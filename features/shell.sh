#!/usr/bin/env bash
# Feature: shell — zsh/bash config, aliases, exports, functions.
DOTFILES="${1:?DOTFILES path required}"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

symlink "$DOTFILES/zshrc"  "$HOME/.zshrc"
symlink "$DOTFILES/bashrc" "$HOME/.bashrc"
