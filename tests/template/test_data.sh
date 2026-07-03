#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
out="$(chez_tmpl "$(chez_init ephemeral)" '{{ .machineRole }}:{{ .isEphemeral }}')"
[ "$out" = "ephemeral:true" ] || { echo "FAIL: got '$out'"; exit 1; }
cfg="$(chez_init personal)"
out="$(chez_tmpl "$cfg" '{{ .machineRole }}:{{ .isEphemeral }}')"
[ "$out" = "personal:false" ] || { echo "FAIL: got '$out'"; exit 1; }
# Persisted sourceDir must let config-only invocations (no --source flag)
# resolve the source, with .chezmoiroot still appending home/.
# cygpath: chezmoi emits native C:/ paths, bash's pwd emits /c/ — normalize.
want="$(cygpath -m "$CHEZ_SRC" 2>/dev/null || echo "$CHEZ_SRC")/home"
out="$(chezmoi source-path --config "$cfg")"
[ "$out" = "$want" ] || { echo "FAIL: source-path got '$out' want '$want'"; exit 1; }
# isWSL must match an independent read of the same kernel marker the template checks.
if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then want=true; else want=false; fi
out="$(chez_tmpl "$cfg" '{{ .isWSL }}')"
[ "$out" = "$want" ] || { echo "FAIL: isWSL got '$out' want '$want'"; exit 1; }
echo "PASS"
