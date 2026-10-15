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
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'; [ -z \"\${srv:-}\" ] || kill \"\$srv\" 2>/dev/null" EXIT
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
echo "$1 $2 token=${GH_TOKEN:-none}" >>"$GH_ENVLOG"
if [ "$1 $2" = "issue comment" ] && [ -n "${GH_TOKEN:-}" ] && [ -e "$GH_APPDENY" ]; then echo "GraphQL: Resource not accessible by integration (addComment)" >&2; exit 1; fi
if [ -e "$GH_FAIL" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
if [ "$1 $2" = "issue comment" ] && [ -s "$GH_REPO_FAIL" ] && [[ " $* " == *" --repo $(cat "$GH_REPO_FAIL") "* ]]; then echo "gh: HTTP 500" >&2; exit 1; fi
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
export GH_ENVLOG="$tmp/gh.env" GH_APPDENY="$tmp/gh.appdeny"
export GH_REPO_FAIL="$tmp/gh.repofail"
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
grep -qx -- "--user enable --now agent-notify.timer agent-notify-digest.timer agent-trends.timer" "$trig/calls" || fail "trigger does not enable all three timers" "$(cat "$trig/calls")"
grep -q "start " "$trig/calls" && fail "trigger must not start a run"
grep -q "agent-notify-digest.service" "$trigger" && grep -q "agent-notify-digest.timer" "$trigger" || fail "trigger must hash the digest units too"
grep -q "agent-trends.service" "$trigger" && grep -q "agent-trends.timer" "$trigger" || fail "trigger must hash the trends units too"

# ── A replacement issue that cannot be found or created posts nothing, so the date is not kept ──
rm -f "$state/notify-issue" "$state/notified.json" "$GH_FAIL" "$GH_GONE" "$GH_SLOW" "$GH_COMMENT_FAIL" "$GH_NOPIN"
echo '[]' >"$GH_LIST"
write_flags 2026-10-20
run 0 send
write_flags 2026-10-21
issue_mem | cut -d' ' -f2 >"$GH_COMMENT_FAIL"
echo CLOSED >"$GH_VIEW"
echo 'not a list' >"$GH_LIST"
run 1 send
if grep -q "2026-10-21" "$state/notified.json"; then fail "a send that could not find a replacement issue kept the date as notified"; fi
rm -f "$GH_COMMENT_FAIL" "$GH_VIEW"
echo '[]' >"$GH_LIST"

# ── Channels: config selects them, a bad one is refused, one failing does not block another ──
set_notify() { python3 - "$tmp/config/config.json" "$1" <<'PY'
import json, sys
json.dump({"store_remote": "git@github.com:acme/metrics.git", "notify": json.loads(sys.argv[2])}, open(sys.argv[1], "w"))
PY
}
default_config='{"store_remote": "git@github.com:acme/metrics.git"}'
reset_state
write_flags 2026-10-08
set_notify '{"channels": [{"type": "carrier-pigeon"}]}'
run 2 send
grep -q "^error:" "$out" && grep -q "carrier-pigeon" "$out" || fail "an unknown channel type is not a structured error" "$(cat "$out")"
[ "$(calls)" = 0 ] || fail "a bad channel config must not call gh"
set_notify '{"channels": [{"type": "github-issue"}, {"type": "github-issue"}]}'
run 2 send
grep -q "used twice" "$out" || fail "two unnamed channels of one type must be refused" "$(cat "$out")"
set_notify '{"channels": []}'
run 2 send
set_notify '[1]'
run 2 send

set_notify '{"channels": [{"type": "github-issue", "name": "main"}, {"type": "github-issue", "name": "mirror", "repo": "acme/mirror"}]}'
echo acme/metrics >"$GH_REPO_FAIL"
run 1 send
grep -q -- "--repo acme/mirror" "$GH_COMMENTS" || fail "a failing channel stopped the other from posting" "$(cat "$out" "$GH_LOG")"
grep -q "main" "$out" && grep -q "failed" "$out" && grep -q "sent" "$out" || fail "the outcome does not report each channel" "$(cat "$out")"
if grep -q "2026-10-08" "$state/main.notified.json" 2>/dev/null; then fail "the failed channel kept the date"; fi
grep -q "2026-10-08" "$state/mirror.notified.json" || fail "the channel that posted did not record the date" "$(ls "$state")"
rm -f "$GH_REPO_FAIL"
: >"$GH_COMMENTS"
run 0 send
[ "$(comments)" = 1 ] && grep -q -- "--repo acme/metrics" "$GH_COMMENTS" || fail "the retry should post only on the channel that had failed" "$(cat "$GH_COMMENTS")"
echo "$default_config" >"$tmp/config/config.json"
reset_state
write_flags 2026-10-08
run 0 send
[ "$(comments)" = 1 ] && [ -e "$state/notified.json" ] || fail "default config no longer uses the single gh channel and legacy state"

# ── App identity: a minted token reaches gh only through its environment ──
command -v openssl >/dev/null || fail "openssl is needed for the app identity tests"
unset GH_TOKEN GITHUB_TOKEN
mkdir -p "$tmp/app"
openssl genrsa -out "$tmp/app/key.pem" 2048 2>/dev/null
openssl rsa -in "$tmp/app/key.pem" -pubout -out "$tmp/app/pub.pem" 2>/dev/null
cat >"$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$KUBECTL_LOG"
if [ -e "$KUBECTL_FAIL" ]; then echo "Unable to connect to the server" >&2; exit 1; fi
case "$*" in
    "-n ai-sre get secret ai-sre-relay -o jsonpath={.data.GITHUB_APP_ID}") printf 4242 | base64 -w0 ;;
    "-n ai-sre get secret ai-sre-relay -o jsonpath={.data.GITHUB_APP_PRIVATE_KEY}") base64 -w0 <"$APP_KEY" ;;
    *) echo "unexpected kubectl call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"
cat >"$tmp/app/server.py" <<'PY'
import base64, http.server, json, os, subprocess, sys

d = sys.argv[1]
TOKEN = "ghs_FAKEINSTALLATIONTOKEN0001"


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def jwt_ok(self):
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        try:
            head, payload, sig = auth[7:].split(".")
            claims = json.loads(b64d(payload))
            open(d + "/sig", "wb").write(b64d(sig))
            r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", d + "/pub.pem", "-signature", d + "/sig"],
                               input=f"{head}.{payload}".encode(), capture_output=True)
            return r.returncode == 0 and claims.get("iss") == "4242" and json.loads(b64d(head)).get("alg") == "RS256"
        except Exception:
            return False

    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        ok = self.jwt_ok()
        open(d + "/requests", "a").write(f"{method} {self.path} jwt={'valid' if ok else 'INVALID'} body={body}\n")
        if not ok:
            return self.reply(401, {"message": "Bad credentials"})
        if method == "GET" and self.path == "/repos/acme/metrics/installation":
            if os.path.exists(d + "/install404"):
                return self.reply(404, {"message": "Not Found"})
            return self.reply(200, {"id": 777})
        if method == "POST" and self.path == "/app/installations/777/access_tokens":
            if os.path.exists(d + "/exchange403"):
                return self.reply(403, {"message": "Resource not accessible by integration"})
            return self.reply(201, {"token": TOKEN, "expires_at": "2026-10-09T13:00:00Z"})
        self.reply(404, {"message": "Not Found"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(d + "/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 "$tmp/app/server.py" "$tmp/app" &
srv=$!
for _ in $(seq 50); do [ -s "$tmp/app/port" ] && break; sleep 0.1; done
[ -s "$tmp/app/port" ] || fail "fake GitHub API did not start"
api_port="$(cat "$tmp/app/port")"
export AGENT_NOTIFY_API_URL="http://127.0.0.1:$api_port"
export KUBECTL_LOG="$tmp/kubectl.log" KUBECTL_FAIL="$tmp/kubectl.fail" APP_KEY="$tmp/app/key.pem"
token=ghs_FAKEINSTALLATIONTOKEN0001
app_reset() { reset_state; rm -f "$GH_ENVLOG" "$GH_APPDENY" "$KUBECTL_FAIL" "$tmp/app/install404" "$tmp/app/exchange403" "$tmp/app/requests" "$KUBECTL_LOG"; touch "$GH_ENVLOG" "$tmp/app/requests"; write_flags 2026-10-08; }
no_secrets() {  # nothing the App touched may surface anywhere a human or a log could read it
    local f
    for f in "$out" "$err" "$GH_LOG" "$KUBECTL_LOG"; do
        if grep -q "$token" "$f"; then fail "the installation token appears in $(basename "$f")" "$(cat "$f")"; fi
        if grep -q "BEGIN" "$f"; then fail "key material appears in $(basename "$f")"; fi
    done
    if grep -rq "$token" "$state"; then fail "the installation token reached the state directory"; fi
    if grep -rqE "BEGIN|eyJ" "$state"; then fail "key or JWT material reached the state directory"; fi
}
set_notify '{"channels": [{"type": "github-issue", "identity": "app"}]}'

app_reset
run 0 send
grep -q "^sent: true" "$out" || fail "app send did not report sent" "$(cat "$out")"
grep -q "app" "$out" || fail "the output does not name the app identity" "$(cat "$out")"
grep -qx "issue comment token=$token" "$GH_ENVLOG" || fail "the comment did not carry the App token in GH_TOKEN" "$(cat "$GH_ENVLOG")"
grep -q "issue list token=none" "$GH_ENVLOG" || fail "issue lookup should stay with the gh login" "$(cat "$GH_ENVLOG")"
[ "$(comments)" = 1 ] || fail "app send should post once"
grep -q "jwt=valid" "$tmp/app/requests" && ! grep -q "INVALID" "$tmp/app/requests" || fail "the App JWT was not a valid RS256 signature for the App id" "$(cat "$tmp/app/requests")"
grep -q 'access_tokens jwt=valid body={"repositories": \["metrics"\]}' "$tmp/app/requests" || fail "the token was not scoped to the repository alone" "$(cat "$tmp/app/requests")"
no_secrets
run 0 send
grep -qi "already" "$out" || fail "app identity broke at-most-once" "$(cat "$out")"
[ "$(comments)" = 1 ] || fail "app identity reposted a notified date"

# not installed: 404 falls back to gh, loudly
app_reset
touch "$tmp/app/install404"
run 0 send
grep -qx "issue comment token=none" "$GH_ENVLOG" || fail "the fallback comment should use the gh login" "$(cat "$GH_ENVLOG")"
grep -q "fallback" "$out" && grep -q "not installed" "$out" || fail "a 404 fallback does not say why" "$(cat "$out")"
grep -q "^help" "$out" && grep -q "jdwlabs-agent-bot" "$out" && grep -q "Issues" "$out" || fail "the fallback has no install help" "$(cat "$out")"
grep -q "gh" "$out" || fail "the fallback output does not name the gh identity"
[ "$(comments)" = 1 ] || fail "the fallback should still post once"
no_secrets

# exchange refused with 403
app_reset
touch "$tmp/app/exchange403"
run 0 send
grep -q "403" "$out" && grep -q "fallback" "$out" || fail "a refused exchange does not fall back with a reason" "$(cat "$out")"
grep -qx "issue comment token=none" "$GH_ENVLOG" || fail "fallback should post as gh" "$(cat "$GH_ENVLOG")"
no_secrets

# App lacks the issues permission: gh refuses the comment, gh identity posts it
app_reset
touch "$GH_APPDENY"
run 0 send
grep -q "Resource not accessible" "$out" && grep -q "fallback" "$out" || fail "a refused comment does not fall back with a reason" "$(cat "$out")"
grep -qx "issue comment token=$token" "$GH_ENVLOG" && grep -qx "issue comment token=none" "$GH_ENVLOG" || fail "expected one App attempt then one gh post" "$(cat "$GH_ENVLOG")"
[ "$(comments)" = 1 ] || fail "the refused comment must be posted exactly once"
grep -q "Install" "$out" || fail "no install help on a permission fallback" "$(cat "$out")"
no_secrets

# kubectl missing or failing
app_reset
touch "$KUBECTL_FAIL"
run 0 send
grep -q "fallback" "$out" && grep -qi "kubectl" "$out" || fail "a kubectl failure does not fall back with a reason" "$(cat "$out")"
[ "$(comments)" = 1 ] || fail "kubectl failure should still post as gh"
no_secrets
app_reset
mkdir -p "$tmp/nokube"
for t in python3 env bash cat base64 openssl timeout rm mkdir; do ln -sf "$(command -v $t)" "$tmp/nokube/$t"; done
ln -sf "$tmp/bin/gh" "$tmp/nokube/gh"
PATH="$tmp/nokube" "$(command -v python3)" "$notify" send >"$out" 2>"$err" || fail "send without kubectl on PATH should still succeed" "$(cat "$out" "$err")"
grep -q "kubectl is not installed" "$out" || fail "a missing kubectl is not named" "$(cat "$out")"

# dry run mints nothing
app_reset
run 0 send --dry-run
[ ! -s "$tmp/app/requests" ] && [ ! -e "$KUBECTL_LOG" ] || fail "a dry run touched the credentials or the API"

echo "$default_config" >"$tmp/config/config.json"
unset AGENT_NOTIFY_API_URL

# ── Digest units ──
dsvc="$units/agent-notify-digest.service"
dtimer="$units/agent-notify-digest.timer"
grep -qx 'ExecStart=%h/.local/bin/agent-notify digest' "$dsvc" || fail "digest service ExecStart"
grep -qx 'NoNewPrivileges=yes' "$dsvc" && grep -qx 'PrivateTmp=yes' "$dsvc" || fail "digest service hardening missing"
grep -q '^TimeoutStartSec=' "$dsvc" && grep -q '^Environment=PATH=.*/usr/bin' "$dsvc" || fail "digest service needs a timeout and a PATH that reaches kubectl"
grep -qxF "OnCalendar=Mon *-*-* 09:10:00 UTC" "$dtimer" || fail "digest timer calendar"
grep -qx "Unit=agent-notify-digest.service" "$dtimer" && grep -qx "Persistent=true" "$dtimer" && grep -qx "WantedBy=timers.target" "$dtimer" || fail "digest timer wiring"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "Mon *-*-* 09:10:00 UTC" >/dev/null || fail "digest calendar rejected by systemd"
    mkdir -p "$tmp/verify"
    cp "$dsvc" "$dtimer" "$tmp/verify/"
    mkdir -p "$tmp/verify/bin" && printf '#!/bin/sh\n' >"$tmp/verify/bin/agent-notify" && chmod +x "$tmp/verify/bin/agent-notify"
    sed -i "s#%h/.local/bin/agent-notify#$tmp/verify/bin/agent-notify#" "$tmp/verify/agent-notify-digest.service"
    verify_out="$(systemd-analyze --user verify "$tmp/verify/agent-notify-digest.service" "$tmp/verify/agent-notify-digest.timer" 2>&1)" || fail "systemd-analyze verify rejects the digest units" "$verify_out"
fi

# ── Digest ──
set_notify '{"dashboard_url": "https://dash.example/metrics", "channels": [{"type": "github-issue"}]}'
reset_state
rm -rf "$tmp/store/reports"
run 0 digest
grep -q "^sent: false" "$out" && grep -qi "no weekly report" "$out" || fail "no weekly report should be a definitive empty state" "$(cat "$out")"
[ "$(calls)" = 0 ] || fail "the empty state called gh"
store="$tmp/store"
mkdir -p "$store/reports"
python3 - "$store/reports" <<'PY'
import json, sys
d = sys.argv[1]
def pop(cost, sessions, linked, per_pr, peak):
    return {"populations": {"interactive": {"sessions": sessions, "cost_usd": cost, "output": {"linked_prs": linked},
                                            "linked_pr_cost": {"cost_per_linked_pr_usd": per_pr}}},
            "quota": {"peak_seven_day_pct": peak}}
def weekly(label, start, end):
    return {"schema": 1, "window": "weekly", "start": start, "end": end, "label_date": label,
            "current": pop(200.0, 10, 8, 25.0, 40), "previous": pop(100.0, 10, 0, None, None), "flags": []}
json.dump(weekly("2026-10-04", "2026-09-28", "2026-10-05"), open(d + "/2026-10-04-weekly.json", "w"))
json.dump(weekly("2026-10-11", "2026-10-05", "2026-10-12"), open(d + "/2026-10-11-weekly.json", "w"))
for day, flags in (("2026-10-06", [{"id": "day-spend", "severity": "warn", "message": "spend @octocat fixes #12 https://evil.example <b>x</b>"}]),
                   ("2026-10-08", [{"id": "weekly-quota", "severity": "critical", "message": "quota high"}]),
                   ("2026-10-09", []), ("2026-10-13", [{"id": "outside-window", "severity": "warn", "message": "next week"}])):
    json.dump({"window": "daily", "label_date": day, "flags": flags}, open(f"{d}/{day}-daily.json", "w"))
PY
run 0 digest --dry-run
[ "$(calls)" = 0 ] && [ ! -e "$state/digest-notified.json" ] || fail "digest dry run called gh or wrote state"
grep -q "2026-10-05 to 2026-10-11" "$out" || fail "digest does not state the window" "$(cat "$out")"
grep -q "Estimated spend | \$200.00 | \$100.00 | +100%" "$out" || fail "spend row wrong" "$(cat "$out")"
grep -q "Linked PRs | 8 | 0 | n/a" "$out" || fail "a change against zero should be n/a" "$(cat "$out")"
grep -q "Peak weekly quota | 40% | n/a | n/a" "$out" || fail "a missing previous value should be n/a" "$(cat "$out")"
grep -q "day-spend" "$out" && grep -q "weekly-quota" "$out" || fail "the week's flags are missing" "$(cat "$out")"
if grep -q "outside-window" "$out"; then fail "a flag from outside the window was listed"; fi
grep -q "Dashboard: https://dash.example/metrics/" "$out" && grep -q "This report: https://dash.example/metrics/reports/2026-10-11-weekly.html" "$out" || fail "dashboard links missing" "$(cat "$out")"
set_notify '{"channels": [{"type": "github-issue"}]}'
run 0 digest --dry-run
if grep -qE "Dashboard:|This report:" "$out"; then fail "links appeared without dashboard_url" "$(cat "$out")"; fi
set_notify '{"dashboard_url": "javascript:alert(1)", "channels": [{"type": "github-issue"}]}'
run 2 digest --dry-run
set_notify '{"dashboard_url": "https://dash.example/metrics", "channels": [{"type": "github-issue"}]}'

run 0 digest
grep -q '^issue create --repo acme/metrics --title Agent metrics: weekly digest' "$GH_LOG" || fail "digest did not use its own issue" "$(cat "$GH_LOG")"
grep -q "Weekly digest" "$GH_BODY" || fail "digest body not posted" "$(cat "$GH_BODY")"
grep -q "2026-10-11" "$state/digest-notified.json" || fail "digest date not recorded"
[ ! -e "$state/notified.json" ] || fail "the digest must not touch the daily flags record"
python3 - "$GH_BODY" <<'PY' || fail "data rendered as a mention, reference or link in the digest" "$(cat "$GH_BODY")"
import re, sys
for line in open(sys.argv[1]):
    if line.startswith("- `"):
        outside = re.sub(r"`[^`]*`", "", line)
        assert not re.search(r"[@#<>]|https?:", outside), line
assert "`spend @octocat fixes #12 https://evil.example <b>x</b>`" in open(sys.argv[1]).read()
PY
run 0 digest
grep -qi "already" "$out" || fail "a repeat digest should say it already notified" "$(cat "$out")"
[ "$(comments)" = 1 ] || fail "a repeat digest posted again"
run 0 digest --force
[ "$(comments)" = 2 ] || fail "--force should post the digest again"
run 0 digest --date 2026-10-04 --dry-run
grep -q "2026-09-28 to 2026-10-04" "$out" || fail "--date did not pick the older report" "$(cat "$out")"
run 0 digest --date 2026-01-01
grep -qi "no weekly report" "$out" || fail "an absent --date should be an empty state" "$(cat "$out")"
run 2 digest --date soon
rm -rf "$tmp/store/reports"
echo "$default_config" >"$tmp/config/config.json"

echo "test_agent_notify_script: OK"
