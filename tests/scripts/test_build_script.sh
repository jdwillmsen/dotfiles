#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
. "$here/tests/lib.sh"
rendered="$(chez_render "$(chez_init personal)" "$here/home/run_onchange_after_20-build-claude-status.sh.tmpl")"
echo "$rendered" | shellcheck -s bash -
echo "$rendered" | grep -q 'go build' || { echo "FAIL: no go build"; exit 1; }
# onchange hash line must reference the Go source so edits retrigger.
echo "$rendered" | grep -q 'claude-status' || { echo "FAIL: missing target"; exit 1; }
echo "PASS"
