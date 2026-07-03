#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
rendered="$(chez_render "$(chez_init personal)" "$here/home/run_onchange_after_21-build-opencode-status.sh.tmpl")"
echo "$rendered" | shellcheck -s bash -
echo "$rendered" | grep -q 'go build' || { echo "FAIL: no go build"; exit 1; }
# onchange hash line must reference the Go source so edits retrigger.
echo "$rendered" | grep -q 'opencode-status' || { echo "FAIL: missing target"; exit 1; }

# Wrapper is a static managed file, not a template — shellcheck it directly.
wrapper="$here/home/dot_config/opencode/executable_statusline.sh"
shellcheck -s bash "$wrapper"
grep -q 'exec ~/.local/bin/opencode-status' "$wrapper" || { echo "FAIL: wrapper doesn't exec opencode-status"; exit 1; }
echo "PASS"
