#!/usr/bin/env bash
set -euo pipefail
# The native build is the only install that updates itself; under winget, brew
# or npm the package manager owns the binary and Claude Code never updates
# until someone upgrades it by hand. A before_ script because the plugin and
# MCP scripts drive claude, and on a fresh box it must exist by then.

bin="$HOME/.local/bin"
if [ -x "$bin/claude" ] || [ -x "$bin/claude.exe" ]; then
    echo "Claude Code native build already installed"
elif command -v claude &>/dev/null; then
    # Migrates a package-manager install in place; the old copy stays until it
    # is uninstalled, but ~/.local/bin comes first on PATH so it is never run.
    claude install || echo "claude install failed — run it by hand"
else
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*)
            powershell -NoProfile -Command "irm https://claude.ai/install.ps1 | iex" ||
                echo "Claude Code install failed" ;;
        *)
            curl -fsSL https://claude.ai/install.sh | bash || echo "Claude Code install failed" ;;
    esac
fi

# Git Bash gets ~/.local/bin from exports.sh, but a PowerShell or cmd window
# reads only the registry PATH. The raw value is read unexpanded and written
# back as REG_EXPAND_SZ so %VAR% entries survive, then the change is broadcast
# so terminals started afterwards see it without a re-login.
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        # shellcheck disable=SC2016  # the $ belong to PowerShell, not bash
        powershell -NoProfile -Command '
$dir = Join-Path $HOME ".local\bin"
$key = Get-Item HKCU:\Environment
$path = $key.GetValue("Path", "", "DoNotExpandEnvironmentNames")
if (($path -split ";") -contains $dir) { "~/.local/bin already on the user PATH"; exit 0 }
$new = if ($path) { "$dir;$path" } else { $dir }
Set-ItemProperty HKCU:\Environment -Name Path -Value $new -Type ExpandString
Add-Type -Namespace Win32 -Name Env -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
$r = [UIntPtr]::Zero
[void][Win32.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$r)
"added ~/.local/bin to the user PATH"
' || echo "could not add ~/.local/bin to the user PATH" ;;
esac
