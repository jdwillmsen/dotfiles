#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_local/bin/executable_refresh-openrouter-free"
[ -x "$script" ] || { echo "FAIL: refresh-openrouter-free missing or not executable"; exit 1; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT

cat >"$tmp/models.json" <<'JSON'
{ "data": [
  { "id": "vendor/free-one:free",  "pricing": { "prompt": "0", "completion": "0" } },
  { "id": "vendor/paid-one",       "pricing": { "prompt": "0.0000015", "completion": "0.000002" } },
  { "id": "vendor/free-two:free",  "pricing": { "prompt": "0", "completion": "0" } },
  { "id": "vendor/half-paid",      "pricing": { "prompt": "0", "completion": "0.000002" } }
] }
JSON

out="$(bash "$script" "$tmp/models.json")"
echo "$out" | grep -qx "vendor/free-one:free" || { echo "FAIL: free model missing"; echo "$out"; exit 1; }
echo "$out" | grep -qx "vendor/free-two:free" || { echo "FAIL: free model missing"; echo "$out"; exit 1; }
echo "$out" | grep -qx "vendor/paid-one" && { echo "FAIL: paid model listed as free"; echo "$out"; exit 1; }
# Free prompt but paid completion is not free — both sides must be zero.
echo "$out" | grep -qx "vendor/half-paid" && { echo "FAIL: half-paid model listed as free"; echo "$out"; exit 1; }

# Malformed upstream JSON must fail loudly, not emit an empty "nothing is free"
# list that check-openrouter-freshness would read as every model delisted.
echo "not json" >"$tmp/bad.json"
set +e
out="$(bash "$script" "$tmp/bad.json" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 on invalid JSON"; echo "$out"; exit 1; }
echo "$out" | grep -q "invalid JSON" || { echo "FAIL: no diagnostic on invalid JSON"; echo "$out"; exit 1; }

echo "PASS"
