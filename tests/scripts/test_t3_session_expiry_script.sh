#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
check="$here/home/dot_local/bin/executable_t3-session-expiry"
svc="$here/home/dot_config/systemd/user/t3-session-expiry.service"
timer="$here/home/dot_config/systemd/user/t3-session-expiry.timer"
trigger="$here/home/run_onchange_51-enable-t3-session-expiry.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$check" ] || fail "t3-session-expiry missing or not executable"
for f in "$svc" "$timer" "$trigger"; do
    [ -f "$f" ] || fail "missing $(basename "$f")"
done
shellcheck -s bash "$check"
shellcheck -s bash "$trigger"

# ── Unit wiring ──
grep -q '^Type=oneshot$' "$svc" || fail "check service is not Type=oneshot"
grep -q '^ExecStart=%h/.local/bin/t3-session-expiry$' "$svc" \
    || fail "ExecStart does not point at the deployed check"
# A non-zero exit is the warning signal; masking it would hide the one state
# the unit exists to surface.
grep -q '^SuccessExitStatus=' "$svc" && fail "a warning exit must stay a unit failure"
# Timer-triggered only: an [Install] here would also run it once at login and
# then never again, which silently replaces the schedule.
grep -q '^\[Install\]' "$svc" && fail "check service should be timer-triggered only"

grep -q '^OnCalendar=' "$timer" || fail "timer is not calendar-scheduled"
# Persistent= is honoured only for calendar timers, and a box that was off
# must not silently eat days out of the warning window.
grep -q '^Persistent=true$' "$timer" || fail "timer does not catch up after downtime"
grep -q '^WantedBy=timers.target$' "$timer" || fail "timer will not be started by systemd"

for dep in t3-session-expiry.service t3-session-expiry.timer executable_t3-session-expiry; do
    grep -q "$dep" "$trigger" || fail "$dep edits do not re-trigger daemon-reload"
done
grep -q 'daemon-reload' "$trigger" || fail "trigger never reloads systemd"
grep -q 'enable --now t3-session-expiry.timer' "$trigger" || fail "trigger never enables the timer"
# systemctl acts on the real home regardless of chezmoi's destination, so a
# scratch-dest apply must skip rather than enable a timer for the live user.
grep -q 'skipping enable' "$trigger" || fail "trigger does not skip on a non-home apply"

# ── Sealed execution environment ──
# The real box has no `t3` on PATH but does have `npx`, and a stray HOME would
# let the check recover nvm's node and reach the network. Both are sealed off:
# PATH is built from scratch and HOME points at an empty sandbox, so the only
# t3 reachable is the stub each case installs.
tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
mkdir -p "$tmp/bin" "$tmp/sys" "$tmp/home" "$tmp/state"
for b in env bash sh cat date ls sort tail mkdir rm; do
    src="$(command -v "$b")" || fail "test host is missing $b"
    ln -s "$src" "$tmp/sys/$b"
done
sealed="$tmp/bin:$tmp/sys"
bash_bin="$(command -v bash)"
marker="$tmp/state/t3-session-expiry.warn"

stub_t3() {  # heredoc on stdin becomes the stub's stdout; $1 = exit code
    { echo '#!/bin/sh'
      echo "cat <<'T3EOF'"
      cat
      echo 'T3EOF'
      echo "exit ${1:-0}"
    } >"$tmp/bin/t3"
    chmod +x "$tmp/bin/t3"
}

run_check() {  # $@ = args to the check; sets $out and $rc
    set +e
    out="$(PATH="$sealed" HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" \
        "$bash_bin" "$check" "$@" 2>&1)"
    rc=$?
    set -e
}

record() {  # $1 = expiry timestamp, $2 = session id
    printf '%s\n  scopes: orchestration:read terminal:operate\n  method: browser-session-cookie\n  client: iphone | mobile | iOS | Safari | 127.0.0.1\n  issued: 2026-08-29T19:14:55.938Z\n  last connected: 2026-08-29T19:14:56.207Z\n  expires: %s\n' "$2" "$1"
}

far="$(date -u -d '+25 days' +%Y-%m-%dT%H:%M:%S.000Z)"
near="$(date -u -d '+3 days' +%Y-%m-%dT%H:%M:%S.000Z)"
gone="$(date -u -d '-2 days' +%Y-%m-%dT%H:%M:%S.000Z)"

# ── A session far from expiry stays quiet ──
record "$far" "1be6de72-be59-44da-8511-581328ead55b" | stub_t3
run_check
[ "$rc" -eq 0 ] || fail "warned about a session 25 days out" "$out"
echo "$out" | grep -q "none expiring within 7d" || fail "no all-clear for a healthy session" "$out"
[ -e "$marker" ] && fail "wrote a warning marker with nothing due" "$out"

# ── A session inside the window warns, names itself, and exits non-zero ──
record "$near" "1be6de72-be59-44da-8511-581328ead55b" | stub_t3
run_check
[ "$rc" -eq 0 ] && fail "exited 0 with a session 3 days from expiry" "$out"
echo "$out" | grep -q "1be6de72-be59-44da-8511-581328ead55b" || fail "warning does not name the session" "$out"
echo "$out" | grep -q "iphone" || fail "warning does not name the device" "$out"
[ -f "$marker" ] || fail "no marker left for a due session" "$out"

# ── Threshold is overridable, and the marker is retracted on a clean run ──
# Same fixture, tighter window: proves the default is a threshold and not a
# hardcoded verdict, and that a later all-clear clears the earlier warning.
run_check 1
[ "$rc" -eq 0 ] || fail "a 3-day session warned against a 1-day threshold" "$out"
[ -e "$marker" ] && fail "stale marker survived an all-clear" "$out"

# ── An already-lapsed session is reported, not treated as absent ──
record "$gone" "dead-session" | stub_t3
run_check
[ "$rc" -eq 0 ] && fail "exited 0 with an already-expired session" "$out"
echo "$out" | grep -qi "expired" || fail "lapsed session not reported as expired" "$out"

# ── Malformed: a record whose expiry is unreadable ──
# Must not silently pass. `date -d ""` yields midnight today and exits 0, so a
# blank expiry that slipped through would read as "expiring right now".
record "not-a-timestamp" "malformed-session" | stub_t3
run_check
[ "$rc" -eq 0 ] && fail "exited 0 with an unparseable expiry" "$out"
echo "$out" | grep -q "could not read an expiry" || fail "no diagnostic for a bad expiry" "$out"
echo "$out" | grep -q "none expiring" && fail "false all-clear on an unparseable expiry" "$out"

# ── Malformed: a record with no expires line at all ──
printf 'no-expiry-session\n  scopes: relay:read\n  client: iphone\n' | stub_t3
run_check
[ "$rc" -eq 0 ] && fail "exited 0 with a record that has no expiry" "$out"
echo "$out" | grep -q "could not read an expiry" || fail "no diagnostic for an absent expiry" "$out"

# ── A run that could not check must not retract an earlier warning ──
record "$near" "1be6de72-be59-44da-8511-581328ead55b" | stub_t3
run_check
[ -f "$marker" ] || fail "marker not re-armed before the retraction check" "$out"
record "not-a-timestamp" "malformed-session" | stub_t3
run_check
[ -f "$marker" ] || fail "an inconclusive run retracted a standing warning" "$out"
rm -f "$marker"

# ── No sessions: clean, and not phrased as an all-clear ──
printf 'No sessions.\n' | stub_t3
run_check
[ "$rc" -eq 0 ] || fail "no-sessions output treated as an error" "$out"
echo "$out" | grep -q "no sessions reported" || fail "no-sessions case not reported" "$out"
echo "$out" | grep -q "none expiring within" && fail "claimed sessions are healthy when there are none" "$out"

# ── The t3 command itself failing is inconclusive, not clear ──
printf 'Error: not signed in\n' | stub_t3 3
run_check
[ "$rc" -eq 0 ] && fail "exited 0 when the session list command failed" "$out"
echo "$out" | grep -q "not signed in" || fail "underlying error not surfaced" "$out"

# ── Neither t3 nor npx reachable: named, non-zero, no traceback ──
rm -f "$tmp/bin/t3"
run_check
[ "$rc" -eq 0 ] && fail "exited 0 with no way to reach t3" "$out"
echo "$out" | grep -q "neither t3 nor npx" || fail "missing dependency not named" "$out"
echo "$out" | grep -qE "line [0-9]+:|command not found" && fail "raw shell error leaked instead of a diagnostic" "$out"

# ── A non-numeric threshold is rejected rather than silently becoming zero ──
record "$far" "1be6de72-be59-44da-8511-581328ead55b" | stub_t3
run_check week
[ "$rc" -eq 0 ] && fail "accepted a non-numeric threshold" "$out"
echo "$out" | grep -q "whole number of days" || fail "no diagnostic for a bad threshold" "$out"

echo "PASS"
