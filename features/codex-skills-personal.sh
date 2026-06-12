#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

SKILLS_SRC="$DOTFILES/codex/skills"
SKILLS_DST="${CODEX_HOME:-$HOME/.codex}/skills"

mkdir -p "$SKILLS_DST"

# Symlink each skill directory from dotfiles/codex/skills/
shopt -s nullglob
linked=0
for skill_dir in "$SKILLS_SRC"/*/; do
    name="$(basename "$skill_dir")"
    symlink "$skill_dir" "$SKILLS_DST/$name"
    linked=$((linked + 1))
done

if [ "$linked" -eq 0 ]; then
    skip "No personal Codex skills yet — add skill directories under codex/skills/"
fi
