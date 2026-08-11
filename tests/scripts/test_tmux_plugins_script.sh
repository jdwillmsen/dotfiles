#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/run_onchange_11-install-tmux-plugins.sh.tmpl"
shellcheck -s bash "$script"

grep -q 'command -v tmux' "$script" || { echo "FAIL: no tmux guard"; exit 1; }
grep -q 'include "dot_tmux.conf" | sha256sum' "$script" || { echo "FAIL: not keyed to dot_tmux.conf changes"; exit 1; }
grep -q "tmux-resurrect" "$here/home/dot_tmux.conf" || { echo "FAIL: tmux-resurrect not declared"; exit 1; }
grep -q "tmux-continuum" "$here/home/dot_tmux.conf" || { echo "FAIL: tmux-continuum not declared"; exit 1; }
grep -q "@continuum-restore 'on'" "$here/home/dot_tmux.conf" || { echo "FAIL: continuum auto-restore not enabled"; exit 1; }
echo "PASS"
