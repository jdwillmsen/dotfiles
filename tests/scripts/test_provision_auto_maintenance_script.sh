#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-auto-maintenance.sh"
shellcheck -s bash "$script"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$script" ] || fail "provision-auto-maintenance.sh must be executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Root-touching commands are stubs that record their argv; files land under
# PROVISION_ROOT, so the assertions are on what the system was asked to do.
mkdir -p "$tmp/bin"
for c in apt-get systemctl; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\n' "$c" "$tmp" >"$tmp/bin/$c"
    chmod +x "$tmp/bin/$c"
done
user="$(id -un)"

run() {  # $1 = uid the stub id reports, rest = env assignments -> out, rc, calls
    local uid="$1"
    shift
    # shellcheck disable=SC2016  # the stub expands its own $1 and $@ when it runs
    printf '#!/usr/bin/env bash\n[ "${1:-}" = -u ] && { echo %s; exit 0; }\nexec /usr/bin/id "$@"\n' "$uid" >"$tmp/bin/id"
    chmod +x "$tmp/bin/id"
    : >"$tmp/calls"
    rm -rf "$tmp/root"
    rc=0
    out="$(env PATH="$tmp/bin:$PATH" PROVISION_ROOT="$tmp/root" SUDO_USER="$user" "$@" \
        bash "$script" 2>&1)" || rc=$?
    calls="$(cat "$tmp/calls")"
}

# ── refuses without root, before touching anything ──
run 1000
[ "$rc" -ne 0 ] || fail "ran without root"
echo "$out" | grep -q "must run as root" || fail "no diagnostic without root" "$out"
[ -z "$calls" ] || fail "mutated the system before the root check" "$calls"

# ── refuses to watch root or nobody ──
run 0 SUDO_USER=
[ "$rc" -ne 0 ] || fail "ran with no user to watch"
run 0 MAINT_USER=root
[ "$rc" -ne 0 ] || fail "accepted root as the watched user"
run 0 IDLE_MINUTES=x
[ "$rc" -ne 0 ] || fail "accepted a non-numeric IDLE_MINUTES"
run 0 REBOOT_WINDOW='8-12'
[ "$rc" -ne 0 ] || fail "accepted a malformed REBOOT_WINDOW"
[ -z "$calls" ] || fail "mutated the system on bad input" "$calls"

# ── default run ──
run 0
[ "$rc" -eq 0 ] || fail "default run exited $rc" "$out"

dropin="$tmp/root/etc/apt/apt.conf.d/52devbox-unattended"
[ -f "$dropin" ] || fail "no apt drop-in written"
# apt's own parser is the consumer; it must see the -updates origin appended
# to the shipped list and the reboot left off.
if command -v apt-config >/dev/null 2>&1; then
    dump="$(apt-config -c "$dropin" dump)"
    # shellcheck disable=SC2016  # the ${...} are apt variables, matched literally
    echo "$dump" | grep -qF 'Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-updates";' \
        || fail "apt does not parse the -updates origin" "$dump"
    echo "$dump" | grep -qF 'Unattended-Upgrade::Automatic-Reboot "false";' \
        || fail "apt does not parse Automatic-Reboot false" "$dump"
fi

guard="$tmp/root/usr/local/sbin/devbox-reboot-guard"
[ -x "$guard" ] || fail "guard not installed executable"
cmp -s "$guard" "$here/scripts/devbox-reboot-guard" || fail "installed guard differs from source"

svc="$tmp/root/etc/systemd/system/devbox-reboot-guard.service"
timer="$tmp/root/etc/systemd/system/devbox-reboot-guard.timer"
grep -qx "Environment=MAINT_USER=$user" "$svc" || fail "service does not watch $user" "$(cat "$svc")"
grep -qx "Environment=IDLE_MINUTES=60" "$svc" || fail "default idle not 60" "$(cat "$svc")"
grep -qx "ExecStart=/usr/local/sbin/devbox-reboot-guard" "$svc" || fail "service runs the wrong path"
grep -q '^Persistent=' "$timer" && fail "timer must not catch up missed runs at boot"
oncal="$(sed -n 's/^OnCalendar=//p' "$timer")"
[ "$oncal" = "*-*-* 08..12:30:00 UTC" ] || fail "unexpected default window '$oncal'"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "$oncal" >/dev/null || fail "systemd rejects OnCalendar '$oncal'"
    systemd-analyze verify "$svc" "$timer" 2>&1 | grep -v 'devbox-reboot-guard\b.*not executable\|No such file' \
        | grep -i 'error\|invalid' && fail "systemd-analyze verify flagged the units"
fi

echo "$calls" | grep -qx "systemctl daemon-reload" || fail "no daemon-reload" "$calls"
echo "$calls" | grep -qx "systemctl enable --now devbox-reboot-guard.timer" || fail "timer not enabled" "$calls"
reload_at="$(echo "$calls" | grep -nx 'systemctl daemon-reload' | cut -d: -f1)"
enable_at="$(echo "$calls" | grep -nx 'systemctl enable --now devbox-reboot-guard.timer' | cut -d: -f1)"
[ "$reload_at" -lt "$enable_at" ] || fail "enabled before reloading units" "$calls"

# ── overrides reach the units ──
run 0 IDLE_MINUTES=90 ESCALATE_DAYS=3 REBOOT_WINDOW=02..04
grep -qx "Environment=IDLE_MINUTES=90" "$svc" || fail "IDLE_MINUTES override lost"
grep -qx "Environment=ESCALATE_DAYS=3" "$svc" || fail "ESCALATE_DAYS override lost"
grep -qx "OnCalendar=\*-\*-\* 02..04:30:00 UTC" "$timer" || fail "REBOOT_WINDOW override lost" "$(cat "$timer")"

# ── idempotent ──
run 0
first="$(cat "$dropin" "$svc" "$timer")"
run 0
[ "$first" = "$(cat "$dropin" "$svc" "$timer")" ] || fail "second run changed the output"

echo "provision-auto-maintenance: all tests passed"
