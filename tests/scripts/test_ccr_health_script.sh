#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
svc="$here/home/dot_config/systemd/user/ccr-health.service"
timer="$here/home/dot_config/systemd/user/ccr-health.timer"
probe="$here/home/dot_local/bin/executable_ccr-health"
trigger="$here/home/run_onchange_49-enable-ccr-health.sh.tmpl"

for f in "$svc" "$timer" "$trigger"; do
    [ -f "$f" ] || { echo "FAIL: missing $(basename "$f")"; exit 1; }
done
[ -x "$probe" ] || { echo "FAIL: ccr-health missing or not executable"; exit 1; }

# ── Unit shape ──
# oneshot, not simple: `ccr start` double-forks, so a supervised ExecStart exits
# immediately and Restart=always turns into a restart loop.
grep -q "^Type=oneshot$" "$svc" || { echo "FAIL: health service is not Type=oneshot"; exit 1; }
grep -q "^ExecStart=%h/.local/bin/ccr-health$" "$svc" \
    || { echo "FAIL: ExecStart does not point at the ccr-health probe"; exit 1; }
grep -q "^Restart=" "$svc" && { echo "FAIL: a oneshot probe must not carry a Restart policy"; exit 1; }
# Without this the finished probe's cgroup teardown kills the router it just
# started, one second after every "repair".
grep -q "^KillMode=process$" "$svc"     || { echo "FAIL: oneshot cgroup teardown will kill the restarted router"; exit 1; }

grep -q "^OnBootSec=" "$timer" || { echo "FAIL: timer does not cover cold boot"; exit 1; }
grep -q "^OnUnitActiveSec=1min$" "$timer" || { echo "FAIL: timer does not re-probe every minute"; exit 1; }
grep -q "^WantedBy=timers.target$" "$timer" || { echo "FAIL: timer will not be started by systemd"; exit 1; }
# The service is triggered by the timer, so it must not also be pulled in by
# default.target — that would run a probe at login and never again.
grep -q "^\[Install\]" "$svc" && { echo "FAIL: health service should be timer-triggered only"; exit 1; }

for dep in ccr-health.service ccr-health.timer executable_ccr-health; do
    grep -q "$dep" "$trigger" || { echo "FAIL: $dep edits do not trigger daemon-reload"; exit 1; }
done

tmp="$(mktemp -d)"
srv=""
# shellcheck disable=SC2064  # $tmp/$srv must expand now: the trap outlives their scope
trap "[ -n \"\$srv\" ] && kill \$srv 2>/dev/null; rm -rf '$tmp'" EXIT
mkdir -p "$tmp/bin" "$tmp/home"
bash_dir="$(dirname "$(command -v bash)")"
curl_dir="$(dirname "$(command -v curl)")"
node_dir="$(dirname "$(command -v node)")"
stub_path="$tmp/bin:$bash_dir:$curl_dir:$node_dir:/usr/bin:/bin"
log="$tmp/calls.log"

# Stub ccr records argv to a file: the probe discards ccr's own output, which is
# exactly the call these assertions need to see.
cat >"$tmp/bin/ccr" <<'STUB'
#!/usr/bin/env bash
echo "CCR_CALLED: $*" >>"$CCR_CALL_LOG"
STUB
chmod +x "$tmp/bin/ccr"

# ── Router answering: probe must be a no-op ──
# A repair that fires against a healthy router would kill live sessions every
# minute, which is worse than the outage it exists to prevent.
cat >"$tmp/srv.js" <<'JS'
const http = require("http"), fs = require("fs");
const s = http.createServer((req, res) => res.end("ok"));
s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], String(s.address().port)));
JS
node "$tmp/srv.js" "$tmp/port" &
srv=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || { echo "FAIL: stub router never bound a port"; exit 1; }

: >"$log"
HOME="$tmp/home" PATH="$stub_path" CCR_CALL_LOG="$log" CCR_PORT="$(cat "$tmp/port")" bash "$probe" \
    || { echo "FAIL: probe reported failure against a healthy router"; exit 1; }
[ -s "$log" ] && { echo "FAIL: probe restarted a router that was answering"; cat "$log"; exit 1; }

# ── Router dead: stale state cleared, then started ──
# Port 9 (discard) is closed everywhere.
: >"$log"
set +e
HOME="$tmp/home" PATH="$stub_path" CCR_CALL_LOG="$log" CCR_PORT=9 CCR_HEALTH_WAIT_TRIES=1 \
    bash "$probe" >"$tmp/out" 2>&1
rc=$?
set -e
[ "$(head -n 1 "$log")" = "CCR_CALLED: stop" ] \
    || { echo "FAIL: probe does not clear stale router state before starting"; cat "$log"; exit 1; }
grep -q "^CCR_CALLED: start$" "$log" || { echo "FAIL: probe never started the router"; cat "$log"; exit 1; }

# A repair that could not repair must fail loudly: exit 0 here would let systemd
# record a healthy run for a router that is still down.
[ "$rc" -eq 0 ] && { echo "FAIL: probe exited 0 with the router still dead"; cat "$tmp/out"; exit 1; }
grep -q "still not answering" "$tmp/out" \
    || { echo "FAIL: no diagnostic when the restart did not take"; cat "$tmp/out"; exit 1; }

# ── ccr absent everywhere: name the missing dependency ──
set +e
out="$(HOME="$tmp/home" PATH="$bash_dir:$curl_dir:/usr/bin:/bin" CCR_PORT=9 bash "$probe" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: probe exited 0 with ccr missing"; echo "$out"; exit 1; }
echo "$out" | grep -q "ccr not found" \
    || { echo "FAIL: no actionable diagnostic when ccr is missing"; echo "$out"; exit 1; }

echo "PASS"
