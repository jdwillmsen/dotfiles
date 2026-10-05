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
# Not a setting: atop.service and atop.daily both read /etc/default/atop, so
# only the root it sits under moves, and only so the test can run unprivileged.
ATOP_DEFAULTS="${PROVISION_ROOT:-}/etc/default/atop"

die() { echo "provision-monitoring: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
command -v apt-get &>/dev/null || die "needs apt-get (Debian-family only)"
command -v systemctl &>/dev/null || die "needs systemd"
for v in ATOP_INTERVAL ATOP_GENERATIONS; do
    case "${!v}" in
        # Nine digits bounds it below 64-bit arithmetic, which would wrap
        # an absurd value into a small valid-looking one.
        '' | *[!0-9]* | ??????????*) die "$v must be a positive whole number, got '${!v}'" ;;
    esac
    # "00" is still zero: atop treats a zero interval as manual sampling only,
    # and rotation as a zero-day cutoff. Base 10, so a leading 0 is not octal.
    [ "$((10#${!v}))" -gt 0 ] || die "$v must be a positive whole number, got '${!v}'"
    printf -v "$v" '%d' "$((10#${!v}))"
done
# atop.daily sources this file as shell while systemd reads it as an
# EnvironmentFile; a space or shell metacharacter would point the logger and
# the rotation at different directories, so allow only plain path characters.
case "$ATOP_LOGPATH" in
    /*[!A-Za-z0-9._/-]* | [!/]* | '') die "ATOP_LOGPATH must be an absolute path of letters, digits, . _ - and /, got '$ATOP_LOGPATH'" ;;
esac

step "atop"
apt-get update -qq
# /etc/default/atop is a dpkg conffile this script rewrites, so an upgrade that
# changes the packaged copy would stop at dpkg's keep-or-replace prompt. Keep
# ours unasked; it is rewritten below either way.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confold atop

step "logging config"
# The package samples every 600s. Averaged over ten minutes, a disk stall of a
# few seconds — long enough to drop every client WebSocket — reads as a quiet
# interval. 60s still dilutes it, but leaves the culprit visible.
mkdir -p "${ATOP_DEFAULTS%/*}"
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
