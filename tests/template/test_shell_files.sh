#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
chez_require_key
dest="$(chez_sandbox)"
chez_apply "$(chez_init personal)" "$dest" >/dev/null 2>&1 || true
for f in aliases exports functions; do
    [ -f "$dest/.config/shell/$f.sh" ] || { echo "FAIL: missing $f.sh"; exit 1; }
done
for a in "alias jlabs='cd ~/projects/jdwlabs'" "alias jdw='cd ~/projects/jdwillmsen'" \
    "alias dota='cd ~/projects/dotablaze-tech'"; do
    grep -qxF "$a" "$dest/.config/shell/aliases.sh" || { echo "FAIL: missing stream alias: $a"; exit 1; }
done
[ -f "$dest/.config/streams.json" ] || { echo "FAIL: stream map not deployed"; exit 1; }
[ -x "$dest/.local/bin/stream" ] || { echo "FAIL: stream command not deployed executable"; exit 1; }
grep -q "^export DOTFILES=" "$dest/.config/shell/exports.sh" && { echo "FAIL: DOTFILES leaked"; exit 1; }
echo "PASS"
