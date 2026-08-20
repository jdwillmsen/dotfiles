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

# The dev tooling catalog installs a Docker daemon and a cluster CLI, so it is
# opt-in per machine: off unless the prompt was answered true.
for s in run_once_49-install-dev-tools.sh.tmpl; do
    grep -qx -- "$s" <<<"$out" || fail "$s must be off unless opted in"
done
on="$(
    unset CI
    chez_render "$(chez_init personal true)" "$here/home/.chezmoiignore"
)"
grep -qx -- 'run_once_49-install-dev-tools.sh.tmpl' <<<"$on" &&
    fail "opting in must actually enable the dev tooling catalog"

# A machine initialised before this prompt existed has no such key in its
# persisted config. The rule reads it with `get` for exactly that reason: a
# bare reference is a hard template error there, which would break every apply
# on every older machine rather than leaving the catalog off.
legacy="$(mktemp -d)/chezmoi.toml"
grep -v installDevTooling "$cfg" > "$legacy"
out="$(
    unset CI
    chez_render "$legacy" "$here/home/.chezmoiignore"
)" || fail "ignore rules must render on a config predating the prompt"
grep -qx -- 'run_once_49-install-dev-tools.sh.tmpl' <<<"$out" ||
    fail "a config without the key must leave the catalog off"

# The script's own guard reads the value the same defensive way, for the same
# reason: it is the guard that actually stops the install (see tests/scripts/
# test_toolchain_scripts.sh), not the ignore rule above, so it has to survive
# a legacy config too rather than hard-erroring the whole apply.
script_out="$(
    chez_render "$legacy" "$here/home/run_once_49-install-dev-tools.sh.tmpl"
)" || fail "dev tooling script must render on a config predating the prompt"
echo "$script_out" | grep -q 'installDevTooling is off — skipping' ||
    fail "a config without the key must leave the dev tooling script off"

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
