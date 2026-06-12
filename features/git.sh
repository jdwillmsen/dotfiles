#!/usr/bin/env bash
# Feature: git — gitconfig and global gitignore.
DOTFILES="${1:?DOTFILES path required}"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require git "git not found"

symlink "$DOTFILES/gitconfig"        "$HOME/.gitconfig"
symlink "$DOTFILES/gitignore_global" "$HOME/.gitignore_global"
