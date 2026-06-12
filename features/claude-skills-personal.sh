#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

SKILLS_SRC="$DOTFILES/claude/skills"
SKILLS_DST="$HOME/.claude/skills"

mkdir -p "$SKILLS_DST"

# Symlink each skill directory from dotfiles/claude/skills/
shopt -s nullglob
linked=0
for skill_dir in "$SKILLS_SRC"/*/; do
    name="$(basename "$skill_dir")"
    symlink "$skill_dir" "$SKILLS_DST/$name"
    linked=$((linked + 1))
done

if [ "$linked" -eq 0 ]; then
    skip "No personal skills yet — add skill directories under claude/skills/"
fi
