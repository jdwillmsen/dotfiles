#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$here/home/dot_local/bin/executable_agent-browser"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$cli" ] || fail "agent-browser missing or not executable"
shellcheck -s bash "$cli"

tmp="$(mktemp -d)"
# Stubs exec sleep, so they are found by their recorded pids, not by path.
trap 'for f in "$tmp"/run/*.pid "$tmp"/run/slot*/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done; rm -rf "$tmp"' EXIT
bin="$tmp/bin"; mkdir -p "$bin"

# Each stub records its argv and then stays alive like the real daemon, so
# start/stop/status see real pids without launching a browser.
for b in Xvfb google-chrome x11vnc websockify; do
    cat >"$bin/$b" <<EOF
#!/usr/bin/env bash
echo "\$*" >"$tmp/$b.args"
exec sleep 300
EOF
    chmod +x "$bin/$b"
done
cat >"$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
echo 100.64.0.7
EOF
chmod +x "$bin/tailscale"
# CDP stub: /json/new hands out numbered targets; every call is logged.
cat >"$bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$tmp/curl.log"
case "\$*" in
    */json/new*)
        n=\$(( \$(cat "$tmp/tabs" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$tmp/tabs"
        printf '{\n   "id": "T%s",\n   "type": "page"\n}\n' "\$n" ;;
    *) echo '{}' ;;
esac
EOF
chmod +x "$bin/curl"

# PATH is built from scratch: inherited, the real binaries on this machine
# would answer for the stubs.
run() {
    env -i HOME="$tmp/home" PATH="$bin:/usr/bin:/bin" \
        AGENT_BROWSER_RUN="$tmp/run" AGENT_BROWSER_PROFILE="$tmp/profile" \
        bash "$cli" "$@"
}
lease() { sed -n 's/^lease: //p' <<<"$1"; }

out="$(run)"
grep -q 'state: stopped' <<<"$out" || fail "no-args should report stopped" "$out"

out="$(run start https://example.com)"
a="$(lease "$out")"
[ -n "$a" ] || fail "start must print a lease" "$out"
grep -q 'slot: 0' <<<"$out" || fail "plain start must use the shared slot 0" "$out"
grep -q 'target: T1' <<<"$out" || fail "start must open its own tab" "$out"
grep -q 'viewer: http://100.64.0.7:6080/vnc.html' <<<"$out" || fail "viewer must use the tailnet address" "$out"
grep -q '/json/new.*=https://example.com' "$tmp/curl.log" || fail "start URL must open in the lease's tab" "$(cat "$tmp/curl.log")"

chrome_args="$(cat "$tmp/google-chrome.args")"
grep -q -- '--remote-debugging-address=127.0.0.1' <<<"$chrome_args" || fail "CDP must bind to loopback" "$chrome_args"
grep -q -- "--user-data-dir=$tmp/profile" <<<"$chrome_args" || fail "chrome must use the persistent profile" "$chrome_args"
grep -q -- '--disable-background-timer-throttling' <<<"$chrome_args" || fail "background tabs must not be throttled" "$chrome_args"
grep -q -- '-localhost' "$tmp/x11vnc.args" || fail "VNC must bind to localhost"
grep -q '100.64.0.7:6080' "$tmp/websockify.args" || fail "viewer must bind to the tailnet address only"
[ "$(stat -c %a "$tmp/profile")" = 700 ] || fail "profile must be private"
for p in $(cat "$tmp"/run/*.pid); do
    [ ! -e "/proc/$p/fd/9" ] || fail "daemons must not inherit the lock fd; it would never be released"
done

out="$(run start)"
b="$(lease "$out")"
{ [ -n "$b" ] && [ "$b" != "$a" ]; } || fail "a second start must get its own lease" "$out"
grep -q 'target: T2' <<<"$out" || fail "a second lease must get its own tab" "$out"

out="$(run stop)"
grep -q 'state: kept' <<<"$out" || fail "a lease-less stop must not kill other agents' browser" "$out"
out="$(run stop "$a")"
grep -q "released: $a" <<<"$out" || fail "stop <lease> should release it" "$out"
grep -q 'kept (in use by 1' <<<"$out" || fail "the browser must stay up while another lease lives" "$out"
grep -q '/json/close/T1' "$tmp/curl.log" || fail "releasing a lease must close its tab"
if grep -q '/json/close/T2' "$tmp/curl.log"; then fail "releasing a lease must not close another lease's tab"; fi

out="$(run wipe)" && fail "wipe without --yes must fail" "$out"
grep -q 'confirmation_required' <<<"$out" || fail "wipe should explain the confirmation" "$out"
out="$(run wipe --yes)" && fail "wipe while running must fail" "$out"
[ -d "$tmp/profile" ] || fail "profile must survive a refused wipe"

# A lease nobody has used within the TTL no longer holds the browser up.
touch -d '3 hours ago' "$tmp/run/leases/$b"
out="$(run stop)"
grep -q 'stopped: 4' <<<"$out" || fail "stale leases must not keep the browser up" "$out"
grep -q 'kept; sessions persist' <<<"$out" || fail "stop must keep the profile" "$out"
out="$(run)"
grep -q 'state: stopped' <<<"$out" || fail "status after stop should be stopped" "$out"

out="$(run py "$b" x.py)" && fail "py on an expired lease must fail" "$out"
grep -q 'unknown_lease' <<<"$out" || fail "expired lease should be a structured error" "$out"

# Isolated slots: own ports, viewer and profile; never the shared slot 0.
run start >/dev/null
out="$(run start --slot auto)"
c="$(lease "$out")"
grep -q 'slot: 1' <<<"$out" || fail "auto must pick isolated slot 1, never shared slot 0" "$out"
grep -q 'cdp: http://127.0.0.1:9223' <<<"$out" || fail "slot 1 must shift the CDP port" "$out"
grep -q 'viewer: http://100.64.0.7:6081' <<<"$out" || fail "slot 1 must get its own viewer" "$out"
grep -q -- "--user-data-dir=$tmp/profile-slot1" "$tmp/google-chrome.args" || fail "slot 1 must use its own profile"
out="$(run start --slot auto)"
grep -q 'slot: 2' <<<"$out" || fail "auto must skip a slot another lease holds" "$out"
out="$(run status)"
grep -q '  1,running,1,' <<<"$out" || fail "status should list every slot" "$out"
out="$(run stop "$c")"
{ grep -q 'slot: 1' <<<"$out" && grep -q 'stopped: 4' <<<"$out"; } || fail "the last lease on a slot stops that slot" "$out"
out="$(run stop --force)"
grep -q 'stopped: 4' <<<"$out" || fail "stop --force must stop a slot regardless of leases" "$out"
run stop --force --slot 2 >/dev/null

out="$(run wipe --yes)"
[ ! -e "$tmp/profile" ] || fail "wipe --yes should delete the profile" "$out"

out="$(run bogus)" && fail "unknown command must fail" "$out"
grep -q 'unknown_command' <<<"$out" || fail "unknown command should be a structured error" "$out"

for args in "start --slot" "stop --slot" "check site --slot" "wipe --slot" "status --slot"; do
    out="$(run $args)" && fail "trailing --slot must not loop: $args" "$out"
    grep -q 'error: usage' <<<"$out" || fail "trailing --slot should be a usage error: $args" "$out"
done

# No tailnet means no viewer at all: never fall back to another interface.
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/tailscale"
out="$(run start)" && fail "start without a tailnet address must fail" "$out"
grep -q 'no_tailnet' <<<"$out" || fail "missing tailnet should be a structured error" "$out"

echo "ok: agent-browser"
