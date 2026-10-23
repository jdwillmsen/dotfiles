#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# The delivery timers (merge-captain every 15 minutes, agent-eval-collect
# daily) and the script that enables them: unit contents, the reload trigger's
# hashes, and the enable script's safety guards against a stubbed systemctl.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
units="$here/home/dot_config/systemd/user"
trigger="$here/home/run_onchange_58-enable-agent-delivery.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT

# ── merge-captain.service / .timer ──
svc="$units/merge-captain.service"
timer="$units/merge-captain.timer"
grep -qx 'Type=oneshot' "$svc" || fail "merge-captain service must be oneshot"
grep -qx 'ExecStart=%h/.local/bin/merge-captain run' "$svc" || fail "merge-captain ExecStart"
grep -qx 'Nice=10' "$svc" || fail "merge-captain should run niced"
grep -qx 'TimeoutStartSec=30min' "$svc" || fail "merge-captain needs a hard timeout"
grep -qx 'NoNewPrivileges=yes' "$svc" && grep -qx 'PrivateTmp=yes' "$svc" || fail "merge-captain hardening missing"
grep -qx 'Environment=PATH=%h/.local/bin:%h/.local/npm-bin:/usr/local/bin:/usr/bin:/bin' "$svc" ||
    fail "merge-captain needs a PATH that reaches gh and the model CLIs"
grep -qxF 'OnCalendar=*:0/15' "$timer" || fail "merge-captain timer calendar"
grep -qx 'Persistent=false' "$timer" || fail "a missed merge-captain slot must not be caught up"
grep -qx 'RandomizedDelaySec=60' "$timer" || fail "merge-captain timer jitter"
grep -qx 'Unit=merge-captain.service' "$timer" || fail "merge-captain timer target"
grep -qx 'WantedBy=timers.target' "$timer" || fail "merge-captain timer install target"

# ── agent-eval-collect.service / .timer ──
esvc="$units/agent-eval-collect.service"
etimer="$units/agent-eval-collect.timer"
grep -qx 'Type=oneshot' "$esvc" || fail "agent-eval-collect service must be oneshot"
collect_line="$(grep -n '^ExecStart=%h/.local/bin/agent-eval collect$' "$esvc" | cut -d: -f1)"
enrich_line="$(grep -n '^ExecStart=%h/.local/bin/agent-eval enrich$' "$esvc" | cut -d: -f1)"
[ -n "$collect_line" ] && [ -n "$enrich_line" ] && [ "$collect_line" -lt "$enrich_line" ] ||
    fail "agent-eval-collect must run collect, then enrich"
grep -q '^TimeoutStartSec=' "$esvc" || fail "agent-eval-collect needs a hard timeout"
grep -qx 'NoNewPrivileges=yes' "$esvc" && grep -qx 'PrivateTmp=yes' "$esvc" || fail "agent-eval-collect hardening missing"
grep -q '^Environment=PATH=' "$esvc" || fail "agent-eval-collect needs a PATH"
grep -qxF 'OnCalendar=*-*-* 06:45:00' "$etimer" || fail "agent-eval-collect timer calendar"
grep -qx 'Persistent=true' "$etimer" || fail "agent-eval-collect must catch up after downtime"
grep -qx 'Unit=agent-eval-collect.service' "$etimer" || fail "agent-eval-collect timer target"
grep -qx 'WantedBy=timers.target' "$etimer" || fail "agent-eval-collect timer install target"

if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar '*:0/15' >/dev/null || fail "merge-captain calendar rejected by systemd"
    systemd-analyze calendar '*-*-* 06:45:00' >/dev/null || fail "agent-eval-collect calendar rejected by systemd"
fi

# ── The enable script: lint, hashes, rendered text ──
for u in merge-captain.service merge-captain.timer agent-eval-collect.service agent-eval-collect.timer; do
    grep -qF "include \"dot_config/systemd/user/$u\" | sha256sum" "$trigger" ||
        fail "the trigger does not re-run when $u changes"
done
if command -v chezmoi >/dev/null 2>&1; then
    : >"$tmp/empty.toml"
    chezmoi execute-template --source "$here" --config "$tmp/empty.toml" <"$trigger" >"$tmp/rendered.sh" ||
        fail "the enable script does not render"
    bash -n "$tmp/rendered.sh" || fail "the rendered enable script is not valid bash"
    shellcheck -s bash "$tmp/rendered.sh"
    # A scratch destination must skip before anything touches the live user manager.
    chezmoi execute-template --source "$here" --config "$tmp/empty.toml" --destination "$tmp/scratch-dest" \
        <"$trigger" >"$tmp/rendered-scratch.sh" || fail "the enable script does not render for a scratch destination"
    grep -q 'skipping enable' "$tmp/rendered-scratch.sh" || fail "a scratch destination does not skip the enable"
    for u in merge-captain.service merge-captain.timer agent-eval-collect.service agent-eval-collect.timer; do
        grep -qxF "# $(sha256sum "$units/$u" | cut -d' ' -f1)" "$tmp/rendered.sh" ||
            fail "the rendered trigger does not carry $u's hash"
    done
    cp "$tmp/rendered.sh" "$tmp/run.sh"
else
    cp "$trigger" "$tmp/run.sh"
fi

# ── Run it against a stubbed systemctl/loginctl ──
trig="$tmp/trig"
mkdir -p "$trig/bin" "$trig/home/.config/systemd/user"
cp "$svc" "$trig/home/.config/systemd/user/"
cat >"$trig/bin/systemctl" <<'STUB'
#!/bin/sh
if [ "$2" = "show-environment" ]; then echo "HOME=$STUB_MANAGER_HOME"; exit 0; fi
echo "$*" >>"$CALL_LOG"
STUB
cat >"$trig/bin/loginctl" <<'STUB'
#!/bin/sh
echo "${STUB_LINGER:-no}"
STUB
chmod +x "$trig/bin"/*
run_trigger() {  # $1 manager home, $2 linger
    : >"$trig/calls"
    trig_out="$(PATH="$trig/bin:/usr/bin:/bin" HOME="$trig/home" USER=tester BASH_ENV=/dev/null \
        XDG_CONFIG_HOME="$trig/home/.config" CALL_LOG="$trig/calls" STUB_MANAGER_HOME="$1" \
        STUB_LINGER="$2" bash "$tmp/run.sh" 2>&1)"
}
run_trigger /elsewhere no
grep -q "skipping enable" <<<"$trig_out" && [ ! -s "$trig/calls" ] || fail "trigger must skip a scratch-dest apply" "$trig_out"
run_trigger "$trig/home" no
grep -qx -- "--user daemon-reload" "$trig/calls" || fail "trigger never reloads systemd"
grep -qx -- "--user enable --now merge-captain.timer agent-eval-collect.timer" "$trig/calls" ||
    fail "trigger does not enable both timers" "$(cat "$trig/calls")"
grep -q "start" "$trig/calls" && fail "trigger must not start a run by hand"
grep -q "\.service" "$trig/calls" && fail "trigger must only touch the timers, never the services" "$(cat "$trig/calls")"
grep -q "linger is off" <<<"$trig_out" || fail "trigger should warn when linger is off"
run_trigger "$trig/home" yes
grep -q "linger is off" <<<"$trig_out" && fail "no linger warning expected when linger is on"
rm "$trig/home/.config/systemd/user/merge-captain.service"
run_trigger "$trig/home" yes
grep -q "not a home apply" <<<"$trig_out" && [ ! -s "$trig/calls" ] || fail "trigger must skip when the unit is absent" "$trig_out"

echo "test_agent_delivery_units_script: OK"
