#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
bindir="$here/home/dot_local/bin"
script="$bindir/executable_check-openrouter-freshness"
[ -x "$script" ] || { echo "FAIL: check-openrouter-freshness missing or not executable"; exit 1; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT

# The checker shells out to its sibling by the installed name, so stage both
# under one dir the way chezmoi lays them out in ~/.local/bin.
stage="$tmp/bin"; mkdir -p "$stage"
cp "$script" "$stage/check-openrouter-freshness"
cp "$bindir/executable_refresh-openrouter-free" "$stage/refresh-openrouter-free"
chmod +x "$stage"/*

cat >"$tmp/models.json" <<'JSON'
{ "data": [ { "id": "vendor/still-free:free", "pricing": { "prompt": "0", "completion": "0" } } ] }
JSON

write_registry() {  # $@ = configured openrouter model ids
    { echo '{ "providers": [ { "name": "openrouter", "api_base_url": "https://openrouter.ai/api/v1/chat/completions", "api_key": "k", "models": ['
      sep=""
      for m in "$@"; do printf '%s"%s"' "$sep" "$m"; sep=", "; done
      echo '] } ] }'
    } >"$tmp/providers.json"
}

# ── All configured models still free ──
write_registry "vendor/still-free:free"
out="$(AIPICK_PROVIDERS="$tmp/providers.json" "$stage/check-openrouter-freshness" "$tmp/models.json")"
echo "$out" | grep -q "all configured openrouter models are currently free" \
    || { echo "FAIL: fresh models not reported clean"; echo "$out"; exit 1; }

# ── A delisted model must fail loudly and name itself ──
write_registry "vendor/still-free:free" "vendor/delisted:free"
set +e
out="$(AIPICK_PROVIDERS="$tmp/providers.json" "$stage/check-openrouter-freshness" "$tmp/models.json" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with a delisted model"; echo "$out"; exit 1; }
echo "$out" | grep -q "vendor/delisted:free" \
    || { echo "FAIL: stale model not named"; echo "$out"; exit 1; }
echo "$out" | grep -q "vendor/still-free:free" \
    && { echo "FAIL: still-free model reported stale"; echo "$out"; exit 1; }

# ── No openrouter provider configured is a clean no-op, not an error ──
echo '{ "providers": [ { "name": "ollama", "api_base_url": "http://127.0.0.1:11434/v1/chat/completions", "api_key": "ollama", "models": ["gpt-oss:20b"] } ] }' >"$tmp/providers.json"
out="$(AIPICK_PROVIDERS="$tmp/providers.json" "$stage/check-openrouter-freshness" "$tmp/models.json")"
echo "$out" | grep -q "no openrouter models configured" \
    || { echo "FAIL: missing openrouter provider not handled"; echo "$out"; exit 1; }

# ── Missing registry names the path ──
set +e
out="$(AIPICK_PROVIDERS="$tmp/absent.json" "$stage/check-openrouter-freshness" "$tmp/models.json" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with no registry"; echo "$out"; exit 1; }
echo "$out" | grep -q "no provider registry at" \
    || { echo "FAIL: no diagnostic for a missing registry"; echo "$out"; exit 1; }

echo "PASS"
