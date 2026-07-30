#!/usr/bin/env bash
set -euo pipefail
# The starship config renders git and status glyphs from the Nerd Font private
# use area; without a patched font they render as tofu. Font families are not
# executables, so this cannot reuse the `command -v` gate the other installers
# share and asks the package manager whether the family is present instead.
# The upstream Nerd Fonts archives register the family as "JetBrainsMono Nerd
# Font" while the MSI winget serves abbreviates it to "JetBrainsMono NF", so the
# presence check has to accept either spelling or it reinstalls on every machine.
FAMILY="JetBrainsMono NF"

font_present() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*)
            # Enumerating installed families needs .NET; a non-zero exit here
            # means "could not determine", which falls through to a reinstall
            # attempt that winget then no-ops.
            powershell.exe -NoProfile -Command \
                "Add-Type -AssemblyName System.Drawing
                 \$n = (New-Object System.Drawing.Text.InstalledFontCollection).Families.Name
                 if (\$n -match '^JetBrainsMono (NF|Nerd Font)$') { exit 0 } else { exit 1 }" \
                &>/dev/null
            ;;
        *)
            command -v fc-list &>/dev/null &&
                fc-list 2>/dev/null | grep -qiE "JetBrainsMono (NF|Nerd Font)"
            ;;
    esac
}

if font_present; then
    echo "$FAMILY already installed — skipping"; exit 0
fi

if command -v brew &>/dev/null; then
    brew install --cask font-jetbrains-mono-nerd-font ||
        { echo "$FAMILY brew install failed"; exit 0; }
elif command -v winget &>/dev/null; then
    winget install --id DEVCOM.JetBrainsMonoNerdFont --silent \
        --accept-package-agreements --accept-source-agreements ||
        { echo "$FAMILY winget install failed"; exit 0; }
elif command -v scoop &>/dev/null; then
    # Nerd Fonts live in a non-default bucket, so adding it is part of installing.
    scoop bucket add nerd-fonts &>/dev/null || true
    scoop install JetBrainsMono-NF ||
        { echo "$FAMILY scoop install failed"; exit 0; }
else
    echo "$FAMILY requires brew, winget, or scoop — install one first"; exit 0
fi
echo "$FAMILY installed — set it as your terminal font to see prompt glyphs"
