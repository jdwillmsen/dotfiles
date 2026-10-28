#!/usr/bin/env bash
set -euo pipefail
# The native build is the only install that updates itself; under winget, brew
# or npm the package manager owns the binary and Claude Code never updates
# until someone upgrades it by hand. A before_ script because the plugin script
# drives claude, and on a fresh box it must exist by then. run_before_ rather
# than run_once_: every failure path below exits 0, which run_once_ would record
# as done, so one network blip on a first apply would never be retried.

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
# reads only the registry PATH, and there it must also precede WinGet\Links and
# npm or those windows keep running a copy that never updates. The raw value is
# read unexpanded and written back as REG_EXPAND_SZ so %VAR% entries survive,
# then the change is broadcast so terminals started afterwards see it without a
# re-login. USERPROFILE, not HOME: it is what the vendor installer installs
# under, and a test apply's sandbox HOME must not reach the real registry.
read -r -d '' ps <<'PS' || true
function Merge-UserPath([string]$path, [string]$dir) {
    $norm = { [Environment]::ExpandEnvironmentVariables($args[0]).TrimEnd('\') }
    $want = & $norm $dir
    $entries = @($path -split ';' | Where-Object { $_ })
    if ($entries.Count -and (& $norm $entries[0]) -eq $want) { return $null }
    $rest = @($entries | Where-Object { (& $norm $_) -ne $want })
    return (@($dir) + $rest) -join ';'
}
$dir = Join-Path $env:USERPROFILE '.local\bin'
$path = (Get-Item HKCU:\Environment).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
$new = Merge-UserPath $path $dir
if ($null -eq $new) { '~/.local/bin already first on the user PATH'; exit 0 }
Set-ItemProperty HKCU:\Environment -Name Path -Value $new -Type ExpandString
Add-Type -Namespace Win32 -Name Env -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
$r = [UIntPtr]::Zero
[void][Win32.Env]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$r)
'moved ~/.local/bin to the front of the user PATH'
PS

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
        if [ "$(cygpath -u "$USERPROFILE")" = "$HOME" ]; then
            powershell -NoProfile -Command "$ps" || echo "could not update the user PATH"
        fi ;;
esac
