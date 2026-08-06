#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_claude-code-router/executable_refresh-openrouter-free.sh"

[ -f "$script" ] || { echo "FAIL: refresh-openrouter-free not tracked in source state"; exit 1; }
shellcheck -s bash "$script"
bash -n "$script"

grep -qE '>[^&].*config\.json|writeFileSync.*config\.json' "$script" \
    && { echo "FAIL: script writes to config.json — must stay read-only"; exit 1; }

tmp="$(mktemp -d)"
trap "rm -rf '$tmp'" EXIT

# ── fixture mode: filters to free (prompt==0 && completion==0) entries only ──
cat >"$tmp/models.json" <<'JSON'
{
  "data": [
    {"id": "qwen/qwen3-next-80b-a3b-instruct:free", "pricing": {"prompt": "0", "completion": "0"}},
    {"id": "moonshotai/kimi-k3", "pricing": {"prompt": "3", "completion": "15"}},
    {"id": "some/other-free-model:free", "pricing": {"prompt": "0", "completion": "0"}}
  ]
}
JSON
out="$(bash "$script" "$tmp/models.json")"
echo "$out" | grep -qx "qwen/qwen3-next-80b-a3b-instruct:free" \
    || { echo "FAIL: free model 1 not listed"; echo "$out"; exit 1; }
echo "$out" | grep -qx "some/other-free-model:free" \
    || { echo "FAIL: free model 2 not listed"; echo "$out"; exit 1; }
echo "$out" | grep -q "kimi-k3" \
    && { echo "FAIL: paid model leaked through"; echo "$out"; exit 1; }

# ── invalid JSON in the fixture: fail loudly, not a silent empty result ──
echo "not json" >"$tmp/bad.json"
set +e
out="$(bash "$script" "$tmp/bad.json" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 on invalid JSON"; echo "$out"; exit 1; }

# ── unreachable network (live mode, no fixture arg): fail loudly ──
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$tmp/bin/curl"
set +e
out="$(PATH="$tmp/bin:$PATH" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with curl unreachable"; echo "$out"; exit 1; }

echo "PASS"
