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
# Verified through the real consumer (systemd's own parser) and a parsed
# key=value model, not by grepping the unit text, so a semantically
# equivalent file passes and a behaviour-changing edit does not slip through.
declare -A UNIT_PROPS
parse_unit() {  # $1 = unit file -> populates UNIT_PROPS as "Section.Key"=value
    UNIT_PROPS=()
    local section="" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            \#*) ;;
            \[*\]) section="${line#\[}"; section="${section%\]}" ;;
            *=*)
                key="${line%%=*}"; value="${line#*=}"
                [ -n "$section" ] && UNIT_PROPS["$section.$key"]="$value"
                ;;
        esac
    done <"$1"
}
has_section() {  # $1 = section name -> 0 if any parsed key belongs to it
    local k
    for k in "${!UNIT_PROPS[@]}"; do
        case "$k" in "$1".*) return 0 ;; esac
    done
    return 1
}

if command -v systemd-analyze >/dev/null 2>&1; then
    verify_home="$(mktemp -d)"
    mkdir -p "$verify_home/.local/bin" "$verify_home/.config/systemd/user"
    cp "$check" "$verify_home/.local/bin/t3-session-expiry"
    chmod +x "$verify_home/.local/bin/t3-session-expiry"
    cp "$svc" "$timer" "$verify_home/.config/systemd/user/"
    for u in t3-session-expiry.service t3-session-expiry.timer; do
        if ! verify_out="$(HOME="$verify_home" systemd-analyze verify --user \
            "$verify_home/.config/systemd/user/$u" 2>&1)"; then
            rm -rf "$verify_home"
            fail "systemd-analyze rejected $u" "$verify_out"
        fi
    done
    rm -rf "$verify_home"
else
    echo "SKIP: systemd-analyze not on this host — unit syntax/semantics unverified by the real consumer"
fi

parse_unit "$svc"
[ "${UNIT_PROPS[Service.Type]-}" = "oneshot" ] || fail "check service is not Type=oneshot"
[ "${UNIT_PROPS[Service.ExecStart]-}" = "%h/.local/bin/t3-session-expiry" ] \
    || fail "ExecStart does not point at the deployed check"
# A non-zero exit is the warning signal; masking it would hide the one state
# the unit exists to surface.
[ -z "${UNIT_PROPS[Service.SuccessExitStatus]+x}" ] || fail "a warning exit must stay a unit failure"
# Timer-triggered only: an [Install] here would also run it once at login and
# then never again, which silently replaces the schedule.
! has_section Install || fail "check service should be timer-triggered only"

parse_unit "$timer"
[ -n "${UNIT_PROPS[Timer.OnCalendar]-}" ] || fail "timer is not calendar-scheduled"
# Persistent= is honoured only for calendar timers, and a box that was off
# must not silently eat days out of the warning window.
[ "${UNIT_PROPS[Timer.Persistent]-}" = "true" ] || fail "timer does not catch up after downtime"
[ "${UNIT_PROPS[Install.WantedBy]-}" = "timers.target" ] || fail "timer will not be started by systemd"

# ── Trigger: dependency hashes actually couple to the files they name ──
# The daemon-reload trigger fires on a content-hash change, computed by
# chezmoi's own template renderer, not by string presence in the trigger's
# source. Prove the coupling by editing each dependency through the real
# consumer and checking the rendered hash line actually moves.
if command -v chezmoi >/dev/null 2>&1; then
    render_src="$(mktemp -d)"
    cp -a "$here/home" "$render_src/home"
    base_render="$(chezmoi execute-template --source="$render_src/home" \
        <"$render_src/home/run_onchange_51-enable-t3-session-expiry.sh.tmpl")"
    for relpath in dot_config/systemd/user/t3-session-expiry.service \
        dot_config/systemd/user/t3-session-expiry.timer \
        dot_local/bin/executable_t3-session-expiry; do
        rm -rf "${render_src:?}/home"
        cp -a "$here/home" "$render_src/home"
        printf '\n# touched-for-test\n' >>"$render_src/home/$relpath"
        touched_render="$(chezmoi execute-template --source="$render_src/home" \
            <"$render_src/home/run_onchange_51-enable-t3-session-expiry.sh.tmpl")"
        [ "$touched_render" != "$base_render" ] \
            || fail "editing $relpath does not change the trigger's re-run hash"
    done
    rm -rf "$render_src"
else
    echo "SKIP: chezmoi not on this host — dependency-hash coupling unverified by the real consumer"
fi

# ── Trigger: executed against stub systemctl/loginctl, asserted on behaviour ──
trig_tmp="$(mktemp -d)"
mkdir -p "$trig_tmp/bin" "$trig_tmp/sys" "$trig_tmp/home/.config/systemd/user" "$trig_tmp/emptyhome"
for b in env bash sh uname sed cat; do
    src="$(command -v "$b")" || fail "test host is missing $b"
    ln -s "$src" "$trig_tmp/sys/$b"
done
trig_sealed="$trig_tmp/bin:$trig_tmp/sys"
trig_bash="$(command -v bash)"
call_log="$trig_tmp/calls.log"
cp "$svc" "$timer" "$trig_tmp/home/.config/systemd/user/"

cat >"$trig_tmp/bin/systemctl" <<'STUB'
#!/bin/sh
if [ "$1" = "--user" ] && [ "$2" = "show-environment" ]; then
    [ "${STUB_NO_MANAGER:-0}" = "1" ] && exit 1
    echo "HOME=${STUB_MANAGER_HOME}"
    exit 0
fi
echo "$*" >>"$CALL_LOG"
exit 0
STUB
chmod +x "$trig_tmp/bin/systemctl"

cat >"$trig_tmp/bin/loginctl" <<'STUB'
#!/bin/sh
echo "${STUB_LINGER:-no}"
STUB
chmod +x "$trig_tmp/bin/loginctl"

run_trigger() {  # $1 = HOME to run the trigger under; sets $trig_out and $trig_rc
    : >"$call_log"
    set +e
    trig_out="$(PATH="$trig_sealed" HOME="$1" USER="tester" CALL_LOG="$call_log" \
        STUB_MANAGER_HOME="${STUB_MANAGER_HOME:-}" STUB_NO_MANAGER="${STUB_NO_MANAGER:-0}" \
        STUB_LINGER="${STUB_LINGER:-no}" "$trig_bash" "$trigger" 2>&1)"
    trig_rc=$?
    set -e
}

# systemctl acts on the real home regardless of chezmoi's destination, so a
# scratch-dest apply must skip rather than enable a timer for the live user.
STUB_MANAGER_HOME="/nonexistent/other-home" run_trigger "$trig_tmp/home"
[ "$trig_rc" -eq 0 ] || fail "trigger did not exit cleanly on a HOME mismatch" "$trig_out"
echo "$trig_out" | grep -q "skipping enable" || fail "trigger does not skip on a non-home apply" "$trig_out"
[ -s "$call_log" ] && fail "trigger touched systemctl despite a HOME mismatch" "$(cat "$call_log")"

# No unit installed under the apply's HOME: also not a live-home apply.
STUB_MANAGER_HOME="$trig_tmp/emptyhome" run_trigger "$trig_tmp/emptyhome"
[ "$trig_rc" -eq 0 ] || fail "trigger did not exit cleanly with no unit applied" "$trig_out"
[ -s "$call_log" ] && fail "trigger enabled a timer that was never applied" "$(cat "$call_log")"

# A real apply: reload, enable, start, and warn when linger is off.
STUB_MANAGER_HOME="$trig_tmp/home" STUB_LINGER="no" run_trigger "$trig_tmp/home"
[ "$trig_rc" -eq 0 ] || fail "trigger failed on a real home apply" "$trig_out"
grep -qx -- "--user daemon-reload" "$call_log" || fail "trigger never reloads systemd" "$(cat "$call_log")"
grep -qx -- "--user enable --now t3-session-expiry.timer" "$call_log" \
    || fail "trigger never enables the timer" "$(cat "$call_log")"
grep -qx -- "--user start t3-session-expiry.service" "$call_log" \
    || fail "trigger never starts the service" "$(cat "$call_log")"
echo "$trig_out" | grep -q "linger is off" || fail "trigger does not warn when linger is off" "$trig_out"

STUB_MANAGER_HOME="$trig_tmp/home" STUB_LINGER="yes" run_trigger "$trig_tmp/home"
[ "$trig_rc" -eq 0 ] || fail "trigger failed with linger enabled" "$trig_out"
echo "$trig_out" | grep -q "linger is off" && fail "trigger warned about linger despite it being on" "$trig_out"

rm -rf "$trig_tmp"

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
