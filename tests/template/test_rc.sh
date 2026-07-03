#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
# Ephemeral render must NOT contain interactive prompt (PS1) heavy blocks guarded off.
out="$(chez_render "$(chez_init ephemeral)" "$here/home/dot_bashrc.tmpl")"
echo "$out" | grep -q '\.config/shell/aliases.sh' || { echo "FAIL: aliases not sourced"; exit 1; }
echo "$out" | grep -q 'SDKMAN_DIR' || { echo "FAIL: sdkman block missing"; exit 1; }
echo "PASS"
