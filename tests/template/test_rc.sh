#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# dot_bashrc is a plain managed file (no template directives), so a direct
# read is byte-faithful to what chezmoi applies — no render step needed.
out="$(cat "$here/home/dot_bashrc")"
echo "$out" | grep -q '\.config/shell/aliases.sh' || { echo "FAIL: aliases not sourced"; exit 1; }
echo "$out" | grep -q 'SDKMAN_DIR' || { echo "FAIL: sdkman block missing"; exit 1; }
# local.sh must be the last entry of the source loop in both rc files so
# unmanaged machine-local definitions override the managed ones.
for rc in dot_bashrc dot_zshrc; do
    grep -q 'shell/local\.sh"; do' "$here/home/$rc" \
        || { echo "FAIL: local.sh not last in $rc source loop"; exit 1; }
done
echo "PASS"
