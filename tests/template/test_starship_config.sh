#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cfg="$here/home/dot_config/starship.toml"

# Read scan_timeout only where it counts: at the top level, before the first
# table header. Nested under a table starship silently ignores it. The awk
# tracks """ blocks because `format` embeds lines that begin with "[".
timeout="$(awk '
    /"""/ { block = !block; next }
    block { next }
    /^\[/ { exit }
    /^scan_timeout[ \t]*=/ { gsub(/[^0-9]/, ""); print; exit }
' "$cfg")"

# Must stay above starship's 30ms default: at the default a cold
# C:\Windows\System32 times out, which warns above every prompt and drops the
# detection-gated modules from it.
[ -n "$timeout" ] && [ "$timeout" -gt 30 ] \
    || { echo "FAIL: top-level scan_timeout is '${timeout:-unset}', not above the 30ms default"; exit 1; }

# Where starship is installed, confirm the parser agrees with the awk above.
if command -v starship >/dev/null 2>&1; then
    parsed="$(STARSHIP_CONFIG="$cfg" starship print-config | grep -oE '^scan_timeout = [0-9]+' | grep -oE '[0-9]+' || true)"
    [ "$parsed" = "$timeout" ] \
        || { echo "FAIL: starship resolved scan_timeout to '${parsed:-unset}', not $timeout"; exit 1; }
fi
echo "PASS"
