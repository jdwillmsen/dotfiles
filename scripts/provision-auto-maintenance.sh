#!/usr/bin/env bash
set -euo pipefail
# Hands-off patching: every stable update installs on its own, and the reboot
# that kernel updates need happens in a quiet window once the box is idle.
#
# Not a chezmoi run_ script: apt config and system timers need root, and
# `chezmoi apply` runs unattended where a sudo prompt would hang it.
#
#   sudo scripts/provision-auto-maintenance.sh
#
# Idempotent — re-running rewrites the same files and re-enables the timer.
# Run it again after editing scripts/devbox-reboot-guard to install the change.

# The user whose agent sessions and terminal input defer a reboot. Under sudo the
# invoking user is the one whose work matters; root's own activity never is.
MAINT_USER=${MAINT_USER:-${SUDO_USER:-}}
IDLE_MINUTES=${IDLE_MINUTES:-60}
ESCALATE_DAYS=${ESCALATE_DAYS:-7}
# UTC hours, matching the box clock. The owner's sessions go quiet in this
# stretch; a guard that only ever finds them busy just escalates sooner.
REBOOT_WINDOW=${REBOOT_WINDOW:-08..12}
# Not a setting: only so the test can run unprivileged.
root="${PROVISION_ROOT:-}"

here="$(cd "$(dirname "$0")" && pwd)"
apt_dropin="$root/etc/apt/apt.conf.d/52devbox-unattended"
guard="$root/usr/local/sbin/devbox-reboot-guard"
unit_dir="$root/etc/systemd/system"

die() { echo "provision-auto-maintenance: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
command -v apt-get &>/dev/null || die "needs apt-get (Debian-family only)"
command -v systemctl &>/dev/null || die "needs systemd"
if [ -z "$MAINT_USER" ] || [ "$MAINT_USER" = root ]; then
    die "set MAINT_USER to the user whose work defers a reboot (run via sudo, or MAINT_USER=<name>)"
fi
getent passwd "$MAINT_USER" >/dev/null || die "no such user '$MAINT_USER'"
for v in IDLE_MINUTES ESCALATE_DAYS; do
    case "${!v}" in
        '' | *[!0-9]* | ?????*) die "$v must be a whole number below 10000, got '${!v}'" ;;
    esac
done
case "$REBOOT_WINDOW" in
    [0-9][0-9]..[0-9][0-9]) ;;
    *) die "REBOOT_WINDOW must be HH..HH in UTC, got '$REBOOT_WINDOW'" ;;
esac
[ -f "$here/devbox-reboot-guard" ] || die "missing $here/devbox-reboot-guard"

step "unattended-upgrades: all stable updates, no reboot of its own"
apt-get install -y -qq unattended-upgrades
mkdir -p "$(dirname "$apt_dropin")"
# A separate drop-in rather than an edit to 50unattended-upgrades: that file
# is a package conffile, so editing it turns every package upgrade into a
# conffile prompt. The "::" suffix appends to the shipped origin list.
cat >"$apt_dropin" <<'EOF'
Unattended-Upgrade::Allowed-Origins:: "${distro_id}:${distro_codename}-updates";
// The reboot is devbox-reboot-guard's decision: it knows when an agent is live.
Unattended-Upgrade::Automatic-Reboot "false";
EOF

step "reboot guard"
install -D -m 0755 "$here/devbox-reboot-guard" "$guard"

mkdir -p "$unit_dir"
cat >"$unit_dir/devbox-reboot-guard.service" <<EOF
[Unit]
Description=Reboot for pending updates when the devbox is idle

[Service]
Type=oneshot
Environment=MAINT_USER=$MAINT_USER
Environment=IDLE_MINUTES=$IDLE_MINUTES
Environment=ESCALATE_DAYS=$ESCALATE_DAYS
ExecStart=/usr/local/sbin/devbox-reboot-guard
EOF
cat >"$unit_dir/devbox-reboot-guard.timer" <<EOF
[Unit]
Description=Hourly reboot check inside the quiet window

[Timer]
OnCalendar=*-*-* $REBOOT_WINDOW:30:00 UTC
# No Persistent=: a run missed while the box was off must not fire at boot,
# which is usually the middle of someone's working hours.
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now devbox-reboot-guard.timer

step "done"
echo "watching $MAINT_USER; idle ${IDLE_MINUTES}m; window ${REBOOT_WINDOW} UTC; notice after ${ESCALATE_DAYS}d"
echo "check the decision now: sudo MAINT_USER=$MAINT_USER $guard --dry-run"
