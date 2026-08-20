#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_local/bin/executable_aipick"
[ -x "$script" ] || { echo "FAIL: aipick missing or not executable"; exit 1; }

# The alias file must not resurrect the CCR-era paths.
grep -q "claude-code-router" "$here/home/dot_config/shell/aliases.sh" \
    && { echo "FAIL: aliases still reference the removed CCR directory"; exit 1; }

tmp="$(mktemp -d)"
srv=""
# shellcheck disable=SC2064  # $tmp/$srv must expand now: the trap outlives their scope
trap "[ -n \"\$srv\" ] && kill \$srv 2>/dev/null; rm -rf '$tmp'" EXIT
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

# ── Reachability gate ───────────────────────────────────────────────────────
# A provider that is merely listed is not a provider that is running. Port 9
# (discard) is closed everywhere — the uninstalled-ollama case.
write_registry_url() {  # $1 = api_base_url
    cat >"$reg" <<JSON
{
  "providers": [
    { "name": "ollama", "api_base_url": "$1", "api_key": "ollama", "models": ["gpt-oss:20b"] }
  ]
}
JSON
}

# Minimal PATH: no aider/qwen, and a pipx stub so a install attempt is visible
# rather than real.
stub="$tmp/stub"; mkdir -p "$stub"
printf '#!/usr/bin/env bash
echo "PIPX_INSTALL_CALLED: $*"
exit 1
' >"$stub/pipx"
chmod +x "$stub/pipx"
bash_dir="$(dirname "$(command -v bash)")"
node_dir="$(dirname "$(command -v node)")"
curl_dir="$(dirname "$(command -v curl)")"
minpath="$stub:$bash_dir:$node_dir:$curl_dir:/usr/bin:/bin"

write_registry_url "http://127.0.0.1:9/v1/chat/completions"
set +e
out="$(printf '1
1
' | AIPICK_PROVIDERS="$reg" PATH="$minpath" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with the provider unreachable"; echo "$out"; exit 1; }
echo "$out" | grep -q "provider unreachable"     || { echo "FAIL: no diagnostic on the unreachable path"; echo "$out"; exit 1; }
# The gate runs before the installer, so a dead provider never triggers a
# multi-minute aider install for a session that cannot start.
echo "$out" | grep -q "PIPX_INSTALL_CALLED"     && { echo "FAIL: installed a tool for an unreachable provider"; echo "$out"; exit 1; }
# ollama gets a specific hint, not just the generic line.
echo "$out" | grep -q "ollama is not answering"     || { echo "FAIL: no provider-specific hint for ollama"; echo "$out"; exit 1; }

# ── AIPICK_SKIP_PROBE overrides, for a provider that serves chat but not /models ──
set +e
out="$(printf '1
1
' | AIPICK_PROVIDERS="$reg" PATH="$minpath" AIPICK_SKIP_PROBE=1 bash "$script" 2>&1)"
set -e
echo "$out" | grep -q "provider unreachable"     && { echo "FAIL: AIPICK_SKIP_PROBE did not bypass the gate"; echo "$out"; exit 1; }
echo "$out" | grep -q "PIPX_INSTALL_CALLED"     || { echo "FAIL: skip-probe run did not reach the launch path"; echo "$out"; exit 1; }

# ── A reachable provider passes the gate ──
cat >"$tmp/srv.js" <<'JS'
const http = require("http"), fs = require("fs");
const s = http.createServer((req, res) => res.end("{}"));
s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], String(s.address().port)));
JS
node "$tmp/srv.js" "$tmp/port" &
srv=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || { echo "FAIL: stub provider never bound a port"; exit 1; }
write_registry_url "http://127.0.0.1:$(cat "$tmp/port")/v1/chat/completions"
set +e
out="$(printf '1
1
' | AIPICK_PROVIDERS="$reg" PATH="$minpath" bash "$script" 2>&1)"
set -e
echo "$out" | grep -q "provider unreachable"     && { echo "FAIL: a live provider was reported unreachable"; echo "$out"; exit 1; }
echo "$out" | grep -q "PIPX_INSTALL_CALLED"     || { echo "FAIL: reachable provider did not reach the launch path"; echo "$out"; exit 1; }

echo "PASS"
