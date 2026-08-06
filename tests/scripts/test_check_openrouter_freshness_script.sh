#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_claude-code-router/executable_check-openrouter-freshness.sh"
refresh_script="$here/home/dot_claude-code-router/executable_refresh-openrouter-free.sh"

[ -f "$script" ] || { echo "FAIL: freshness checker not tracked in source state"; exit 1; }
shellcheck -s bash "$script"
bash -n "$script"

grep -q "alias orcheck='bash ~/.claude-code-router/check-openrouter-freshness.sh'" "$here/home/dot_config/shell/aliases.sh" \
    || { echo "FAIL: no orcheck alias"; exit 1; }

tmp="$(mktemp -d)"
trap "rm -rf '$tmp'" EXIT
mkdir -p "$tmp/.claude-code-router"
cp "$refresh_script" "$tmp/.claude-code-router/refresh-openrouter-free.sh"

write_config() {  # $1 = space-separated openrouter model ids ("" = no openrouter provider)
    local models="[]"
    if [ -n "$1" ]; then
        # shellcheck disable=SC2086  # unquoted on purpose: $1 splits into multiple node argv entries
        models="$(node -e 'console.log(JSON.stringify(process.argv.slice(1)))' $1)"
    fi
    node -e '
      const models = JSON.parse(process.argv[1]);
      const providers = [{ name: "ollama", api_base_url: "http://x", api_key: "x", models: ["m1"] }];
      if (process.argv[2] === "1") providers.push({ name: "openrouter", api_base_url: "https://openrouter.ai/api/v1/chat/completions", api_key: "x", models });
      console.log(JSON.stringify({ Providers: providers }, null, 2));
    ' "$models" "${2:-1}" >"$tmp/.claude-code-router/config.json"
}
write_fixture() {  # $1 = space-separated free model ids
    # shellcheck disable=SC2086  # unquoted on purpose: $1 splits into multiple node argv entries
    node -e '
      const data = process.argv.slice(1).map(id => ({ id, pricing: { prompt: "0", completion: "0" } }));
      console.log(JSON.stringify({ data }));
    ' $1 >"$tmp/fixture.json"
}

# ── missing config.json: fail loudly ──
set +e
out="$(HOME="$tmp/missing" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with no config.json"; echo "$out"; exit 1; }
case "$out" in *"no CCR config"*) ;; *) echo "FAIL: no diagnostic for missing config"; echo "$out"; exit 1 ;; esac

# ── no openrouter provider configured: nothing to check ──
write_config "" 0
out="$(HOME="$tmp" bash "$script")"
echo "$out" | grep -q "no openrouter models configured" \
    || { echo "FAIL: didn't short-circuit with no openrouter provider"; echo "$out"; exit 1; }

# ── all configured models still free: PASS ──
write_config "modelA modelB"
write_fixture "modelA modelB modelC"
out="$(HOME="$tmp" bash "$script" "$tmp/fixture.json")"
echo "$out" | grep -q "all configured openrouter models are currently free" \
    || { echo "FAIL: didn't confirm freshness with a clean fixture"; echo "$out"; exit 1; }

# ── a configured model delisted from the free tier: FAIL and name it ──
write_config "modelA modelB"
write_fixture "modelA"
set +e
out="$(HOME="$tmp" bash "$script" "$tmp/fixture.json" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with a stale model configured"; echo "$out"; exit 1; }
echo "$out" | grep -q "modelB" \
    || { echo "FAIL: stale model not named in output"; echo "$out"; exit 1; }

echo "PASS"
