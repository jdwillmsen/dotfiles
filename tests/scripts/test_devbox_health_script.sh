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
for u in bash python3 grep sed awk cat printf uptime mktemp; do
    up="$(type -P "$u")"
    [ -n "$up" ] || fail "cannot sandbox $u: no external binary"
    ln -sf "$up" "$sysbin/$u"
done
SEALED="$bin:$sysbin"

# Stub knobs, each read at call time so a case can flip one without rewriting
# the stub: STATE_<unit> for is-active/is-enabled, HAVE_TS for whether
# tailscale exists, HTTP_CODE for what the endpoint returns.
write_stubs() {
    cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"is-active tailscaled"*) echo "${TAILSCALED_STATE:-active}" ;;
    *"cat t3code.service"*)   [ "${HAVE_T3:-1}" = 1 ] || exit 1 ;;
    *"cat t3-session-expiry.timer"*) [ "${HAVE_TIMER:-1}" = 1 ] || exit 1 ;;
    *"is-active t3code.service"*)  echo "${T3_ACTIVE:-active}" ;;
    *"is-enabled t3code.service"*) echo "${T3_ENABLED:-enabled}" ;;
    *"is-active t3-session-expiry.timer"*)  echo "${TIMER_ACTIVE:-active}" ;;
    *"is-enabled t3-session-expiry.timer"*) echo "${TIMER_ENABLED:-enabled}" ;;
    *"is-enabled ssh.socket"*) echo "${SSHSOCK:-enabled}" ;;
esac
EOF
    cat >"$bin/loginctl" <<'EOF'
#!/usr/bin/env bash
echo "${LINGER:-yes}"
EOF
    cat >"$bin/ss" <<'EOF'
#!/usr/bin/env bash
[ "${PORT_UP:-1}" = 1 ] && echo "LISTEN 0 511 127.0.0.1:3773 0.0.0.0:*"
EOF
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${HTTP_CODE:-200}"
EOF
    cat >"$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"debug prefs"*) echo "{\"RunSSH\": ${RUNSSH:-true}}" ;;
    *"status --json"*) echo "{\"BackendState\":\"${BACKEND:-Running}\",\"Self\":{\"DNSName\":\"box.example.ts.net.\"}}" ;;
esac
EOF
    chmod +x "$bin"/*
}
write_stubs

run() {  # run -> stdout+stderr of the script, sets RC
    set +e
    OUT="$(env -i PATH="$SEALED" HOME="$tmp/home" USER=tester \
        TAILSCALED_STATE="${TAILSCALED_STATE:-}" BACKEND="${BACKEND:-}" \
        RUNSSH="${RUNSSH:-}" LINGER="${LINGER:-}" HAVE_T3="${HAVE_T3:-}" \
        HAVE_TIMER="${HAVE_TIMER:-}" T3_ACTIVE="${T3_ACTIVE:-}" \
        T3_ENABLED="${T3_ENABLED:-}" TIMER_ACTIVE="${TIMER_ACTIVE:-}" \
        TIMER_ENABLED="${TIMER_ENABLED:-}" SSHSOCK="${SSHSOCK:-}" \
        PORT_UP="${PORT_UP:-}" HTTP_CODE="${HTTP_CODE:-}" \
        bash "$check" 2>&1)"
    RC=$?
    set -e
}

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
echo "$OUT" | grep -q "failed=0" || fail "healthy machine should report failed=0" "$OUT"
echo "$OUT" | grep -q "all good" || fail "healthy machine should say all good" "$OUT"

# ── the outage this script was written to catch ──
T3_ACTIVE=inactive run
[ "$RC" -eq 1 ] || fail "a dead harness must exit non-zero" "$OUT"
echo "$OUT" | grep -q "FAIL  t3code.service active" || fail "dead harness must be named" "$OUT"
unset T3_ACTIVE

# ── a stopped timer is a silent loss of the expiry warning ──
TIMER_ACTIVE=inactive run
[ "$RC" -eq 1 ] || fail "a dead timer must exit non-zero" "$OUT"
unset TIMER_ACTIVE

# ── tunnel up but server down, and the reverse: these look alike from a browser ──
PORT_UP=0 run
[ "$RC" -eq 1 ] || fail "missing loopback listener must fail" "$OUT"
echo "$OUT" | grep -q "FAIL  loopback 3773" || fail "loopback failure must be named" "$OUT"
unset PORT_UP

HTTP_CODE=502 run
[ "$RC" -eq 1 ] || fail "a 502 endpoint must fail" "$OUT"
echo "$OUT" | grep -q "box.example.ts.net" || fail "endpoint check must use the derived MagicDNS name" "$OUT"
unset HTTP_CODE

# ── linger off means every user unit dies at logout, so green units mislead ──
LINGER=no run
[ "$RC" -eq 1 ] || fail "linger off must fail" "$OUT"
unset LINGER

# ── break-glass off is a failure even when everything else is up ──
RUNSSH=false run
[ "$RC" -eq 1 ] || fail "tailscale ssh off must fail" "$OUT"
unset RUNSSH

# ── absent is not broken: a machine without these must skip, not fail ──
HAVE_T3=0 HAVE_TIMER=0 run
[ "$RC" -eq 0 ] || fail "uninstalled units should skip, not fail" "$OUT"
echo "$OUT" | grep -q "skip  t3code.service" || fail "uninstalled unit should report skip" "$OUT"
unset HAVE_T3 HAVE_TIMER

rm -f "$bin/tailscale"
run
[ "$RC" -eq 0 ] || fail "absent tailscale should skip, not fail" "$OUT"
echo "$OUT" | grep -q "skip  tailscale" || fail "absent tailscale should report skip" "$OUT"
write_stubs

echo "PASS"
