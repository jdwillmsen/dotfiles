#!/usr/bin/env bash
set -euo pipefail
# Two-tier swap (compressed RAM first, disk file for true overflow) plus
# pressure-based OOM handling, for Debian-family machines.
#
# Not a chezmoi run_ script on purpose: every step needs root, and `chezmoi
# apply` runs unattended (CI, devcontainers, first-boot bootstrap) where a
# sudo password prompt would hang the apply. Run this once per machine.
#
#   sudo scripts/provision-swap.sh
#
# Idempotent — re-running only fills in what is missing.

SWAPFILE=${SWAPFILE:-/swapfile}
SWAPFILE_SIZE=${SWAPFILE_SIZE:-16G}
SWAPFILE_PRIORITY=${SWAPFILE_PRIORITY:-10}
ZRAM_ALGO=${ZRAM_ALGO:-zstd}
ZRAM_PERCENT=${ZRAM_PERCENT:-25}
ZRAM_PRIORITY=${ZRAM_PRIORITY:-100}
SWAPPINESS=${SWAPPINESS:-60}
VFS_CACHE_PRESSURE=${VFS_CACHE_PRESSURE:-50}

SYSCTL_FILE=/etc/sysctl.d/99-swap.conf
ZRAM_DEFAULTS=/etc/default/zramswap

die() { echo "provision-swap: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
command -v apt-get &>/dev/null || die "needs apt-get (Debian-family only)"
command -v systemctl &>/dev/null || die "needs systemd"

step "kernel modules"
# The virtual kernel flavour ships without the zram module, so zram-tools
# fails to start with a modprobe error until modules-extra is present. That
# package is versioned per kernel release, so pinning only the running
# version silently loses zram at the next kernel upgrade; the generic
# meta-package carries modules-extra forward across upgrades instead. There
# is no virtual-flavour equivalent of it.
apt-get update -qq
apt-get install -y -qq linux-generic
# linux-generic only takes effect on the kernel it pulls in, which needs a
# reboot. Install modules-extra for the running kernel too so zram works now.
running_extra="linux-modules-extra-$(uname -r)"
if apt-cache show "$running_extra" &>/dev/null; then
    apt-get install -y -qq "$running_extra"
else
    echo "no $running_extra available — zram may need a reboot to load"
fi
modprobe zram 2>/dev/null || echo "zram module not loadable until reboot"

step "zram swap tier"
apt-get install -y -qq zram-tools
cat >"$ZRAM_DEFAULTS" <<EOF
ALGO=$ZRAM_ALGO
PERCENT=$ZRAM_PERCENT
PRIORITY=$ZRAM_PRIORITY
EOF

step "swapfile tier"
if grep -qs "^${SWAPFILE//\//\\/}[[:space:]]" /proc/swaps; then
    echo "$SWAPFILE already active — leaving size alone"
elif [ -e "$SWAPFILE" ]; then
    echo "$SWAPFILE exists but is inactive — enabling as-is"
    chmod 600 "$SWAPFILE"
    swapon --priority "$SWAPFILE_PRIORITY" "$SWAPFILE"
else
    # fallocate leaves holes on some filesystems and the kernel refuses a
    # sparse swapfile, so verify and fall back to a written-through file.
    fallocate -l "$SWAPFILE_SIZE" "$SWAPFILE" 2>/dev/null || true
    if [ ! -s "$SWAPFILE" ]; then
        dd if=/dev/zero of="$SWAPFILE" bs=1M \
            count=$(( $(numfmt --from=iec "$SWAPFILE_SIZE") / 1048576 )) status=none
    fi
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    swapon --priority "$SWAPFILE_PRIORITY" "$SWAPFILE"
    echo "created $SWAPFILE ($SWAPFILE_SIZE)"
fi

fstab_line="$SWAPFILE none swap sw,pri=$SWAPFILE_PRIORITY 0 0"
if grep -qs "^${SWAPFILE//\//\\/}[[:space:]]" /etc/fstab; then
    echo "fstab entry already present"
else
    printf '%s\n' "$fstab_line" >>/etc/fstab
    echo "added fstab entry"
fi

step "memory tuning"
# Swappiness is deliberately high, not the usual low value: with zram as the
# primary tier a swap-out is a RAM-to-RAM compress, so the kernel should reach
# for it freely rather than evicting cache. Lowering cache pressure keeps
# dentry/inode cache alive across the large source trees this box builds.
cat >"$SYSCTL_FILE" <<EOF
vm.swappiness = $SWAPPINESS
vm.vfs_cache_pressure = $VFS_CACHE_PRESSURE
EOF
sysctl -q -p "$SYSCTL_FILE"

step "services"
# PSI-based kills take out the single runaway cgroup; the kernel OOM killer
# instead picks the largest process, which here is the IDE or a mid-flight
# agent rather than the thing actually leaking.
systemctl enable --now systemd-oomd
systemctl restart zramswap || echo "zramswap failed to start — check the zram module"

step "result"
swapon --show || echo "no swap active"
echo
echo "provision-swap: done"
