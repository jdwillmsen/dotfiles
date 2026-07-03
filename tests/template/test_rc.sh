#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# dot_bashrc is a plain managed file (no template directives), so a direct
# read is byte-faithful to what chezmoi applies — no render step needed.
out="$(cat "$here/home/dot_bashrc")"
echo "$out" | grep -q '\.config/shell/aliases.sh' || { echo "FAIL: aliases not sourced"; exit 1; }
echo "$out" | grep -q 'SDKMAN_DIR' || { echo "FAIL: sdkman block missing"; exit 1; }
echo "PASS"
