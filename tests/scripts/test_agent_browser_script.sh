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
cleanup() {
    local f
    for f in "$tmp"/run/*.pid "$tmp"/run/slot*/*.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    done
    rm -rf "$tmp"
}
trap cleanup EXIT
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
while read -r p; do
    [ ! -e "/proc/$p/fd/9" ] || fail "daemons must not inherit the lock fd; it would never be released"
done < <(cat "$tmp"/run/*.pid)

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
grep -q '/json/close/T2' "$tmp/curl.log" || fail "pruning a stale lease must close its tab"
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

# stop <bogus-id>: a not-live id never clobbers --slot and never shuts a slot down
out="$(run start)"
d="$(lease "$out")"
[ -n "$d" ] || fail "setup start for bogus-stop test" "$out"
out="$(run stop bogus-id)" && fail "stop <bogus-id> must not succeed" "$out"
grep -q 'unknown_lease' <<<"$out" || fail "stop <bogus-id> should be a structured unknown_lease error" "$out"
grep -q 'released: none' <<<"$out" || fail "stop <bogus-id> should report released: none" "$out"
if grep -q 'stopped:' <<<"$out"; then fail "stop <bogus-id> must not shut a slot down" "$out"; fi
out="$(run status)"
grep -q 'state: running' <<<"$out" || fail "stop <bogus-id> must not stop the running slot" "$out"
out="$(run stop --force --slot 1 bogus-id)" && fail "stop --force --slot 1 <bogus-id> must not succeed" "$out"
grep -q 'unknown_lease' <<<"$out" || fail "stop --force <bogus-id> should be unknown_lease" "$out"
if grep -q 'stopped:' <<<"$out"; then fail "stop --force --slot 1 <bogus-id> must not shut down any slot" "$out"; fi
out="$(run status)"
grep -q 'state: running' <<<"$out" || fail "stop --force --slot 1 <bogus-id> must not stop slot 0" "$out"
out="$(run stop --slot 2 bogus-id)" && fail "stop --slot 2 <bogus-id> must not succeed" "$out"
if grep -q 'stopped:' <<<"$out"; then fail "stop --slot 2 <bogus-id> must not shut a slot down" "$out"; fi
out="$(run status)"
grep -q 'state: running' <<<"$out" || fail "stop --slot 2 <bogus-id> must not stop slot 0" "$out"
run stop "$d" >/dev/null
run stop --force >/dev/null 2>&1 || true

# canonical slot identity: leading zeros are the same slot
out="$(run start --slot 00)"
grep -q 'slot: 0' <<<"$out" || fail "--slot 00 must count as slot 0" "$out"
grep -q 'cdp: http://127.0.0.1:9222' <<<"$out" || fail "--slot 00 must keep slot 0 ports" "$out"
grep -q -- "--user-data-dir=$tmp/profile" "$tmp/google-chrome.args" || fail "--slot 00 must use the slot-0 profile" "$out"
if [ -e "$tmp/profile-slot00" ]; then fail "--slot 00 must not create a slot00 profile"; fi
case "$(lease "$out")" in s0-*) ;; *) fail "--slot 00 lease id must be s0-*" "$out" ;; esac
out="$(run status --slot 00)"
grep -q 'slot: 0' <<<"$out" || fail "status --slot 00 must count as slot 0" "$out"
run stop --force --slot 00 >/dev/null

# shared slot-flag parser: --slot N and --slot=N on every subcommand
out="$(run start --slot=1)"
grep -q 'slot: 1' <<<"$out" || fail "start must accept --slot=1" "$out"
run stop --force --slot=1 >/dev/null
out="$(run status --slot=0)"
grep -q 'slot: 0' <<<"$out" || fail "status must accept --slot=0" "$out"

# wipe targets exactly the named slot and rejects unknown args
mkdir -p "$tmp/profile" "$tmp/profile-slot1"
echo keep >"$tmp/profile/keep"
echo gone >"$tmp/profile-slot1/gone"
out="$(run wipe --yes --slot=1)"
[ ! -e "$tmp/profile-slot1" ] || fail "wipe --slot=1 must remove only slot 1 profile" "$out"
[ -e "$tmp/profile/keep" ] || fail "wipe --slot=1 must leave slot 0 profile" "$out"
mkdir -p "$tmp/profile-slot1"
for bad in "--slot1" "--slotX" "--bogus" "extra"; do
    out="$(run wipe --yes "$bad")" && fail "wipe must reject unknown arg: $bad" "$out"
    grep -q 'error: usage' <<<"$out" || fail "wipe unknown arg should be usage error: $bad" "$out"
done
# unknown flags with a following value are never silently shifted
for bad in "--slott" "-slot"; do
    out="$(run wipe --yes "$bad" 1)" && fail "wipe must reject unknown option: $bad" "$out"
    grep -q 'error: usage' <<<"$out" || fail "wipe unknown option should be usage error: $bad" "$out"
done
[ -e "$tmp/profile/keep" ] || fail "rejected wipe must not delete slot 0 profile"
[ -e "$tmp/profile-slot1" ] || fail "rejected wipe must not delete slot 1 profile"
for bad in "--bogus" "--slotX" "--slott"; do
    out="$(run check site "$bad")" && fail "check must reject unknown option: $bad" "$out"
    grep -q 'error: usage' <<<"$out" || fail "check unknown option should be usage error: $bad" "$out"
done
out="$(run check site --unknown-site-flag)" && fail "check must reject unknown options" "$out"
grep -q 'error: usage' <<<"$out" || fail "check unknown option should be usage error" "$out"

# check --slot=N is accepted, never treated as the site
out="$(run check github --slot=1)" || true
grep -q 'slot 1 browser is not running' <<<"$out" || fail "check --slot=1 must select slot 1, not site" "$out"
out="$(run check github --slot 1)" || true
grep -q 'slot 1 browser is not running' <<<"$out" || fail "check --slot 1 must select slot 1" "$out"

# agent_browser._record_target never recreates a removed lease file
command -v python3 >/dev/null || fail "python3 not found"
py_lease="$tmp/pylease"
printf 'slot=0\ntarget=T1\ncreated=1\n' >"$py_lease"
PYTHONPATH="$here/home/dot_local/share/agent-browser" python3 - "$py_lease" <<'PY' || fail "_record_target must update existing and never recreate removed lease"
import os, sys
os.environ["AGENT_BROWSER_LEASE_FILE"] = sys.argv[1]
from agent_browser import _record_target
_record_target("T2")
lines = open(sys.argv[1]).read().splitlines()
assert "target=T2" in lines and "slot=0" in lines and not any(l.startswith("target=T1") for l in lines), lines
os.remove(sys.argv[1])
_record_target("T3")
assert not os.path.exists(sys.argv[1]), "a removed lease file must not be recreated"
PY

# No tailnet means no viewer at all: never fall back to another interface.
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/tailscale"
out="$(run start)" && fail "start without a tailnet address must fail" "$out"
grep -q 'no_tailnet' <<<"$out" || fail "missing tailnet should be a structured error" "$out"

echo "ok: agent-browser"
