#!/usr/bin/env bash
# Feature: codex — global Codex instructions.
set -euo pipefail

DOTFILES="${1:?DOTFILES path required}"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

FEATURE="$DOTFILES/codex"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_DIR"

if [ -f "$FEATURE/AGENTS.md" ]; then
    symlink "$FEATURE/AGENTS.md" "$CODEX_DIR/AGENTS.md"
fi
