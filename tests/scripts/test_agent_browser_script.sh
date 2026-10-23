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
trap 'pkill -f "$tmp/bin/" 2>/dev/null || true; rm -rf "$tmp"' EXIT
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

# PATH is built from scratch: inherited, the real binaries on this machine
# would answer for the stubs.
run() {
    env -i HOME="$tmp/home" PATH="$bin:/usr/bin:/bin" \
        AGENT_BROWSER_RUN="$tmp/run" AGENT_BROWSER_PROFILE="$tmp/profile" \
        bash "$cli" "$@"
}

out="$(run)"
grep -q 'state: stopped' <<<"$out" || fail "no-args should report stopped" "$out"

out="$(run start https://example.com)"
grep -q 'state: running' <<<"$out" || fail "start should report running" "$out"
grep -q 'viewer: http://100.64.0.7:6080/vnc.html' <<<"$out" || fail "viewer must use the tailnet address" "$out"

chrome_args="$(cat "$tmp/google-chrome.args")"
grep -q -- '--remote-debugging-address=127.0.0.1' <<<"$chrome_args" || fail "CDP must bind to loopback" "$chrome_args"
grep -q -- "--user-data-dir=$tmp/profile" <<<"$chrome_args" || fail "chrome must use the persistent profile" "$chrome_args"
grep -q 'https://example.com' <<<"$chrome_args" || fail "start URL not passed to chrome" "$chrome_args"
grep -q -- '-localhost' "$tmp/x11vnc.args" || fail "VNC must bind to localhost"
grep -q '100.64.0.7:6080' "$tmp/websockify.args" || fail "viewer must bind to the tailnet address only"
[ "$(stat -c %a "$tmp/profile")" = 700 ] || fail "profile must be private"

out="$(run start)"
grep -q 'state: running' <<<"$out" || fail "second start must be idempotent" "$out"

out="$(run wipe)" && fail "wipe without --yes must fail" "$out"
grep -q 'confirmation_required' <<<"$out" || fail "wipe should explain the confirmation" "$out"
out="$(run wipe --yes)" && fail "wipe while running must fail" "$out"
[ -d "$tmp/profile" ] || fail "profile must survive a refused wipe"

out="$(run stop)"
grep -q 'stopped: 4' <<<"$out" || fail "stop should stop all four components" "$out"
grep -q 'kept' <<<"$out" || fail "stop must keep the profile" "$out"
out="$(run)"
grep -q 'state: stopped' <<<"$out" || fail "status after stop should be stopped" "$out"

out="$(run wipe --yes)"
[ ! -e "$tmp/profile" ] || fail "wipe --yes should delete the profile" "$out"

out="$(run bogus)" && fail "unknown command must fail" "$out"
grep -q 'unknown_command' <<<"$out" || fail "unknown command should be a structured error" "$out"

# No tailnet means no viewer at all: never fall back to another interface.
printf '#!/usr/bin/env bash\nexit 1\n' >"$bin/tailscale"
out="$(run start)" && fail "start without a tailnet address must fail" "$out"
grep -q 'no_tailnet' <<<"$out" || fail "missing tailnet should be a structured error" "$out"

echo "ok: agent-browser"
