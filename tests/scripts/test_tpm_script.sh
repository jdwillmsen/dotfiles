#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
shellcheck -s bash "$here/home/run_once_10-install-tpm.sh"
grep -q 'command -v tmux' "$here/home/run_once_10-install-tpm.sh" || { echo "FAIL: no tmux guard"; exit 1; }
echo "PASS"
