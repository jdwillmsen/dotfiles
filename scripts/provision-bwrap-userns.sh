#!/usr/bin/env bash
set -euo pipefail
# Lets bubblewrap create user namespaces, which is what Codex needs to sandbox
# its own tool calls.
#
# Ubuntu 24.04 restricts unprivileged user namespaces through AppArmor
# (kernel.apparmor_restrict_unprivileged_userns=1), so an unconfined bwrap
# fails at `setting up uid map: Permission denied` and Codex falls back to
# running tool calls against the real filesystem. The fix is a profile naming
# the binary and granting `userns` to it alone — the same shape Ubuntu ships
# for 1password, podman and buildah — rather than clearing the sysctl, which
# would return the capability to every unprivileged process on the machine.
#
# The profile is `flags=(unconfined)`: it confines nothing and exists only to
# give bwrap a label that may create namespaces. That is Ubuntu's own pattern
# and worth stating plainly, because a file under /etc/apparmor.d reads like a
# confinement and this one is not.
#
# Not a chezmoi run_ script: writing under /etc and reloading AppArmor need
# root, and `chezmoi apply` runs unattended where a sudo prompt would hang it.
#
#   sudo scripts/provision-bwrap-userns.sh
#
# Idempotent — re-running with the profile already in place reloads and exits.

BWRAP=${BWRAP:-/usr/bin/bwrap}
PROFILE=${PROFILE:-/etc/apparmor.d/bwrap}

die() { echo "provision-bwrap-userns: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" = 0 ] || die "must run as root — try: sudo $0"
[ -x "$BWRAP" ] || die "no bubblewrap at $BWRAP — chezmoi apply installs it (see docs/provisioning.md)"
command -v apparmor_parser &>/dev/null || die "needs apparmor_parser"

# Nothing to do on a kernel that does not restrict this in the first place: the
# profile would be inert and the reload pure noise.
restricted="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
if [ "$restricted" != 1 ]; then
    echo "provision-bwrap-userns: kernel does not restrict unprivileged userns — nothing to do"
    exit 0
fi

desired=$(
    cat <<EOF
# Managed by scripts/provision-bwrap-userns.sh — see docs/provisioning.md.
# Confines nothing. It exists so bubblewrap has a label permitted to create
# user namespaces, instead of being denied as unconfined.
abi <abi/4.0>,
include <tunables/global>

profile bwrap $BWRAP flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
EOF
)

step "Writing $PROFILE"
if [ -f "$PROFILE" ] && [ "$(cat "$PROFILE")" = "$desired" ]; then
    echo "already current"
else
    printf '%s\n' "$desired" >"$PROFILE"
    echo "written"
fi

step "Loading the profile"
apparmor_parser -r -W "$PROFILE" || die "apparmor_parser rejected $PROFILE"

# Proving it through the real consumer, not by trusting the reload: the sysctl
# is enforced at namespace creation, so only an actual unshare says whether the
# profile took.
step "Verifying"
if runuser -u "${SUDO_USER:-nobody}" -- "$BWRAP" --unshare-user --dev-bind / / true 2>/dev/null; then
    echo "bubblewrap can create user namespaces"
else
    die "bwrap still cannot unshare a user namespace — check 'dmesg | grep apparmor'"
fi
