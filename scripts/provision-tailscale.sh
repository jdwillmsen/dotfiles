#!/usr/bin/env bash
set -euo pipefail
# Installs Tailscale and joins this machine to the tailnet, so the devbox is
# reachable by stable identity from any network without opening a router port.
#
# Not a chezmoi run_ script on purpose: apt and `tailscale up` need root, and
# `chezmoi apply` runs unattended (CI, devcontainers, first-boot bootstrap)
# where a sudo password prompt would hang the apply. Run this once per machine.
#
#   sudo scripts/provision-tailscale.sh
#
# Idempotent — re-running with the package installed and the node already
# authenticated is a no-op.

TARGET_USER=${TARGET_USER:-${SUDO_USER:-}}

die() { echo "provision-tailscale: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
[ -n "$TARGET_USER" ] || die "no target user — run via sudo, or set TARGET_USER"

[ -r /etc/os-release ] || die "no /etc/os-release — cannot pick a package repo"
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "only wired up for Ubuntu, found '${ID:-unknown}'"
[ -n "${VERSION_CODENAME:-}" ] || die "no VERSION_CODENAME in /etc/os-release"

KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
SOURCES=/etc/apt/sources.list.d/tailscale.list
BASE_URL="https://pkgs.tailscale.com/stable/ubuntu"

step "Adding the Tailscale apt repo"
if [ -s "$KEYRING" ] && [ -s "$SOURCES" ]; then
    echo "already present"
else
    curl -fsSL "$BASE_URL/${VERSION_CODENAME}.noarmor.gpg" >"$KEYRING"
    curl -fsSL "$BASE_URL/${VERSION_CODENAME}.tailscale-keyring.list" >"$SOURCES"
    echo "added for $VERSION_CODENAME"
fi

step "Installing tailscale"
if command -v tailscale &>/dev/null; then
    echo "already installed: $(tailscale version | head -1)"
else
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq tailscale
    echo "installed: $(tailscale version | head -1)"
fi

systemctl enable --now tailscaled

step "Joining the tailnet"
if tailscale status &>/dev/null; then
    echo "already authenticated as $(tailscale status --json | grep -o '"DNSName":"[^"]*"' | head -1)"
else
    echo "Opening an auth URL — sign in with the account that owns the tailnet."
    # --hostname pins the MagicDNS name; the HTTPS cert T3 Code serves on is
    # issued for it, so an inferred hostname would move the URL out from under
    # every paired device.
    tailscale up --hostname=devbox --ssh
fi

step "Done"
tailscale ip -4
echo "See docs/t3code.md for what consumes this address."
