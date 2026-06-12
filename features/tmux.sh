#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require tmux

symlink "$DOTFILES/tmux/tmux.conf" "$HOME/.tmux.conf"

success "tmux configured — see docs/tmux.md for usage"
