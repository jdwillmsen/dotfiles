#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$here/scripts/devbox-reboot-guard"
shellcheck -s bash "$guard"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$guard" ] || fail "devbox-reboot-guard must be executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The system is faked under GUARD_ROOT and every probe is a PATH stub, so each
# case sets exactly the signals it is about and asserts on the decision, the
# state written and whether a reboot was asked for.
user="$(id -un)"
root="$tmp/root"
home="$root$(getent passwd "$user" | cut -d: -f6)"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >>"$tmp/calls"
EOF
# pgrep matches against a fake process table: -x on the 15-character kernel
# name, -f on the full command line, as the real one does.
cat >"$tmp/bin/pgrep" <<EOF
#!/usr/bin/env bash
case "\$1" in
    -x) grep -qxE "\$2" "$tmp/comms" ;;
    -f) grep -qE "\$2" "$tmp/cmdlines" ;;
    *) echo "unexpected pgrep \$*" >&2; exit 3 ;;
esac
EOF
chmod +x "$tmp/bin/"*
proc() {  # proc COMM CMDLINE — add a process to the fake table
    echo "$1" >>"$tmp/comms"
    echo "$2" >>"$tmp/cmdlines"
}

reset() {
    rm -rf "$root"
    mkdir -p "$home" "$root/var/run" "$root/dev/pts" "$root/proc"
    booted $((30 * 86400))
    : >"$tmp/calls"
    # Always running on Ubuntu, and shares the truncated name of a real upgrade.
    printf 'sshd\nunattended-upgr\n' >"$tmp/comms"
    printf 'sshd: %s\n/usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown --wait-for-signal\n' \
        "$user" >"$tmp/cmdlines"
}
booted() {  # booted SECONDS_AGO — the boot time /proc/stat reports
    printf 'cpu  1 2 3 4\nbtime %s\nprocesses 1\n' "$(($(date +%s) - $1))" >"$root/proc/stat"
}
tty_input() {  # tty_input N SECONDS_AGO — a user-owned pty last read that long ago
    : >"$root/dev/pts/$1"
    touch -a -d "@$(($(date +%s) - $2))" "$root/dev/pts/$1"
}
pending() {  # pending DAYS_AGO — a reboot-required flag that old
    : >"$root/var/run/reboot-required"
    touch -d "@$(($(date +%s) - $1 * 86400 - 60))" "$root/var/run/reboot-required"
}
run() {  # run [args] -> out, rc, calls; extra env via the caller's env
    rc=0
    out="$(env PATH="$tmp/bin:$PATH" GUARD_ROOT="$root" MAINT_USER="${MAINT_USER-$user}" \
        bash "$guard" "$@" 2>&1)" || rc=$?
    calls="$(cat "$tmp/calls")"
}
state() { cat "$root/var/lib/devbox-maintenance/state.json" 2>/dev/null; }
notice_text() { cat "$root/var/lib/devbox-maintenance/notice" 2>/dev/null || true; }

# ── refuses to guess whose work matters ──
reset; pending 1
MAINT_USER="" run
[ "$rc" -eq 2 ] || fail "ran without MAINT_USER (rc=$rc)" "$out"
[ -z "$calls" ] || fail "rebooted without MAINT_USER" "$calls"

reset; pending 1
IDLE_MINUTES=abc run
[ "$rc" -eq 2 ] || fail "accepted a non-numeric IDLE_MINUTES" "$out"

reset
run --bogus
[ "$rc" -eq 2 ] || fail "accepted an unknown argument" "$out"

# ── nothing pending: no reboot, stale notice cleared ──
reset
mkdir -p "$root/var/lib/devbox-maintenance"
echo old >"$root/var/lib/devbox-maintenance/notice"
run
[ "$rc" -eq 0 ] || fail "clean run exited $rc" "$out"
[ -z "$calls" ] || fail "rebooted with nothing pending" "$calls"
state | grep -q '"status": "clean"' || fail "clean state not recorded" "$(state)"
[ -z "$(notice_text)" ] || fail "stale notice survived a clean run"

# ── pending and idle: reboots ──
reset; pending 1
run
[ "$rc" -eq 0 ] || fail "idle run exited $rc" "$out"
[ "$calls" = "systemctl reboot" ] || fail "idle box with a pending reboot did not reboot" "$calls"
state | grep -q '"status": "rebooting"' || fail "rebooting state not recorded" "$(state)"

# ── --dry-run decides but changes nothing ──
reset; pending 1
run --dry-run
echo "$out" | grep -q "^would reboot" || fail "dry run did not report the reboot" "$out"
[ -z "$calls" ] || fail "dry run rebooted" "$calls"
[ -z "$(state)" ] || fail "dry run wrote state"

# ── each blocker defers ──
reset; pending 1
proc dpkg "/usr/bin/dpkg --configure -a"
run
[ -z "$calls" ] || fail "rebooted while dpkg was running" "$calls"
state | grep -q 'package manager running' || fail "apt blocker not recorded" "$(state)"

reset; pending 1
proc unattended-upgr "/usr/bin/python3 /usr/bin/unattended-upgrade"
run
[ -z "$calls" ] || fail "rebooted during an unattended-upgrade run" "$calls"

# The shutdown helper alone (always present, set up by reset) must not block.
reset; pending 1
run
[ "$calls" = "systemctl reboot" ] || fail "the idle unattended-upgrade-shutdown helper blocked the reboot" "$out"

for d in .claude/projects/p .codex/sessions .local/share/opencode/s; do
    reset; pending 1
    mkdir -p "$home/$d"
    : >"$home/$d/t.jsonl"
    run
    [ -z "$calls" ] || fail "rebooted with a fresh transcript under $d" "$calls"
    echo "$out" | grep -q "agent session active" || fail "no agent reason for $d" "$out"
done

# An old transcript is not activity.
reset; pending 1
mkdir -p "$home/.claude/projects/p"
: >"$home/.claude/projects/p/t.jsonl"
touch -d '-2 hours' "$home/.claude/projects/p/t.jsonl"
run
[ "$calls" = "systemctl reboot" ] || fail "a 2h-old transcript blocked the reboot" "$out"

# IDLE_MINUTES widens the window.
reset; pending 1
mkdir -p "$home/.claude/projects/p"
: >"$home/.claude/projects/p/t.jsonl"
touch -d '-2 hours' "$home/.claude/projects/p/t.jsonl"
IDLE_MINUTES=180 run
[ -z "$calls" ] || fail "IDLE_MINUTES=180 ignored a 2h-old transcript" "$calls"

# Terminals: recent keyboard input defers; a terminal left open but idle, or
# one with only fresh output (mtime), does not.
reset; pending 1
tty_input 3 120
run
[ -z "$calls" ] || fail "rebooted under recent terminal input" "$calls"
echo "$out" | grep -q "terminal input" || fail "no terminal reason" "$out"

reset; pending 1
tty_input 0 $((3 * 3600))
touch -m "$root/dev/pts/0"
run
[ "$calls" = "systemctl reboot" ] || fail "an idle terminal with fresh output blocked the reboot" "$out"

# Only the watched user's terminals count; faking another owner needs chown.
if [ "$(id -u)" = 0 ]; then
    reset; pending 1
    tty_input 4 60
    chown nobody "$root/dev/pts/4"
    run
    [ "$calls" = "systemctl reboot" ] || fail "another user's terminal blocked the reboot" "$out"
fi

# ── escalation: notice only once the reboot has waited ESCALATE_DAYS ──
reset; pending 3
proc dpkg dpkg
run
[ -z "$(notice_text)" ] || fail "notice before the escalation threshold" "$(notice_text)"

reset; pending 8
proc dpkg dpkg
run
notice_text | grep -q "reboot pending 8d" || fail "no notice after 8 days deferred" "$(notice_text)"
notice_text | grep -q "sudo reboot" || fail "notice does not say how to fix it" "$(notice_text)"

# A later reboot-requiring install rewrites the flag; a prior deferral keeps
# the original start so the escalation still fires.
prior() {  # prior STATUS DAYS_AGO [CHECKED_SECONDS_AGO] — the state a previous guard run left
    prior_since=$(($(date +%s) - $2 * 86400 - 60))
    mkdir -p "$root/var/lib/devbox-maintenance"
    printf '{"status": "%s", "reason": "x", "pending_since": %s, "checked_at": %s}\n' \
        "$1" "$prior_since" "$(($(date +%s) - ${3:-3600}))" >"$root/var/lib/devbox-maintenance/state.json"
}
reset; pending 1; prior deferred 8
proc dpkg dpkg
run
notice_text | grep -q "reboot pending 8d" || fail "a rewritten flag restarted the deferral count" "$(notice_text)"
state | grep -q "\"pending_since\": $prior_since," || fail "the original pending_since was not kept" "$(state)"

# A deferral from before a manual reboot does not date a flag set since.
reset; pending 0; prior deferred 8 $((2 * 3600)); booted 3600
proc dpkg dpkg
run
[ -z "$(notice_text)" ] || fail "a deferral from before the last boot carried over" "$(notice_text)"
state | grep -q "\"pending_since\": $prior_since," && fail "pre-boot pending_since kept" "$(state)"

# After a reboot attempt the wait starts over from the flag.
reset; pending 1; prior rebooting 8
proc dpkg dpkg
run
[ -z "$(notice_text)" ] || fail "a pre-reboot start carried over" "$(notice_text)"

reset; pending 8
proc dpkg dpkg
ESCALATE_DAYS=10 run
[ -z "$(notice_text)" ] || fail "ESCALATE_DAYS ignored" "$(notice_text)"

echo "devbox-reboot-guard: all tests passed"
