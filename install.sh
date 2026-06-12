#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/utils.sh
source "$DOTFILES/lib/utils.sh"

info "Installing dotfiles from $DOTFILES"
echo

# Run a feature installer. A non-zero exit is treated as a non-fatal skip —
# it never fails the overall install.
run_feature() {
    local name="$1"
    local script="$DOTFILES/features/${name}.sh"
    if [ ! -f "$script" ]; then
        warn "Feature '$name' not found — skipping"
        return 0
    fi
    info "Feature: $name"
    bash "$script" "$DOTFILES" || warn "Feature '$name' could not be fully installed — skipping"
    echo
}

run_feature shell
run_feature git
run_feature claude-status
run_feature claude
run_feature claude-mcp
run_feature claude-plugins
run_feature claude-rtk
run_feature claude-skills-personal
run_feature claude-plugins-personal
run_feature tmux

info "Done. Restart your shell or run:"
info "  source ~/.zshrc   (zsh)"
info "  source ~/.bashrc  (bash)"
