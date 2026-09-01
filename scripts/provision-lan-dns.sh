#!/usr/bin/env bash
set -euo pipefail
# Points jdwlabs.com at the LAN resolver on the HAProxy VM, so
# cluster.jdwlabs.com reaches the Kubernetes apiserver from this machine
# without a hosts-file entry.
#
# Public DNS answers jdwlabs.com with the WAN address, and the apiserver port
# is not forwarded there, so a LAN machine resolving publicly has no path to
# the cluster at all. The gateway cannot express a per-name override, hence a
# resolver rather than a router setting.
#
# Not a chezmoi run_ script on purpose: writing under /etc and restarting
# systemd-resolved need root, and `chezmoi apply` runs unattended (CI,
# devcontainers, first-boot bootstrap) where a sudo password prompt would hang
# the apply. Run this once per machine.
#
#   sudo scripts/provision-lan-dns.sh
#
# Idempotent — re-running with the drop-in already in place is a no-op.

RESOLVER=${RESOLVER:-192.168.1.199}
FALLBACK=${FALLBACK:-192.168.1.254}
DOMAIN=${DOMAIN:-jdwlabs.com}
DROPIN=${DROPIN:-/etc/systemd/resolved.conf.d/10-jdwlabs-lan.conf}

die() { echo "provision-lan-dns: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
command -v resolvectl &>/dev/null || die "needs resolvectl (systemd-resolved)"

# Scoping to a routing domain rather than replacing the machine's default
# nameservers is the whole safety argument: if the resolver on the HAProxy VM
# is down, only jdwlabs.com degrades to the gateway's public answer, and every
# other name still resolves exactly as before.
desired=$(
    cat <<EOF
# Managed by scripts/provision-lan-dns.sh — see docs/provisioning.md.
[Resolve]
DNS=$RESOLVER $FALLBACK
Domains=~$DOMAIN
EOF
)

step "Writing $DROPIN"
if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$desired" ]; then
    echo "already current"
else
    install -d -m 0755 "$(dirname "$DROPIN")"
    printf '%s\n' "$desired" >"$DROPIN"
    chmod 0644 "$DROPIN"
    echo "written"
    step "Restarting systemd-resolved"
    systemctl restart systemd-resolved
fi

# Verifying against the live resolver rather than the file catches the case
# where the drop-in is correct but something else on the machine — a VPN client
# rewriting resolv.conf, a stale stub — wins the lookup anyway.
step "Verifying"
got=$(resolvectl query --legend=false "cluster.$DOMAIN" 2>/dev/null | awk 'NR==1 {print $2}')
[ "$got" = "$RESOLVER" ] ||
    die "cluster.$DOMAIN resolved to '${got:-nothing}', expected $RESOLVER"
echo "cluster.$DOMAIN -> $got"

step "Done"
echo "jdwlabs.com now resolves via $RESOLVER; all other names are untouched."
echo "Remove $DROPIN and restart systemd-resolved to roll back."
