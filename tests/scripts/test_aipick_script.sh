#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_local/bin/executable_aipick"
[ -x "$script" ] || { echo "FAIL: aipick missing or not executable"; exit 1; }

# The alias file must not resurrect the CCR-era paths.
grep -q "claude-code-router" "$here/home/dot_config/shell/aliases.sh" \
    && { echo "FAIL: aliases still reference the removed CCR directory"; exit 1; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
reg="$tmp/providers.json"

write_registry() {  # $1 = api_key value
    cat >"$reg" <<JSON
{
  "providers": [
    { "name": "ollama", "api_base_url": "http://127.0.0.1:11434/v1/chat/completions", "api_key": "$1", "models": ["gpt-oss:20b"] }
  ]
}
JSON
}
write_registry "ollama"

# ── Aider: base URL loses the /chat/completions suffix the registry carries ──
out="$(printf '1\n1\n' | AIPICK_PROVIDERS="$reg" AIPICK_DRY_RUN=1 bash "$script" 2>&1)"
echo "$out" | grep -q 'OPENAI_API_BASE="http://127.0.0.1:11434/v1"' \
    || { echo "FAIL: aider base url wrong"; echo "$out"; exit 1; }
echo "$out" | grep -q -- '--model "openai/gpt-oss:20b"' \
    || { echo "FAIL: aider model wrong"; echo "$out"; exit 1; }

# ── Qwen ──
out="$(printf '2\n1\n' | AIPICK_PROVIDERS="$reg" AIPICK_DRY_RUN=1 bash "$script" 2>&1)"
echo "$out" | grep -q 'OPENAI_BASE_URL="http://127.0.0.1:11434/v1"' \
    || { echo "FAIL: qwen base url wrong"; echo "$out"; exit 1; }
echo "$out" | grep -q 'OPENAI_MODEL="gpt-oss:20b"' \
    || { echo "FAIL: qwen model wrong"; echo "$out"; exit 1; }

# ── Claude Code is no longer an option: CCR is gone, so offering it would
#    hand the user a route to a router that does not exist. ──
echo "$out" | grep -qi "claude code" \
    && { echo "FAIL: aipick still offers a Claude Code route"; echo "$out"; exit 1; }

# ── "$ENV_VAR" api_key resolves from the environment ──
# shellcheck disable=SC2016  # the literal string "$AIPICK_TEST_KEY" IS the fixture
write_registry '$AIPICK_TEST_KEY'
out="$(printf '1\n1\n' | AIPICK_PROVIDERS="$reg" AIPICK_TEST_KEY=secret-from-env AIPICK_DRY_RUN=1 bash "$script" 2>&1)"
echo "$out" | grep -q "no api key resolved" \
    && { echo "FAIL: env-var api_key did not resolve"; echo "$out"; exit 1; }
# The key itself must never be echoed, even in a dry run.
echo "$out" | grep -q "secret-from-env" \
    && { echo "FAIL: dry-run leaked the api key"; echo "$out"; exit 1; }

# ── Unresolvable env var warns but still launches (dummy-key providers) ──
out="$(printf '1\n1\n' | AIPICK_PROVIDERS="$reg" AIPICK_DRY_RUN=1 bash "$script" 2>&1)"
echo "$out" | grep -q "no api key resolved" \
    || { echo "FAIL: no warning for an unresolvable api key"; echo "$out"; exit 1; }

# ── Missing registry names the path instead of failing inside node ──
set +e
out="$(printf '1\n1\n' | AIPICK_PROVIDERS="$tmp/absent.json" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with no registry"; echo "$out"; exit 1; }
echo "$out" | grep -q "no provider registry at" \
    || { echo "FAIL: no diagnostic for a missing registry"; echo "$out"; exit 1; }

# ── Bad tool choice ──
set +e
out="$(printf '9\n' | AIPICK_PROVIDERS="$reg" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 on an invalid tool choice"; echo "$out"; exit 1; }

echo "PASS"
