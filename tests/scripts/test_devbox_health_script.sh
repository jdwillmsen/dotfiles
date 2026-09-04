#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
check="$here/home/dot_local/bin/executable_devbox-health"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$check" ] || fail "devbox-health missing or not executable"
shellcheck -s bash "$check"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"; mkdir -p "$bin"

# PATH is built from scratch rather than inherited: with the caller's PATH the
# real systemctl and tailscale on this machine would answer for the stubs and
# every case would assert against live state instead of the fixture.
sysbin="$tmp/sysbin"; mkdir -p "$sysbin"
for u in bash python3 grep sed awk cat printf uptime mktemp id; do
    up="$(type -P "$u")"
    [ -n "$up" ] || fail "cannot sandbox $u: no external binary"
    ln -sf "$up" "$sysbin/$u"
done
SEALED="$bin:$sysbin"

# Stub knobs, each read at call time so a case can flip one without rewriting
# the stub. HAVE_* decide whether a unit exists at all, so absent can be told
# from broken; USER_BUS decides whether systemctl --user can answer, which is
# the third case — present but unaskable.
KNOBS=(TAILSCALED_STATE BACKEND RUNSSH PREFS_OK LINGER LINGER_OK USER_BUS
    HAVE_T3 HAVE_TIMER T3_ACTIVE T3_ENABLED TIMER_ACTIVE TIMER_ENABLED
    HAVE_SSHSOCK SSHSOCK HAVE_SSHSVC SSHSVC SS_OK PORT_UP LISTEN_ADDR HTTP_CODE)

write_stubs() {
    cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"--user is-system-running"*) echo "${USER_BUS:-running}" ;;
    *"is-active tailscaled"*) echo "${TAILSCALED_STATE:-active}" ;;
    *"cat t3code.service"*)   [ "${HAVE_T3:-1}" = 1 ] || exit 1 ;;
    *"cat t3-session-expiry.timer"*) [ "${HAVE_TIMER:-1}" = 1 ] || exit 1 ;;
    *"is-active t3code.service"*)  echo "${T3_ACTIVE:-active}" ;;
    *"is-enabled t3code.service"*) echo "${T3_ENABLED:-enabled}" ;;
    *"is-active t3-session-expiry.timer"*)  echo "${TIMER_ACTIVE:-active}" ;;
    *"is-enabled t3-session-expiry.timer"*) echo "${TIMER_ENABLED:-enabled}" ;;
    *"cat ssh.socket"*) [ "${HAVE_SSHSOCK:-1}" = 1 ] || exit 1 ;;
    *"cat ssh.service"*) [ "${HAVE_SSHSVC:-0}" = 1 ] || exit 1 ;;
    *"cat sshd.service"*) exit 1 ;;
    *"is-enabled ssh.socket"*) echo "${SSHSOCK:-enabled}" ;;
    *"is-enabled ssh.service"*) echo "${SSHSVC:-disabled}" ;;
esac
EOF
    cat >"$bin/loginctl" <<'EOF'
#!/usr/bin/env bash
[ "${LINGER_OK:-1}" = 1 ] || { echo "Failed to get user: not logged in or lingering" >&2; exit 1; }
echo "${LINGER:-yes}"
EOF
    # The wanted line comes first and is followed by far more than a stdio
    # buffer of other listeners: a reader that stops at the first match while
    # the writer is still mid-output is exactly the shape this must catch.
    cat >"$bin/ss" <<'EOF'
#!/usr/bin/env bash
[ "${SS_OK:-1}" = 1 ] || exit 255
echo "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process"
[ "${PORT_UP:-1}" = 1 ] && echo "LISTEN 0 511 ${LISTEN_ADDR:-127.0.0.1:3773} 0.0.0.0:*"
printf 'LISTEN 0 4096 127.0.0.1:%d 0.0.0.0:*\n' {40000..43000}
EOF
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${HTTP_CODE:-200}"
EOF
    cat >"$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"debug prefs"*)
        [ "${PREFS_OK:-1}" = 1 ] || exit 1
        echo "{\"RunSSH\": ${RUNSSH:-true}}" ;;
    *"status --json"*) echo "{\"BackendState\":\"${BACKEND:-Running}\",\"Self\":{\"DNSName\":\"box.example.ts.net.\"}}" ;;
esac
EOF
    chmod +x "$bin"/*
}
write_stubs

# The linger record dir is part of the seal too: the script falls back to it
# when loginctl is silent, and the real one would answer for this host.
linger_dir="$tmp/linger"; mkdir -p "$linger_dir"

run() {  # run -> stdout+stderr of the script, sets RC
    local envargs=(PATH="$SEALED" HOME="$tmp/home" DEVBOX_HEALTH_LINGER_DIR="$linger_dir") k
    [ "${NO_USER:-0}" = 1 ] || envargs+=(USER=tester)
    for k in "${KNOBS[@]}"; do envargs+=("$k=${!k-}"); done
    set +e
    OUT="$(env -i "${envargs[@]}" bash "$check" 2>&1)"
    RC=$?
    set -e
}

has() { echo "$OUT" | grep -q "$1"; }
hasnt() { ! echo "$OUT" | grep -q "$1"; }

# The seal itself is asserted before any case runs: a stub that silently lost
# to a real binary would make every assertion below meaningless.
for u in systemctl tailscale ss curl loginctl; do
    resolved="$(PATH="$SEALED" command -v "$u" || true)"
    case "$resolved" in
        "$bin/$u") ;;
        *) fail "seal leaked: $u resolved to '$resolved', not the stub" ;;
    esac
done

# ── healthy machine ──
run
[ "$RC" -eq 0 ] || fail "healthy machine should exit 0" "$OUT"
has "failed=0" || fail "healthy machine should report failed=0" "$OUT"
has "undetermined=0" || fail "healthy machine should report undetermined=0" "$OUT"
has "all good" || fail "healthy machine should say all good" "$OUT"

# ── the outage this script was written to catch ──
T3_ACTIVE=inactive run
[ "$RC" -eq 1 ] || fail "a dead harness must exit non-zero" "$OUT"
has "FAIL  t3code.service active" || fail "dead harness must be named" "$OUT"
unset T3_ACTIVE

# ── a stopped timer is a silent loss of the expiry warning ──
TIMER_ACTIVE=inactive run
[ "$RC" -eq 1 ] || fail "a dead timer must exit non-zero" "$OUT"
unset TIMER_ACTIVE

# ── tunnel up but server down, and the reverse: these look alike from a browser ──
PORT_UP=0 run
[ "$RC" -eq 1 ] || fail "missing loopback listener must fail" "$OUT"
has "FAIL  loopback 3773" || fail "loopback failure must be named" "$OUT"
unset PORT_UP

# ── ss failing outright is not a dead listener; it is a check that could not run ──
SS_OK=0 run
[ "$RC" -eq 1 ] || fail "a failing ss must exit non-zero" "$OUT"
has "UNKN  loopback 3773" || fail "a failing ss must report undetermined" "$OUT"
hasnt "FAIL  loopback 3773" || fail "a failing ss must not claim the listener is dead" "$OUT"
unset SS_OK

# ── a longer port that merely starts with the wanted one is not the wanted one ──
LISTEN_ADDR=127.0.0.1:37730 run
[ "$RC" -eq 1 ] || fail "a listener on 37730 must not satisfy the 3773 check" "$OUT"
has "FAIL  loopback 3773" || fail "prefix-only listener must be reported failed" "$OUT"
unset LISTEN_ADDR

HTTP_CODE=502 run
[ "$RC" -eq 1 ] || fail "a 502 endpoint must fail" "$OUT"
has "box.example.ts.net" || fail "endpoint check must use the derived MagicDNS name" "$OUT"
unset HTTP_CODE

# ── linger off means every user unit dies at logout, so green units mislead ──
LINGER=no run
[ "$RC" -eq 1 ] || fail "linger off must fail" "$OUT"
unset LINGER

# ── ...and loginctl is silent about a user it is not tracking, which is what
# linger off looks like from a system unit: that is a plain failure, not UNKN ──
LINGER_OK=0 run
[ "$RC" -eq 1 ] || fail "silent loginctl with no linger record must fail" "$OUT"
has "FAIL  linger .*got=no" || fail "silent loginctl must report linger as off" "$OUT"
hasnt "UNKN  linger" || fail "silent loginctl must not read as a tooling problem" "$OUT"

# ── ...unless the on-disk record says the user lingers, which is the answer ──
touch "$linger_dir/tester"
LINGER_OK=0 run
[ "$RC" -eq 0 ] || fail "a linger record must satisfy the check when loginctl is silent" "$OUT"
has "ok    linger .*yes" || fail "a linger record must read as linger on" "$OUT"
rm "$linger_dir/tester"
unset LINGER_OK

# ── break-glass off is a failure, and it must not read as an unreadable dump ──
RUNSSH=false run
[ "$RC" -eq 1 ] || fail "tailscale ssh off must fail" "$OUT"
has "FAIL  tailscale ssh .*got=False" || fail "a switched-off SSH server must show False" "$OUT"
unset RUNSSH

# ── ...whereas an unreadable prefs dump is not a switched-off server ──
PREFS_OK=0 run
[ "$RC" -eq 1 ] || fail "unreadable prefs must exit non-zero" "$OUT"
has "UNKN  tailscale ssh" || fail "unreadable prefs must report undetermined" "$OUT"
hasnt "got=False" || fail "unreadable prefs must not claim the server is off" "$OUT"
unset PREFS_OK

# ── absent is not broken: a machine without these must skip, not fail ──
HAVE_T3=0 HAVE_TIMER=0 run
[ "$RC" -eq 0 ] || fail "uninstalled units should skip, not fail" "$OUT"
has "skip  t3code.service" || fail "uninstalled unit should report skip" "$OUT"
unset HAVE_T3 HAVE_TIMER

# ── ...but an unreachable user bus is not absence, and must not pass as one.
# This is the cron and system-unit case the script advertises support for. ──
USER_BUS=offline run
[ "$RC" -eq 1 ] || fail "an unreachable user bus must exit non-zero" "$OUT"
has "UNKN  t3code.service" || fail "unreachable bus must report undetermined" "$OUT"
hasnt "skip  t3code.service" || fail "unreachable bus must not read as not installed" "$OUT"
hasnt "all good" || fail "unreachable bus must not report a converged machine" "$OUT"
unset USER_BUS

# ── no ssh unit at all is absence; a service-activated one is still enabled ──
HAVE_SSHSOCK=0 HAVE_SSHSVC=0 run
[ "$RC" -eq 0 ] || fail "a machine with no ssh unit should skip, not fail" "$OUT"
has "skip  ssh " || fail "absent ssh unit should report skip" "$OUT"
unset HAVE_SSHSOCK HAVE_SSHSVC

HAVE_SSHSVC=1 SSHSOCK=disabled SSHSVC=enabled run
[ "$RC" -eq 0 ] || fail "service-activated ssh should pass" "$OUT"
has "ok    ssh.service enabled" || fail "service-activated ssh should be named" "$OUT"
unset HAVE_SSHSVC SSHSOCK SSHSVC

# ── the user name is derived, not assumed: system units do not set USER ──
NO_USER=1 run
[ "$RC" -eq 0 ] || fail "an unset USER must not abort the run" "$OUT"
has "box.example.ts.net" || fail "checks after linger must still run with USER unset" "$OUT"
unset NO_USER

# ── a missing interpreter is the tool's own problem, not the tailnet's ──
mv "$sysbin/python3" "$tmp/python3-parked"
run
[ "$RC" -eq 1 ] || fail "a missing python3 must exit non-zero" "$OUT"
has "UNKN  tailnet backend" || fail "missing python3 must report undetermined" "$OUT"
hasnt "FAIL  tailnet backend" || fail "missing python3 must not blame the tailnet" "$OUT"
mv "$tmp/python3-parked" "$sysbin/python3"

rm -f "$bin/tailscale"
run
[ "$RC" -eq 0 ] || fail "absent tailscale should skip, not fail" "$OUT"
has "skip  tailscale" || fail "absent tailscale should report skip" "$OUT"
write_stubs

echo "PASS"
