#!/usr/bin/env bash
set -euo pipefail
if command -v rtk &>/dev/null; then
    echo "RTK already installed — skipping"; exit 0
fi
if command -v cargo &>/dev/null; then
    cargo install --git https://github.com/rtk-ai/rtk || { echo "RTK cargo install failed"; exit 0; }
elif command -v brew &>/dev/null; then
    brew install rtk || { echo "RTK brew install failed"; exit 0; }
else
    echo "RTK requires cargo or brew — install one first"; exit 0
fi
echo "RTK installed"
