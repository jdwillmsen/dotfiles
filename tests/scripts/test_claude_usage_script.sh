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

# ── a failed credit or promo read is an error state, never a $0 balance ──
python3 - "$cli" <<'PY' || fail "unavailable reads must not look like zero"
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("cu2", sys.argv[1]).load_module()
assert m.parse_credits(None) == {"error": "unavailable"}
assert m.parse_credits({"amount": 0}) == {"amount": 0}
assert m.parse_promo(None) == {"state": "unavailable"}
row = {"at": "t", "source": "s", "credit": {}, "cloud_credit": {},
       "windows": [{"name": "a", "used_pct": 1, "resets_at": "r"},
                   {"name": "b", "used_pct": 2, "resets_at": "r", "used_usd": 3.5}]}
w = m.present(row)["windows"]
assert all(set(x) == set(w[0]) and "used_usd" in x for x in w), w
PY

# ── the browser: stop only what this run started, from fully stopped ──
bin="$tmp/bin"; mkdir -p "$bin"
cat >"$bin/agent-browser" <<'STUB'
#!/usr/bin/env bash
d="${STUB_DIR:?}"
echo "${1:-status}" >>"$d/calls"
case "${1:-}" in
    check)
        case "$(cat "$d/login")" in
            fail) exit 1 ;;
            *) echo "site: x"; echo "logged_in: $(cat "$d/login")" ;;
        esac ;;
    start) [ -e "$d/start_fails" ] || echo running >"$d/state"; echo "state: $(cat "$d/state")" ;;
    stop) echo stopped >"$d/state" ;;
    *) printf 'state: %s\nviewer: http://100.64.0.1:6080/vnc.html\n' "$(cat "$d/state")" ;;
esac
STUB
chmod +x "$bin/agent-browser"
export STUB_DIR="$tmp/stub"; mkdir -p "$STUB_DIR"
# Run with the stub and no Playwright: after the sign-in check the browser
# library is imported, so a "yes" ends in a structured error and exit 1, and
# the calls show what was started and stopped.
drive() {  # drive STATE LOGIN [claude-usage args...]
    printf '%s\n' "$1" >"$STUB_DIR/state"; printf '%s\n' "$2" >"$STUB_DIR/login"; : >"$STUB_DIR/calls"
    shift 2
    code=0
    # An unused debug port, so a host python3 that does have Playwright can
    # never reach a real browser: the run fails at connect, deterministically.
    AGENT_BROWSER_CDP_PORT=9 PATH="$bin:$PATH" py "$@" >"$tmp/out" 2>"$tmp/err" || code=$?
    calls="$(tr '\n' ' ' <"$STUB_DIR/calls")"
}

drive running yes now
[ "$calls" = "status check " ] || fail "a running browser must be neither started nor stopped" "$calls"
drive stopped yes now
[ "$calls" = "status start status check stop " ] || fail "a stopped browser is started, then stopped by this run" "$calls"
drive partial yes now
[ "$calls" = "status start status check " ] || fail "a half-up browser is repaired but never stopped" "$calls"
drive stopped fail now
[ "$code" = 1 ] || fail "a failing sign-in check must exit 1, got $code" "$(cat "$tmp/out")"
grep -q "could not check" "$tmp/out" || fail "a failing check is not reported as such" "$(cat "$tmp/out")"
[ "$calls" = "status start status check stop " ] || fail "the browser this run started is stopped even on error" "$calls"
# A start that does not bring the browser up is still cleaned up.
: >"$STUB_DIR/start_fails"
drive stopped yes now
rm -f "$STUB_DIR/start_fails"
[ "$code" = 1 ] || fail "a failed start must exit 1, got $code" "$(cat "$tmp/out")"
grep -q "would not start" "$tmp/out" || fail "a failed start is not reported" "$(cat "$tmp/out")"
[ "$calls" = "status start status stop " ] || fail "a failed start must still stop what this run began" "$calls"
drive running no now
[ "$code" = 3 ] || fail "not signed in should exit 3, got $code" "$(cat "$tmp/out" "$tmp/err")"
grep -q "not signed in" "$tmp/out" || fail "no structured login error" "$(cat "$tmp/out")"
grep -q "never handles credentials" "$tmp/out" || fail "login error does not say credentials are the human's" "$(cat "$tmp/out")"
[ "$calls" = "status check status " ] || fail "a sign-in miss must not stop a browser it did not start" "$calls"

# ── --if-idle: the timer leaves a browser that is in use alone ──
drive running yes snapshot --if-idle
[ "$code" = 0 ] || fail "--if-idle skipping must exit 0, got $code" "$(cat "$tmp/out")"
grep -q "snapshot: skipped" "$tmp/out" || fail "--if-idle must skip while the browser runs" "$(cat "$tmp/out")"
[ "$calls" = "status " ] || fail "--if-idle must not start, check or stop anything" "$calls"
drive partial yes snapshot --if-idle
grep -q "snapshot: skipped" "$tmp/out" || fail "--if-idle must skip a half-up browser" "$(cat "$tmp/out")"

# ── wiring: unit, timer, enable hook and gaming-machine ignore ──
svc="$here/home/dot_config/systemd/user/claude-usage.service"
tim="$here/home/dot_config/systemd/user/claude-usage.timer"
grep -q "^ExecStart=%h/.local/bin/claude-usage snapshot --if-idle$" "$svc" || fail "the service must run snapshot --if-idle"
grep -q "^Unit=claude-usage.service$" "$tim" || fail "the timer does not point at the service"
grep -q "^Persistent=false$" "$tim" || fail "readings of now must not be caught up"
hook="$here/home/run_onchange_53-enable-agent-metrics.sh.tmpl"
grep -q 'include "dot_config/systemd/user/claude-usage.service" | sha256sum' "$hook" || fail "service edits must retrigger the hook"
grep -q 'include "dot_config/systemd/user/claude-usage.timer" | sha256sum' "$hook" || fail "timer edits must retrigger the hook"
grep -q "enable --now claude-usage.timer" "$hook" || fail "the hook does not enable the timer"
grep -q "disable --now claude-usage.timer" "$hook" || fail "the hook must disable the timer when a prerequisite is missing"
grep -q 'for bin in google-chrome Xvfb x11vnc websockify tailscale uv' "$hook" || fail "the timer must be gated on the browser stack"
grep -qx ".local/bin/claude-usage" "$here/home/.chezmoiignore" || fail "gaming machines must not get claude-usage"
grep -q "claude-usage.timer" "$here/docs/services.md" || fail "docs/services.md does not list the timer"

echo "claude-usage OK"
