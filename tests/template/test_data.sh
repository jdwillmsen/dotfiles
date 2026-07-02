#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
out="$(chez_tmpl "$(chez_init ephemeral)" '{{ .machineRole }}:{{ .isEphemeral }}')"
[ "$out" = "ephemeral:true" ] || { echo "FAIL: got '$out'"; exit 1; }
out="$(chez_tmpl "$(chez_init personal)" '{{ .machineRole }}:{{ .isEphemeral }}')"
[ "$out" = "personal:false" ] || { echo "FAIL: got '$out'"; exit 1; }
echo "PASS"
