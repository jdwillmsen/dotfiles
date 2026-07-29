#!/usr/bin/env bash
set -euo pipefail
# rtk shells out to rg for every search and prints a fallback warning per call
# when it is absent, so this is a hard dependency of the 40-install-rtk pairing.
if command -v rg &>/dev/null; then
    echo "ripgrep already installed — skipping"; exit 0
fi
# Prebuilt-binary managers first; cargo is the universal fallback but compiles
# ripgrep from source, which costs minutes on a first-run bootstrap.
if command -v brew &>/dev/null; then
    brew install ripgrep || { echo "ripgrep brew install failed"; exit 0; }
elif command -v winget &>/dev/null; then
    winget install --id BurntSushi.ripgrep.MSVC --silent --accept-package-agreements --accept-source-agreements ||
        { echo "ripgrep winget install failed"; exit 0; }
elif command -v scoop &>/dev/null; then
    scoop install ripgrep || { echo "ripgrep scoop install failed"; exit 0; }
elif command -v cargo &>/dev/null; then
    cargo install ripgrep || { echo "ripgrep cargo install failed"; exit 0; }
else
    echo "ripgrep requires brew, winget, scoop, or cargo — install one first"; exit 0
fi
echo "ripgrep installed"
