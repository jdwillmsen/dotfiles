#!/usr/bin/env bash
set -euo pipefail
# Keeps the user's systemd instance (and anything running under it — a
# detached tmux server included) alive with zero active login sessions.
#
# Not a chezmoi run_ script on purpose: `loginctl enable-linger` needs root,
# and `chezmoi apply` runs unattended (CI, devcontainers, first-boot
# bootstrap) where a sudo password prompt would hang the apply. Run this once
# per machine.
#
#   sudo scripts/provision-persistence.sh
#
# Idempotent — re-running when linger is already enabled is a no-op.

TARGET_USER=${TARGET_USER:-${SUDO_USER:-}}

die() { echo "provision-persistence: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
[ -n "$TARGET_USER" ] || die "no target user — run via sudo, or set TARGET_USER"
command -v loginctl &>/dev/null || die "needs loginctl (systemd-logind)"

step "Enabling linger for $TARGET_USER"
if loginctl show-user "$TARGET_USER" -p Linger 2>/dev/null | grep -q '^Linger=yes$'; then
    echo "already enabled"
else
    loginctl enable-linger "$TARGET_USER"
    echo "enabled"
fi

step "Done"
echo "systemd --user, and anything under it (a detached tmux server), now"
echo "survives the last SSH session closing. See docs/persistence.md."
