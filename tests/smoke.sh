#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$repo/tests/lib.sh"
h="$(mktemp -d)"
chez_apply "$(chez_init personal)" "$h"
for f in .bashrc .zshrc .gitconfig .config/shell/aliases.sh .claude/settings.json; do
    [ -f "$h/$f" ] || { echo "FAIL: missing $f"; exit 1; }
done
echo "SMOKE OK"
