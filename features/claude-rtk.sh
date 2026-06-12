#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

if command -v rtk &>/dev/null; then
    skip "RTK already installed — skipping"
    exit 0
fi

# Try cargo first (most platforms), then brew (macOS/Linux with Homebrew)
if command -v cargo &>/dev/null; then
    info "Installing RTK via cargo..."
    cargo install --git https://github.com/rtk-ai/rtk \
        || { warn "RTK cargo install failed — skipping"; exit 0; }
    success "RTK installed — prefix commands with 'rtk' to filter output before it enters context"
elif command -v brew &>/dev/null; then
    info "Installing RTK via brew..."
    brew install rtk \
        || { warn "RTK brew install failed — skipping"; exit 0; }
    success "RTK installed — prefix commands with 'rtk' to filter output before it enters context"
else
    skip "RTK requires cargo or brew — install one first, then re-run install.sh"
    exit 0
fi
