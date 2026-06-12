#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

PLUGINS_SRC="$DOTFILES/claude/plugins"
PLUGINS_DST="$HOME/.claude/plugins"

mkdir -p "$PLUGINS_DST"

# Symlink each personal plugin directory from dotfiles/claude/plugins/
shopt -s nullglob
linked=0
for plugin_dir in "$PLUGINS_SRC"/*/; do
    name="$(basename "$plugin_dir")"
    symlink "$plugin_dir" "$PLUGINS_DST/$name"
    linked=$((linked + 1))
done

if [ "$linked" -eq 0 ]; then
    skip "No personal plugins yet — add plugin directories under claude/plugins/"
fi
