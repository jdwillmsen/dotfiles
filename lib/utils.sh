#!/usr/bin/env bash
# Shared helpers sourced by every feature installer.

info()    { echo "[dotfiles] $*"; }
success() { echo "[dotfiles]   ✓ $*"; }
warn()    { echo "[dotfiles]   ! $*"; }
skip()    { echo "[dotfiles]   ↷ $*"; }

# Symlink src → dst, backing up any existing non-symlink file.
symlink() {
    local src="$1" dst="$2"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        warn "Backing up $(basename "$dst") → ${dst}.bak"
        mv "$dst" "${dst}.bak"
    fi
    ln -sf "$src" "$dst"
    success "Linked $(basename "$dst")"
}

# Run a command; on failure print a warning but do not exit.
try() {
    "$@" || warn "Command failed (non-fatal): $*"
}

# Require a command to be present; if not, print a skip message and exit 0.
require() {
    local cmd="$1" msg="${2:-$1 not found}"
    if ! command -v "$cmd" &>/dev/null; then
        skip "$msg — skipping"
        exit 0
    fi
}
