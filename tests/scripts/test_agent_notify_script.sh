#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in the strings are literal markdown, not substitutions
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
    "issue create") echo "https://github.com/acme/metrics/issues/$(cat "$GH_CREATE_N" 2>/dev/null || echo 41)" ;;
    "issue comment")
        if [ -e "$GH_SLOW" ]; then sleep "$(cat "$GH_SLOW")"; fi
        if grep -qx "$3" "$GH_COMMENT_FAIL" 2>/dev/null; then echo "gh: issue is locked" >&2; exit 1; fi
        echo "$*" >>"$GH_COMMENTS"
        cat >"$GH_BODY" ;;
    "issue view")
        if [ -e "$GH_GONE" ]; then echo "GraphQL: Could not resolve to an issue with the number of $3." >&2; exit 1; fi
        echo "{\"state\":\"$(cat "$GH_VIEW" 2>/dev/null || echo OPEN)\"}" ;;
    "issue pin") [ -e "$GH_NOPIN" ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log" GH_FAIL="$tmp/gh.fail" GH_LIST="$tmp/gh.list" GH_BODY="$tmp/gh.body" GH_NOPIN="$tmp/gh.nopin"
export GH_SLOW="$tmp/gh.slow" GH_COMMENT_FAIL="$tmp/gh.commentfail" GH_COMMENTS="$tmp/gh.comments" GH_VIEW="$tmp/gh.view" GH_GONE="$tmp/gh.gone" GH_CREATE_N="$tmp/gh.createn"
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
issue_mem() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["number"])' "$state/notify-issue"; }
comments() { if [ -e "$GH_COMMENTS" ]; then wc -l <"$GH_COMMENTS" | tr -d ' '; else echo 0; fi; }
trun() {  # like run, but a hang is a failure
    local want="$1" got=0
    shift
    timeout 10 "$notify" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-notify $* exited $got, want $want (124 is a hang)" "$(cat "$out" "$err")"
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
[ "$(issue_mem)" = "acme/metrics 41" ] || fail "issue number not remembered with its repo" "$(cat "$state/notify-issue")"
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
[ "$(issue_mem)" = "acme/metrics 7" ] || fail "found issue not remembered"
rm -f "$GH_NOPIN"
echo '[{"number": 3, "title": "Agent metrics: flagged days (old)"}]' >"$GH_LIST"
rm -f "$state/notify-issue" "$state/notified.json"
touch "$GH_NOPIN"
run 0 send
[ "$(issue_mem)" = "acme/metrics 41" ] || fail "a near-match title must not be adopted"
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


# ── State files are untrusted: a FIFO or a device never hangs or floods ──
reset_state() { rm -rf "$state"; mkdir -p "$state"; : >"$GH_LOG"; rm -f "$GH_COMMENTS" "$GH_SLOW" "$GH_FAIL" "$GH_COMMENT_FAIL" "$GH_VIEW" "$GH_GONE" "$GH_CREATE_N"; echo '[]' >"$GH_LIST"; }
for kind in fifo zero; do
    reset_state
    if [ "$kind" = fifo ]; then mkfifo "$state/flags.json"; else ln -s /dev/zero "$state/flags.json"; fi
    trun 0 shell
    [ ! -s "$out" ] || fail "shell printed for a $kind flags file" "$(cat "$out")"
    trun 2 send
    grep -q "flags.json" "$out" || fail "send does not name a $kind flags file" "$(cat "$out")"
    trun 2 show
    rm -f "$state/flags.json"
    write_flags 2026-10-08
    for f in acked.json notified.json notify-issue; do
        rm -f "$state/$f"
        if [ "$kind" = fifo ]; then mkfifo "$state/$f"; else ln -s /dev/zero "$state/$f"; fi
    done
    trun 0 shell
    trun 0
    rm -f "$state/acked.json" "$state/notified.json" "$state/notify-issue"
done

# ── Nothing from the file reaches the terminal, the shell line or the comment ──
reset_state
python3 - "$state/flags.json" <<'PY'
import json, sys
json.dump({"date": "2026-10-08", "flags": [
    {"id": "\x1b[31mspoof", "severity": "critical", "metric": "m", "message": "red \x1b]0;title\x07 text \u009b31m end ‮evil⁦  done"},
    {"id": "ok-id", "severity": "\x1b[2Jwarn", "message": "plain message"}]}, open(sys.argv[1], "w"))
PY
run 0 show
python3 - "$out" <<'PY' || fail "show let a control or format character through" "$(cat "$out")"
import sys, unicodedata
text = open(sys.argv[1], encoding="utf-8").read()
bad = [c for c in text if c != "\n" and unicodedata.category(c)[0] == "C"]
assert not bad, [hex(ord(c)) for c in bad]
assert "_invalid" in text and "plain message" in text and "red" in text and "done" in text
PY
run 0 send --dry-run
python3 - "$out" <<'PY' || fail "the comment preview let a control or format character through" "$(cat "$out")"
import sys, unicodedata
text = open(sys.argv[1], encoding="utf-8").read()
bad = [c for c in text if c != "\n" and unicodedata.category(c)[0] == "C"]
assert not bad, [hex(ord(c)) for c in bad]
PY

# ── The comment interprets nothing from the file ──
reset_state
python3 - "$state/flags.json" <<'PY'
import json, sys
json.dump({"date": "2026-10-08", "flags": [
    {"id": "spend", "severity": "warn", "message": "[click](http://evil.invalid) ![i](http://e.invalid/i.png) <img src=x> #1 owner/repo#2 @bob `tick`"}]},
    open(sys.argv[1], "w"))
PY
run 0 send
grep -qF '`[click](http://evil.invalid) ![i](http://e.invalid/i.png) <img src=x> #1 owner/repo#2 @bob tick`' "$GH_BODY" || fail "a flag message is not wrapped whole in inline code with backticks stripped" "$(cat "$GH_BODY")"
grep -qF -- '- `warn` `spend`: ' "$GH_BODY" || fail "severity and id are not in inline code" "$(cat "$GH_BODY")"
grep -qF 'Daily report: `reports/2026-10-08-daily.json`' "$GH_BODY" || fail "the report location should be a plain path in code" "$(cat "$GH_BODY")"
if grep -F "blob/main" "$GH_BODY"; then fail "the comment still links to the report"; fi

# ── Repo names are validated ──
for bad in "https://github.com/acme/r).git" "git@github.com:acme/a b" "https://github.com/-x/y" "https://github.com/acme/.."; do
    echo "{\"store_remote\": \"$bad\"}" >"$tmp/config/config.json"
    reset_state
    write_flags 2026-10-08
    run 2 send
    [ "$(calls)" = 0 ] || fail "send called gh for the repo $bad"
done
echo '{"store_remote": "git@github.com:acme/metrics.git"}' >"$tmp/config/config.json"
reset_state
write_flags 2026-10-08
AGENT_NOTIFY_REPO='acme/x y' run 2 send
AGENT_NOTIFY_REPO='acme/metrics' run 0 send --dry-run

# ── Non-ASCII digits are not a date ──
reset_state
python3 - "$state/flags.json" <<'PY'
import json, sys
json.dump({"date": "٢٠٢٦-١٠-٠٨", "flags": [{"id": "a", "severity": "warn", "message": "m"}]}, open(sys.argv[1], "w"))
PY
run 2 send
trun 0 shell
[ ! -s "$out" ] || fail "shell showed a file with a non-ASCII date" "$(cat "$out")"

# ── Two sends at once post one comment ──
reset_state
write_flags 2026-10-08
echo 1 >"$GH_SLOW"
"$notify" send >"$tmp/o1" 2>&1 &
p1=$!
"$notify" send >"$tmp/o2" 2>&1 &
p2=$!
wait "$p1" "$p2" || fail "a concurrent send failed" "$(cat "$tmp/o1" "$tmp/o2")"
[ "$(comments)" = 1 ] || fail "concurrent sends posted $(comments) comments" "$(cat "$tmp/o1" "$tmp/o2")"

# ── A timeout may have posted: record first, report loudly, never repost silently ──
reset_state
write_flags 2026-10-08
echo 5 >"$GH_SLOW"
AGENT_NOTIFY_GH_TIMEOUT=1 run 1 send
grep -q "may have been posted" "$out" || fail "a timeout is not reported as possibly posted" "$(cat "$out")"
grep -q "2026-10-08" "$state/notified.json" || fail "a timed-out send must keep the date recorded"
rm -f "$GH_SLOW"
run 0 send
grep -qi "already" "$out" || fail "the run after a timeout should not repost" "$(cat "$out")"
[ "$(comments)" = 0 ] || fail "reposted after a timeout"
run 0 send --force
[ "$(comments)" = 1 ] || fail "--force should post again"

# ── Unwritable state: nothing is posted ──
reset_state
write_flags 2026-10-08
mkdir "$state/notified.json"
run 1 send
grep -q "notified.json" "$out" || fail "an unwritable notified.json is not named" "$(cat "$out")"
[ "$(comments)" = 0 ] || fail "posted although the date could not be recorded"
rmdir "$state/notified.json"

# ── A closed or deleted tracking issue is replaced once ──
for mode in closed gone; do
    reset_state
    write_flags 2026-10-08
    echo '{"repo": "acme/metrics", "number": 41}' >"$state/notify-issue"
    echo 41 >"$GH_COMMENT_FAIL"
    echo 52 >"$GH_CREATE_N"
    if [ "$mode" = closed ]; then echo CLOSED >"$GH_VIEW"; else touch "$GH_GONE"; fi
    run 0 send
    [ "$(issue_mem)" = "acme/metrics 52" ] || fail "the replacement issue ($mode) was not remembered" "$(cat "$state/notify-issue")"
    grep -q '^issue comment 52 ' "$GH_COMMENTS" || fail "the comment did not land on the replacement ($mode)" "$(cat "$GH_COMMENTS" "$GH_LOG")"
    grep -q "2026-10-08" "$state/notified.json" || fail "date not recorded after replacing the issue ($mode)"
done
# An open issue that refuses a comment is a real failure, not a reason to open another.
reset_state
write_flags 2026-10-08
echo '{"repo": "acme/metrics", "number": 41}' >"$state/notify-issue"
echo 41 >"$GH_COMMENT_FAIL"
run 1 send
grep -q '^issue create' "$GH_LOG" && fail "created an issue although the remembered one is open"
if grep -q "2026-10-08" "$state/notified.json" 2>/dev/null; then fail "a definite failure left the date recorded"; fi

# ── A remembered issue belongs to one repository ──
for mem in '{"repo": "other/place", "number": 9}' '41' '{"number": 9}'; do
    reset_state
    write_flags 2026-10-08
    echo "$mem" >"$state/notify-issue"
    run 0 send
    grep -q '^issue list --repo acme/metrics' "$GH_LOG" || fail "a remembered issue for another repo was trusted ($mem)" "$(cat "$GH_LOG")"
    grep -q '^issue comment 9 ' "$GH_LOG" && fail "commented on another repo's issue number ($mem)"
    [ "$(issue_mem)" = "acme/metrics 41" ] || fail "memory not rewritten for this repo ($mem)"
done

# ── Shell hook: terminals only, and quiet once acknowledged ──
hook="$here/home/dot_config/shell/functions.sh"
mkdir -p "$tmp/hookbin"
printf '#!/bin/sh\necho "STUB-CALLED"\n' >"$tmp/hookbin/agent-notify"
chmod +x "$tmp/hookbin/agent-notify"
hook_run() {  # $1 tty|pipe -> stdout of a shell sourcing the hook
    python3 - "$1" "$hook" "$tmp/hookbin" <<'PY'
import os, pty, subprocess, sys
mode, hook, binpath = sys.argv[1:]
env = {**os.environ, "PATH": binpath + ":" + os.environ["PATH"]}
cmd = ["bash", "-c", f'source "{hook}"']
if mode == "pipe":
    sys.stdout.write(subprocess.run(cmd, env=env, capture_output=True, text=True).stdout)
else:
    master, slave = pty.openpty()
    subprocess.run(cmd, env=env, stdout=slave, stderr=subprocess.DEVNULL)
    os.close(slave)
    sys.stdout.write(os.read(master, 4096).decode())
PY
}
reset_state
write_flags 2026-10-08
[ -z "$(hook_run pipe)" ] || fail "the shell hook wrote to a pipe"
hook_run tty 2>/dev/null | grep -q STUB-CALLED || fail "the shell hook did not run for a terminal with pending flags"
touch -d "2 hours ago" "$state/flags.json"
echo '{"dates": ["2026-10-08"]}' >"$state/acked.json"
if hook_run tty 2>/dev/null | grep -q STUB-CALLED; then fail "the shell hook started agent-notify for an acknowledged date"; fi
touch "$state/flags.json"
hook_run tty 2>/dev/null | grep -q STUB-CALLED || fail "a newer flags file must be announced again"

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
