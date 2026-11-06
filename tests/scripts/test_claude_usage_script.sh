#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$here/home/dot_local/bin/executable_claude-usage"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$cli" ] || fail "claude-usage missing or not executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AGENT_METRICS_STATE="$tmp/state"
export CLAUDE_USAGE_NOW="2026-11-06T12:00:00+00:00"

# Run the file with plain python3: the browser library is imported lazily, so
# nothing here needs uv or the network.
py() { python3 "$cli" "$@"; }

[ "$(py --version)" = "1.0.0" ] || fail "--version"
py --help | grep -q "snapshot" || fail "--help does not list snapshot"

# ── parsing: quota windows are found by shape, not by name ──
python3 - "$cli" <<'PY' || fail "parser contract"
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("cu", sys.argv[1]).load_module()
usage = {
    "five_hour": {"utilization": 7.0, "resets_at": "2026-11-07T02:09:59+00:00", "used_dollars": None},
    "seven_day": {"utilization": 5.0, "resets_at": "2026-11-12T22:59:59+00:00"},
    "seven_day_opus": None,
    "brass_thimble": {"eligible": False},
    "future_window": {"utilization": 40, "resets_at": "x"},
}
rows = m.parse_usage(usage)
names = [r["name"] for r in rows]
assert names == ["session_5h", "weekly", "future_window"], names
assert "used_usd" not in rows[0], rows[0]
assert m.parse_usage(None) == []
row = m.build_row(usage, {"amount": 0, "currency": None, "balance": None},
                  {"state": "expired", "claimed": True, "expires_at": "e", "eligible": False}, m.now_utc())
assert row["cloud_credit"] == {"state": "expired", "claimed": True, "expires_at": "e"}, row["cloud_credit"]
assert row["credit"] == {"amount": 0}, row["credit"]
assert row["at"] == "2026-11-06T12:00:00Z", row["at"]
import json
assert "uuid" not in json.dumps(row).lower()
PY

# ── show: empty log, then rows ──
py show | grep -q "^readings: 0" || fail "show on an empty log"
mkdir -p "$tmp/state"
printf '%s\n' '{"at":"2026-11-06T10:00:00Z","source":"claude.ai","windows":[{"name":"session_5h","used_pct":8,"resets_at":"r"},{"name":"weekly","used_pct":5,"resets_at":"r"}],"credit":{"amount":0},"cloud_credit":{"state":"expired"}}' \
    'not json' >"$tmp/state/claudeai.jsonl"
py show --limit 5 >"$tmp/out"
grep -q "^readings: 1" "$tmp/out" || fail "show skips a corrupt line and counts the rest" "$(cat "$tmp/out")"
grep -q "8,5,expired" "$tmp/out" || fail "show does not flatten the windows" "$(cat "$tmp/out")"

# ── a profile that is not signed in stops with a login hint and exit 3 ──
bin="$tmp/bin"; mkdir -p "$bin"
cat >"$bin/agent-browser" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    check) echo "logged_in: no" ;;
    stop) : ;;
    *) printf 'state: running\nviewer: http://100.64.0.1:6080/vnc.html\n' ;;
esac
STUB
chmod +x "$bin/agent-browser"
code=0
PATH="$bin:$PATH" py now >"$tmp/out" 2>"$tmp/err" || code=$?
[ "$code" = 3 ] || fail "not signed in should exit 3, got $code" "$(cat "$tmp/out" "$tmp/err")"
grep -q "not signed in" "$tmp/out" || fail "no structured login error" "$(cat "$tmp/out")"
grep -q "never handles credentials" "$tmp/out" || fail "login error does not say credentials are the human's" "$(cat "$tmp/out")"

echo "claude-usage OK"
