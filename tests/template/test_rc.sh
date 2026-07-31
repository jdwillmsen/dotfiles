#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# dot_bashrc is a plain managed file (no template directives), so a direct
# read is byte-faithful to what chezmoi applies — no render step needed.
out="$(cat "$here/home/dot_bashrc")"
echo "$out" | grep -q '\.config/shell/aliases.sh' || { echo "FAIL: aliases not sourced"; exit 1; }
echo "$out" | grep -q 'SDKMAN_DIR' || { echo "FAIL: sdkman block missing"; exit 1; }
# Elevated shells inherit System32 as cwd, where starship's per-prompt scan
# times out and drops the detection-gated modules. The guard must also precede
# the zoxide block, which caches pwd at load time.
# shellcheck disable=SC2016  # matching the literal, unexpanded rc line
echo "$out" | grep -qF '/?/windows/system32) cd "$HOME"' \
    || { echo "FAIL: System32 cwd guard missing in dot_bashrc"; exit 1; }
[ "$(grep -n 'windows/system32' "$here/home/dot_bashrc" | cut -d: -f1)" \
    -lt "$(grep -n 'zoxide init bash' "$here/home/dot_bashrc" | cut -d: -f1)" ] \
    || { echo "FAIL: System32 cwd guard must come before zoxide init"; exit 1; }
# local.sh must be the last entry of the source loop in both rc files so
# unmanaged machine-local definitions override the managed ones.
for rc in dot_bashrc dot_zshrc; do
    grep -q 'shell/local\.sh"; do' "$here/home/$rc" \
        || { echo "FAIL: local.sh not last in $rc source loop"; exit 1; }
    # zoxide 0.10.0 ships a Windows init whose __zoxide_pwd lost its command
    # substitution; both rc files must redefine it or every cd errors.
    # shellcheck disable=SC2016  # matching the literal, unexpanded rc line
    grep -q '__zoxide_pwd() { \\command cygpath -w "\$(\\builtin pwd -L)"; }' "$here/home/$rc" \
        || { echo "FAIL: zoxide cygpath pwd override missing in $rc"; exit 1; }
done
echo "PASS"
