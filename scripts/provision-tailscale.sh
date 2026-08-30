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
# Idempotent — re-running reconciles the node against the desired hostname and
# Tailscale SSH state, and is a no-op once both already match.

TS_HOSTNAME=${TS_HOSTNAME:-devbox}
OS_RELEASE=${OS_RELEASE:-/etc/os-release}
KEYRING=${KEYRING:-/usr/share/keyrings/tailscale-archive-keyring.gpg}
SOURCES=${SOURCES:-/etc/apt/sources.list.d/tailscale.list}
BASE_URL=${BASE_URL:-https://pkgs.tailscale.com/stable/ubuntu}

die() { echo "provision-tailscale: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# Publishes a download by atomic rename. A plain `curl >dest` truncates the
# destination before the body arrives, so an interrupted transfer leaves a
# partial file that still satisfies the `-s` guard below — the repo step then
# reports "already present" and apt fails GPG verification on every later run
# until someone deletes the file by hand.
fetch_to() {  # $1 = url, $2 = destination
    local tmp
    tmp="$(mktemp "$2.XXXXXX")"
    if curl -fsSL "$1" >"$tmp"; then
        chmod 0644 "$tmp"
        mv -f "$tmp" "$2"
    else
        rm -f "$tmp"
        die "download failed: $1"
    fi
}

tailnet_dnsname() {
    # --peers=false leaves Self as the only node in the document, so there is
    # exactly one DNSName to match and no dependence on field ordering.
    # Empty on any failure, which reads downstream as "not converged".
    tailscale status --peers=false --json 2>/dev/null |
        sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true
}

tailnet_ssh_enabled() {
    tailscale debug prefs 2>/dev/null | grep -qE '"RunSSH"[[:space:]]*:[[:space:]]*true'
}

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"

[ -r "$OS_RELEASE" ] || die "no $OS_RELEASE — cannot pick a package repo"
# shellcheck disable=SC1090
. "$OS_RELEASE"
[ "${ID:-}" = ubuntu ] || die "only wired up for Ubuntu, found '${ID:-unknown}'"
[ -n "${VERSION_CODENAME:-}" ] || die "no VERSION_CODENAME in $OS_RELEASE"

step "Adding the Tailscale apt repo"
if [ -s "$KEYRING" ] && [ -s "$SOURCES" ]; then
    echo "already present"
else
    fetch_to "$BASE_URL/${VERSION_CODENAME}.noarmor.gpg" "$KEYRING"
    fetch_to "$BASE_URL/${VERSION_CODENAME}.tailscale-keyring.list" "$SOURCES"
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
# --hostname pins the MagicDNS name; the HTTPS cert T3 Code serves on is issued
# for it, so an inferred hostname would move the URL out from under every paired
# device. --ssh is the break-glass path for re-pairing once a T3 Code session
# hits its hard 30-day TTL — see docs/t3code.md.
if ! tailscale status &>/dev/null; then
    echo "Opening an auth URL — sign in with the account that owns the tailnet."
    tailscale up --hostname="$TS_HOSTNAME" --ssh
else
    # Capability check, not a liveness check: a node can be authenticated and
    # running while carrying an inferred hostname and no SSH, which is the
    # state a re-run has to converge rather than skip.
    dns="$(tailnet_dnsname)"
    if [ "${dns%%.*}" = "$TS_HOSTNAME" ] && tailnet_ssh_enabled; then
        echo "already joined as ${dns%.} with Tailscale SSH on"
    else
        echo "joined as ${dns:-<unknown>} — converging hostname and Tailscale SSH"
        tailscale up --hostname="$TS_HOSTNAME" --ssh
    fi
fi

step "Done"
tailscale ip -4
echo "See docs/t3code.md for what consumes this address."
