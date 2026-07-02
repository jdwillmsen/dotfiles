#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
dest="$(mktemp -d)"
chez_apply "$(chez_init personal)" "$dest" >/dev/null 2>&1 || true
for f in aliases exports functions; do
    [ -f "$dest/.config/shell/$f.sh" ] || { echo "FAIL: missing $f.sh"; exit 1; }
done
grep -q "alias jlabs=" "$dest/.config/shell/aliases.sh" || { echo "FAIL: jlabs alias missing"; exit 1; }
grep -q "^export DOTFILES=" "$dest/.config/shell/exports.sh" && { echo "FAIL: DOTFILES leaked"; exit 1; }
echo "PASS"
