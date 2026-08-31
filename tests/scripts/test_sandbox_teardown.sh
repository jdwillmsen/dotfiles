#!/usr/bin/env bash
# A sandbox HOME is not only files. Applying into one runs the agent-CLI
# installer, which ends by starting a no-mistakes daemon rooted at that HOME;
# under a sandbox HOME its systemd unit lands somewhere the running
# `systemd --user` never scans, so it falls back to a detached process that
# reparents to init. Removing the tree without stopping that process would
# replace a leaked daemon with a leaked daemon writing to deleted files.
#
# So this executes the real harness teardown against a real detached process
# and asserts the observable end state on every exit path a test can take:
# nothing running under the sandbox, and no sandbox left on disk.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"

# Each case runs in its own bash so the traps lib.sh arms are the thing under
# test rather than a copy of them, and so an uncleaned sandbox belongs to a
# process that has already exited — exactly the shape of the real leak.
driver="$CHEZ_TMP_ROOT/driver.sh"
cat > "$driver" <<'DRIVER'
set -euo pipefail
. "$LIB"
h="$(chez_sandbox)"
# Stand-in for the installed daemon: a detached process whose argv names the
# sandbox. The subshell exits at once, so it reparents to init the way the real
# daemon does. exec -a keeps the sandbox path in argv without needing the
# vendor binary, which would cost a download on every run.
( exec -a "$h/.no-mistakes/bin/no-mistakes daemon run --root $h/.no-mistakes" sleep 300 & )
pid=""
for _ in $(seq 1 100); do
    pid="$(chez_pids_under "$CHEZ_TMP_ROOT" | head -1)"
    [ -n "$pid" ] && break
    sleep 0.1
done
[ -n "$pid" ] || { echo "driver: stand-in daemon never started"; exit 3; }
printf '%s\n%s\n' "$CHEZ_TMP_ROOT" "$pid" > "$REPORT"
case "$MODE" in
    success) exit 0 ;;
    failure) exit 1 ;;
    # Signalled while idling in a short foreground sleep: bash defers a trap
    # until the running foreground command returns, so a single long sleep here
    # would swallow the interrupt for its whole duration.
    signal) printf 'armed\n' > "$READY"; while :; do sleep 0.2; done ;;
esac
DRIVER

fail() {
    local root="$1" msg="$2"
    # A failing assertion must not leak the very thing it is reporting.
    if [ -n "$root" ]; then
        CHEZ_TMP_ROOT="$root" chez_reap || true
        rm -rf -- "$root" || true
    fi
    echo "FAIL: $msg"
    exit 1
}

check_case() {
    local mode="$1" report="$2" rc="$3" root pid
    [ -s "$report" ] || fail "" "$mode: driver wrote no report, so it never armed a sandbox"
    root="$(sed -n 1p "$report")"
    pid="$(sed -n 2p "$report")"
    if [ -z "$root" ] || [ -z "$pid" ]; then fail "" "$mode: incomplete report"; fi

    case "$mode" in
        failure) [ "$rc" != 0 ] || fail "$root" "$mode: driver exited 0, so the failure path was never exercised" ;;
        success) [ "$rc" = 0 ] || fail "$root" "$mode: driver exited $rc, expected 0" ;;
    esac

    # Both checks, not either: an empty pid list with a live pid would mean the
    # match rule drifted, and a dead pid with a live list would mean a sibling
    # process (the daemon's log-sink, in the real case) outlived the teardown.
    if kill -0 "$pid" 2>/dev/null; then
        fail "$root" "$mode: process $pid rooted at the sandbox is still running"
    fi
    local survivors
    survivors="$(chez_pids_under "$root")"
    [ -z "$survivors" ] || fail "$root" "$mode: processes still rooted at $root: $survivors"
    [ ! -e "$root" ] || fail "$root" "$mode: $root still on disk"
    echo "ok: $mode — sandbox $root reaped and removed"
}

for mode in success failure; do
    report="$CHEZ_TMP_ROOT/report.$mode"
    rc=0
    LIB="$here/tests/lib.sh" REPORT="$report" MODE="$mode" bash "$driver" || rc=$?
    check_case "$mode" "$report" "$rc"
done

# Interrupt path: EXIT alone never fires here, so this is the case a bare
# `trap ... EXIT` would silently fail.
report="$CHEZ_TMP_ROOT/report.signal"
ready="$CHEZ_TMP_ROOT/ready.signal"
# A background job of a non-interactive shell inherits SIGINT ignored, and bash
# cannot trap a signal that was already ignored when it started — so without job
# control the driver's INT trap would never arm and this case would hang instead
# of testing anything. set -m gives the driver its own process group with
# default dispositions, which is the state a terminal Ctrl-C acts on.
set -m
LIB="$here/tests/lib.sh" REPORT="$report" READY="$ready" MODE=signal bash "$driver" &
driver_pid=$!
set +m
for _ in $(seq 1 100); do
    [ -s "$ready" ] && break
    sleep 0.1
done
[ -s "$ready" ] || fail "" "signal: driver never armed"
# Positive control: the leak this guards against is observable from here right
# now, so a teardown that did nothing would be caught rather than passing on an
# already-empty machine.
signal_root="$(sed -n 1p "$report")"
[ -n "$(chez_pids_under "$signal_root")" ] ||
    fail "$signal_root" "signal: no process was rooted at the sandbox to begin with"
kill -INT "$driver_pid"
# Bounded, so a teardown that never fires fails the run instead of hanging CI.
for _ in $(seq 1 150); do
    kill -0 "$driver_pid" 2>/dev/null || break
    sleep 0.2
done
if kill -0 "$driver_pid" 2>/dev/null; then
    kill -KILL "$driver_pid" 2>/dev/null || true
    fail "$signal_root" "signal: driver did not act on SIGINT"
fi
rc=0
wait "$driver_pid" || rc=$?
check_case signal "$report" "$rc"

echo "PASS"
