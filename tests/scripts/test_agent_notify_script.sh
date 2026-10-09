#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-notify posts to GitHub and runs at every shell start, so the tests
# run it against a fixture state directory and a stub gh that records its calls.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
notify="$here/home/dot_local/bin/executable_agent-notify"
units="$here/home/dot_config/systemd/user"
trigger="$here/home/run_onchange_55-enable-agent-notify.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$notify" ] || fail "agent-notify missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$notify" || fail "agent-notify does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
mkdir -p "$tmp/home" "$tmp/config" "$tmp/state" "$tmp/store" "$tmp/bin"
echo '{"store_remote": "git@github.com:acme/metrics.git"}' >"$tmp/config/config.json"

export HOME="$tmp/home"
export AGENT_METRICS_STORE="$tmp/store"
export AGENT_METRICS_STATE="$tmp/state"
export AGENT_METRICS_CONFIG="$tmp/config"
export AGENT_METRICS_NOW="2026-10-09T12:00:00+00:00"
state="$tmp/state"

# The stub answers from files so each case can script gh without editing it.
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [ -e "$GH_FAIL" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
case "$1 $2" in
    "issue list") cat "$GH_LIST" ;;
    "issue create") echo "https://github.com/acme/metrics/issues/41" ;;
    "issue comment") cat >"$GH_BODY" ;;
    "issue pin") [ -e "$GH_NOPIN" ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log" GH_FAIL="$tmp/gh.fail" GH_LIST="$tmp/gh.list" GH_BODY="$tmp/gh.body" GH_NOPIN="$tmp/gh.nopin"
echo '[]' >"$GH_LIST"
: >"$GH_LOG"
export PATH="$tmp/bin:$PATH"

out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$notify" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-notify $* exited $got, want $want" "$(cat "$out" "$err")"
}
calls() { wc -l <"$GH_LOG" | tr -d ' '; }
write_flags() {  # $1 date
    python3 - "$state/flags.json" "$1" <<'PY'
import json, sys
json.dump({"date": sys.argv[2], "window": "daily", "flags": [
    {"id": "spend-spike", "severity": "critical", "metric": "CANARY_METRIC", "message": "Spend was 3.1x the baseline", "value": 91.5, "baseline": 29.4},
    {"id": "cache-drop", "severity": "warn", "metric": "cache_read_share", "message": "Cache reads fell to 41%", "value": 0.41, "baseline": None}]},
    open(sys.argv[1], "w"))
PY
}

# ── CLI surface ──
run 0 --help
grep -q "send" "$out" && grep -q "show" "$out" || fail "--help does not list the commands" "$(cat "$out")"
run 0
grep -q "^pending: none" "$out" || fail "home view should say nothing is pending" "$(cat "$out")"
run 2 frobnicate
grep -q "^error:" "$out" || fail "an unknown command does not print a structured error" "$(cat "$out")"

# ── No flags: nothing to send, shell stays quiet ──
run 0 send
grep -qi "nothing to send" "$out" || fail "send without flags should say so" "$(cat "$out")"
[ "$(calls)" = 0 ] || fail "send without flags called gh"
run 0 shell
[ ! -s "$out" ] || fail "shell printed something without flags" "$(cat "$out")"

# ── Dry run: shows the comment, calls nothing, remembers nothing ──
write_flags 2026-10-08
run 0 send --dry-run
grep -q "spend-spike" "$out" && grep -q "reports/2026-10-08-daily.json" "$out" || fail "dry run does not show the comment" "$(cat "$out")"
[ "$(calls)" = 0 ] && [ ! -e "$state/notified.json" ] || fail "dry run called gh or wrote state"

# ── First send: finds no issue, creates and pins one, comments ──
run 0 send
grep -q "^issue list --repo acme/metrics" "$GH_LOG" || fail "send did not look for the tracking issue in the store repo" "$(cat "$GH_LOG")"
grep -q '^issue create --repo acme/metrics --title Agent metrics: flagged days' "$GH_LOG" || fail "send did not create the tracking issue" "$(cat "$GH_LOG")"
grep -q '^issue pin 41 --repo acme/metrics' "$GH_LOG" || fail "send did not try to pin the issue" "$(cat "$GH_LOG")"
grep -q '^issue comment 41 --repo acme/metrics' "$GH_LOG" || fail "send did not comment on the new issue" "$(cat "$GH_LOG")"
[ "$(cat "$state/notify-issue")" = 41 ] || fail "issue number not remembered"
grep -q "2026-10-08" "$GH_BODY" && grep -q "critical" "$GH_BODY" && grep -q "spend-spike" "$GH_BODY" \
    && grep -q "Spend was 3.1x the baseline" "$GH_BODY" && grep -q "warn" "$GH_BODY" && grep -q "cache-drop" "$GH_BODY" \
    || fail "comment is missing the date or a flag" "$(cat "$GH_BODY")"
grep -q "reports/2026-10-08-daily.json" "$GH_BODY" || fail "comment has no pointer to the daily report" "$(cat "$GH_BODY")"
if grep -qE "CANARY_METRIC|91.5|29.4" "$GH_BODY"; then fail "comment carries more than severity, id and message" "$(cat "$GH_BODY")"; fi
grep -q "2026-10-08" "$state/notified.json" || fail "date not marked notified"

# ── Idempotent per date ──
n="$(calls)"
run 0 send
grep -qi "already" "$out" || fail "a repeat send should say it already notified" "$(cat "$out")"
[ "$(calls)" = "$n" ] || fail "a repeat send called gh again"

# ── A new date reuses the remembered issue ──
write_flags 2026-10-09
: >"$GH_LOG"
run 0 send
[ "$(calls)" = 1 ] && grep -q '^issue comment 41 ' "$GH_LOG" || fail "second date should only comment on the remembered issue" "$(cat "$GH_LOG")"

# ── gh failure: exit 1, date stays unnotified ──
write_flags 2026-10-10
touch "$GH_FAIL"
run 1 send
grep -q "gh" "$out" || fail "a gh failure is not reported" "$(cat "$out")"
if grep -q "2026-10-10" "$state/notified.json"; then fail "a failed send marked the date notified"; fi
rm -f "$GH_FAIL"
run 0 send
grep -q "2026-10-10" "$state/notified.json" || fail "the retry did not notify"

# ── Existing issue is found by exact title; a pin refusal is not fatal ──
rm -f "$state/notify-issue" "$state/notified.json"
touch "$GH_NOPIN"
echo '[{"number": 3, "title": "Agent metrics: flagged days (old)"}, {"number": 7, "title": "Agent metrics: flagged days"}]' >"$GH_LIST"
: >"$GH_LOG"
run 0 send
grep -q '^issue comment 7 ' "$GH_LOG" || fail "did not reuse the exact-title issue" "$(cat "$GH_LOG")"
grep -q '^issue create' "$GH_LOG" && fail "created a second tracking issue"
[ "$(cat "$state/notify-issue")" = 7 ] || fail "found issue not remembered"
rm -f "$GH_NOPIN"
echo '[{"number": 3, "title": "Agent metrics: flagged days (old)"}]' >"$GH_LIST"
rm -f "$state/notify-issue" "$state/notified.json"
touch "$GH_NOPIN"
run 0 send
[ "$(cat "$state/notify-issue")" = 41 ] || fail "a near-match title must not be adopted"
rm -f "$GH_NOPIN"

# ── Repo derivation ──
for remote in "https://github.com/acme/metrics.git" "ssh://git@github.com/acme/metrics" "git@github.com:acme/metrics"; do
    echo "{\"store_remote\": \"$remote\"}" >"$tmp/config/config.json"
    rm -f "$state/notified.json"
    : >"$GH_LOG"
    run 0 send
    grep -q -- "--repo acme/metrics" "$GH_LOG" || fail "could not derive the repo from $remote" "$(cat "$GH_LOG")"
done
echo '{"store_remote": "/srv/git/metrics.git"}' >"$tmp/config/config.json"
rm -f "$state/notified.json"
run 2 send
grep -q "store_remote" "$out" || fail "a non-GitHub remote should name store_remote" "$(cat "$out")"
AGENT_NOTIFY_REPO=other/place run 0 send
grep -q -- "--repo other/place" "$GH_LOG" || fail "AGENT_NOTIFY_REPO override ignored"
echo '{"store_remote": "git@github.com:acme/metrics.git"}' >"$tmp/config/config.json"

# ── Home view ──
run 0
grep -q "^pending: " "$out" && grep -q "last_notified" "$out" && grep -q "issue" "$out" || fail "home view is incomplete" "$(cat "$out")"

# ── Shell line, show, acknowledgement ──
rm -f "$state/acked.json"
write_flags 2026-10-08
: >"$GH_LOG"
run 0 shell
[ "$(wc -l <"$out" | tr -d ' ')" = 1 ] || fail "shell must print exactly one line" "$(cat "$out")"
grep -q "agent-metrics: 2 flags for 2026-10-08 (1 critical): run agent-notify show" "$out" || fail "shell line wrong" "$(cat "$out")"
[ "$(calls)" = 0 ] || fail "shell touched the network"
run 0 show
grep -q "spend-spike" "$out" && grep -q "Spend was 3.1x" "$out" && grep -q "cache-drop" "$out" || fail "show does not list the flags" "$(cat "$out")"
grep -q "2026-10-08" "$state/acked.json" || fail "show did not acknowledge"
run 0 shell
[ ! -s "$out" ] || fail "shell still prints after acknowledgement" "$(cat "$out")"
write_flags 2026-10-11
run 0 shell
grep -q "2026-10-11" "$out" || fail "a new date should not be covered by an old acknowledgement" "$(cat "$out")"
python3 - "$state/flags.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["flags"] = d["flags"][1:]
json.dump(d, open(sys.argv[1], "w"))
PY
run 0 shell
grep -q "1 flag for 2026-10-11 (1 warn)" "$out" || fail "singular wording or worst severity wrong" "$(cat "$out")"
run 0 show
rm -f "$state/flags.json"
run 0 show
grep -qi "no flags" "$out" || fail "show without flags should say so" "$(cat "$out")"

# ── Malformed flags: send and show name the file, shell stays silent ──
echo '{nope' >"$state/flags.json"
run 2 send
grep -q "flags.json" "$out" || fail "send does not name the broken file" "$(cat "$out")"
run 2 show
grep -q "flags.json" "$out" || fail "show does not name the broken file" "$(cat "$out")"
run 0 shell
[ ! -s "$out" ] && [ ! -s "$err" ] || fail "shell must stay silent on a broken file" "$(cat "$out" "$err")"
echo '{"date": "../../x", "flags": [{"id": "a", "severity": "warn", "message": "m"}]}' >"$state/flags.json"
run 2 send
grep -q "date" "$out" || fail "a date that is not YYYY-MM-DD must be refused" "$(cat "$out")"
rm -f "$state/flags.json"

# ── Wiring: shell start, units, trigger ──
grep -q "agent-notify shell" "$here/home/dot_config/shell/functions.sh" || fail "shell start does not call agent-notify"
grep -q "flags.json" "$here/home/dot_config/shell/functions.sh" || fail "shell start should test for flags.json before starting Python"
svc="$units/agent-notify.service"
timer="$units/agent-notify.timer"
grep -qx 'ExecStart=%h/.local/bin/agent-notify send' "$svc" || fail "service ExecStart"
grep -qx 'NoNewPrivileges=yes' "$svc" && grep -qx 'PrivateTmp=yes' "$svc" || fail "service hardening missing"
grep -q '^TimeoutStartSec=' "$svc" || fail "service needs a hard timeout"
grep -q '^Environment=PATH=' "$svc" || fail "service needs a PATH: a user manager starts with a bare one"
grep -qxF "OnCalendar=*-*-* 07:20:00" "$timer" || fail "timer calendar"
grep -qx "Unit=agent-notify.service" "$timer" || fail "timer target"
grep -qx "Persistent=true" "$timer" || fail "timer must catch up after downtime"
grep -qx "WantedBy=timers.target" "$timer" || fail "timer install target"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "*-*-* 07:20:00" >/dev/null || fail "calendar rejected by systemd"
    systemd-analyze calendar "*-*-* 07:30:00" >/dev/null || fail "calendar rejected by systemd"
fi

shellcheck -s bash "$trigger"
trig="$tmp/trig"
mkdir -p "$trig/bin" "$trig/home/.config/systemd/user"
cp "$svc" "$trig/home/.config/systemd/user/"
cat >"$trig/bin/systemctl" <<'STUB'
#!/bin/sh
if [ "$2" = "show-environment" ]; then echo "HOME=$STUB_MANAGER_HOME"; exit 0; fi
echo "$*" >>"$CALL_LOG"
STUB
cat >"$trig/bin/loginctl" <<'STUB'
#!/bin/sh
echo "${STUB_LINGER:-no}"
STUB
chmod +x "$trig/bin"/*
run_trigger() {  # $1 manager home
    : >"$trig/calls"
    trig_out="$(PATH="$trig/bin:/usr/bin:/bin" HOME="$trig/home" USER=tester BASH_ENV=/dev/null \
        XDG_CONFIG_HOME="$trig/home/.config" CALL_LOG="$trig/calls" STUB_MANAGER_HOME="$1" \
        STUB_LINGER=yes bash "$trigger" 2>&1)"
}
run_trigger /elsewhere
[ ! -s "$trig/calls" ] || fail "trigger must skip a scratch-dest apply" "$trig_out"
run_trigger "$trig/home"
grep -qx -- "--user daemon-reload" "$trig/calls" || fail "trigger never reloads systemd"
grep -qx -- "--user enable --now agent-notify.timer agent-trends.timer" "$trig/calls" || fail "trigger does not enable both timers" "$(cat "$trig/calls")"
grep -q "start " "$trig/calls" && fail "trigger must not start a run"
grep -q "agent-trends.service" "$trigger" && grep -q "agent-trends.timer" "$trigger" || fail "trigger must hash the trends units too"

echo "test_agent_notify_script: OK"
