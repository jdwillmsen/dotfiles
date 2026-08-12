#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"

fail() {
    echo "FAIL: $1"
    exit 1
}
cfg="$(chez_init personal)"
render() { chez_render "$cfg" "$here/home/.chezmoiignore"; }

# The download-heavy installers must be *ignored* under CI, not merely
# self-skipped: chezmoi records a run_once script as executed whenever it exits
# 0, and a script that exits 0 to say "CI detected — skipping" is recorded just
# the same. A machine that ever applied with CI set would then never install
# the toolchain again. Ignoring them leaves no state behind to block a later
# real apply.
out="$(
    export CI=1
    render
)"
for s in run_once_46-install-cloud-clis.sh run_once_47-install-go.sh; do
    grep -qx -- "$s" <<<"$out" || fail "$s is not ignored under CI"
done

out="$(
    unset CI
    render
)"
for s in run_once_46-install-cloud-clis.sh run_once_47-install-go.sh; do
    grep -qx -- "$s" <<<"$out" && fail "$s must still run on a real machine"
done

# The ephemeral rules are independent of CI and must not have been folded in.
eph="$(chez_init ephemeral)"
out="$(
    unset CI
    chez_render "$eph" "$here/home/.chezmoiignore"
)"
grep -qx -- 'run_once_46-install-cloud-clis.sh' <<<"$out" ||
    fail "ephemeral machines must still skip the cloud CLI install"
grep -qx -- 'run_once_47-install-go.sh' <<<"$out" &&
    fail "ephemeral machines still render a statusline and need Go"

echo "PASS"
