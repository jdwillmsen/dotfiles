#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
check="$here/home/dot_local/bin/executable_devbox-health-boot"
svc="$here/home/dot_config/systemd/user/devbox-health-boot.service"
timer="$here/home/dot_config/systemd/user/devbox-health-boot.timer"
trigger="$here/home/run_onchange_58-enable-devbox-health-boot.sh.tmpl"
functions="$here/home/dot_config/shell/functions.sh"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$check" ] || fail "devbox-health-boot missing or not executable"
for f in "$svc" "$timer" "$trigger"; do
    [ -f "$f" ] || fail "missing $(basename "$f")"
done
shellcheck -s bash "$check"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── wrapper: marker follows devbox-health's verdict ──
marker="$tmp/state/devbox-health.fail"
fake() {  # fake EXIT LINES... — a devbox-health that prints LINES and exits EXIT
    local rc="$1"
    shift
    { echo '#!/usr/bin/env bash'; printf 'echo %q\n' "$@"; echo "exit $rc"; } >"$tmp/health"
    chmod +x "$tmp/health"
}
run() {
    rc=0
    out="$(XDG_STATE_HOME="$tmp/state" DEVBOX_HEALTH="$tmp/health" bash "$check" 2>&1)" || rc=$?
}

fake 1 "  ok    tailscaled active              active" "  FAIL  t3code active                  got=failed want=active" "  UNKN  tailnet backend                no output"
run
[ "$rc" -eq 1 ] || fail "failure exit not passed through (rc=$rc)"
[ -s "$marker" ] || fail "no marker after a failed check"
grep -q "FAIL  t3code" "$marker" || fail "marker lacks the FAIL line" "$(cat "$marker")"
grep -q "UNKN  tailnet" "$marker" || fail "marker lacks the UNKN line" "$(cat "$marker")"
grep -q "ok    tailscaled" "$marker" && fail "marker carries passing lines" "$(cat "$marker")"
echo "$out" | grep -q "ok    tailscaled" || fail "full report not printed for the journal" "$out"

fake 0 "  ok    everything"
run
[ "$rc" -eq 0 ] || fail "healthy run exited $rc"
[ ! -e "$marker" ] || fail "marker survived a healthy run"

# ── units, through systemd's own parser where available ──
grep -qx 'ExecStart=%h/.local/bin/devbox-health-boot' "$svc" || fail "service runs the wrong path"
grep -qx 'Type=oneshot' "$svc" || fail "service is not oneshot"
grep -q '^OnStartupSec=' "$timer" || fail "timer is not relative to manager start"
grep -q '^OnCalendar=\|^Persistent=' "$timer" && fail "boot check must not also run on a calendar"
grep -qx 'WantedBy=timers.target' "$timer" || fail "timer not wanted by timers.target"
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$tmp/units"
    sed 's|%h/.local/bin/devbox-health-boot|/bin/true|' "$svc" >"$tmp/units/devbox-health-boot.service"
    cp "$timer" "$tmp/units/"
    v="$(systemd-analyze --user verify "$tmp/units/devbox-health-boot.service" "$tmp/units/devbox-health-boot.timer" 2>&1 || true)"
    echo "$v" | grep -qi 'invalid\|unknown key\|failed to parse' && fail "systemd rejects the units" "$v"
fi

# ── enable trigger renders, lints, and re-runs when any input changes ──
if command -v chezmoi >/dev/null 2>&1; then
    rendered="$(chezmoi execute-template --source="$here/home" <"$trigger")"
    printf '%s\n' "$rendered" >"$tmp/trigger.sh"
    shellcheck -s bash "$tmp/trigger.sh"
    echo "$rendered" | grep -qx 'systemctl --user enable devbox-health-boot.timer' \
        || fail "trigger does not enable the timer" "$rendered"
    echo "$rendered" | grep -q 'start devbox-health-boot.service' \
        && fail "trigger must not run the boot check at apply time"
    for rel in dot_config/systemd/user/devbox-health-boot.service dot_config/systemd/user/devbox-health-boot.timer \
        dot_local/bin/executable_devbox-health-boot; do
        src="$tmp/src"
        rm -rf "$src"
        cp -a "$here/home" "$src"
        printf '\n# touched-for-test\n' >>"$src/$rel"
        [ "$(chezmoi execute-template --source="$src" <"$trigger")" != "$rendered" ] \
            || fail "trigger does not re-run when $rel changes"
    done
fi

# ── maintenance_notice: silent when clean, prints each marker ──
mkdir -p "$tmp/home"
notice() { HOME="$tmp/home" XDG_STATE_HOME="$tmp/state" bash -c 'source "$1"; maintenance_notice' _ "$functions" 2>&1; }
[ -z "$(notice)" ] || fail "notice not silent on a clean box" "$(notice)"
fake 1 "  FAIL  t3code active"
run || true
notice | grep -q "devbox-health failed after boot" || fail "notice does not show the health marker" "$(notice)"
for rc_file in "$here/home/dot_bashrc" "$here/home/dot_zshrc"; do
    grep -qx 'command -v maintenance_notice >/dev/null 2>&1 && maintenance_notice' "$rc_file" \
        || fail "$(basename "$rc_file") never calls maintenance_notice"
done

echo "devbox-health-boot: all tests passed"
