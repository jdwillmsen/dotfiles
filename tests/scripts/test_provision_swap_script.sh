#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns here match literal shell text in the script under test
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-swap.sh"
shellcheck -s bash "$script"

fail() { echo "FAIL: $1"; exit 1; }

[ -x "$script" ] || fail "provision-swap.sh must be executable"
grep -q 'id -u' "$script" || fail "no root guard"

# The whole point of the kernel step: pinning modules-extra to the running
# release loses zram at the next kernel upgrade, so the generic meta-package
# must be installed, not just the versioned module package.
grep -q 'apt-get install -y -qq linux-generic' "$script" || fail "linux-generic not installed"
grep -q 'linux-modules-extra-\$(uname -r)' "$script" || fail "running-kernel modules-extra not installed"

# zram must outrank the disk file, or the swapfile absorbs pressure first and
# the compressed tier never gets used.
zram_pri="$(sed -n 's/^ZRAM_PRIORITY=${ZRAM_PRIORITY:-\([0-9]*\)}$/\1/p' "$script")"
file_pri="$(sed -n 's/^SWAPFILE_PRIORITY=${SWAPFILE_PRIORITY:-\([0-9]*\)}$/\1/p' "$script")"
# shellcheck disable=SC2015  # either value being empty is the same failure; the || is the else
[ -n "$zram_pri" ] && [ -n "$file_pri" ] || fail "swap priorities not parseable"
[ "$zram_pri" -gt "$file_pri" ] || fail "zram priority ($zram_pri) must exceed swapfile ($file_pri)"

# Swapping to zram is a RAM-to-RAM compress, so the tuning is deliberately
# swap-happy; a conservative value here would mean the tier is provisioned
# and then never reached.
swappiness="$(sed -n 's/^SWAPPINESS=${SWAPPINESS:-\([0-9]*\)}$/\1/p' "$script")"
[ "$swappiness" -ge 60 ] || fail "swappiness ($swappiness) too low for a zram-primary setup"

# Re-runs are the normal case (kernel upgrades, partial first runs), so every
# mutation needs a guard.
grep -q '/proc/swaps' "$script" || fail "no active-swap guard before creating the swapfile"
grep -q '/etc/fstab' "$script" || fail "fstab entry not persisted"
grep -c 'grep -qs' "$script" | grep -qv '^0$' || fail "no idempotency guards"

grep -q 'systemctl enable --now systemd-oomd' "$script" || fail "systemd-oomd not enabled"

# A trailing `cond && echo` aborts the whole script under `set -e` whenever the
# condition is false, silently skipping every later step.
grep -qE '^[[:space:]]*(command -v|\[ -n).*&&$' "$script" &&
    fail "trailing '&&' continuation aborts under set -e"

echo "PASS"
