#!/usr/bin/env bash
set -euo pipefail
# Recorded workload history (atop), so a stall can be traced to the process
# behind it after the fact rather than only while it is happening.
#
# Not a chezmoi run_ script: atop logs as a system service and needs root,
# and `chezmoi apply` runs unattended where a sudo prompt would hang it.
#
#   sudo scripts/provision-monitoring.sh
#
# Idempotent — re-running rewrites the same config and restarts the logger.

ATOP_INTERVAL=${ATOP_INTERVAL:-60}
ATOP_GENERATIONS=${ATOP_GENERATIONS:-14}
ATOP_LOGPATH=${ATOP_LOGPATH:-/var/log/atop}
ATOP_DEFAULTS=${ATOP_DEFAULTS:-/etc/default/atop}

die() { echo "provision-monitoring: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
command -v apt-get &>/dev/null || die "needs apt-get (Debian-family only)"
command -v systemctl &>/dev/null || die "needs systemd"
for v in ATOP_INTERVAL ATOP_GENERATIONS; do
    case "${!v}" in
        '' | *[!0-9]* | 0) die "$v must be a positive whole number, got '${!v}'" ;;
    esac
done

step "atop"
apt-get update -qq
apt-get install -y -qq atop

step "logging config"
# The package samples every 600s. Averaged over ten minutes, a disk stall of a
# few seconds — long enough to drop every client WebSocket — reads as a quiet
# interval. 60s still dilutes it, but leaves the culprit visible.
cat >"$ATOP_DEFAULTS" <<EOF
LOGOPTS=""
LOGINTERVAL=$ATOP_INTERVAL
LOGGENERATIONS=$ATOP_GENERATIONS
LOGPATH=$ATOP_LOGPATH
EOF

step "services"
# atopacct records processes that exit between samples, which short-lived
# build and agent subprocesses otherwise escape entirely.
systemctl enable --now atopacct.service atop-rotate.timer
systemctl enable atop.service
# The logger reads its interval only at start, so a running one keeps the old
# value until restarted.
systemctl restart atop.service

step "result"
systemctl --no-pager --lines=0 status atop.service || true
echo
echo "provision-monitoring: logging every ${ATOP_INTERVAL}s to $ATOP_LOGPATH, keeping ${ATOP_GENERATIONS} days"
echo "replay a window with: atop -r $ATOP_LOGPATH/atop_YYYYMMDD -b HH:MM"
