#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
shellcheck -s bash "$here/home/run_once_40-install-rtk.sh"
grep -q 'command -v rtk' "$here/home/run_once_40-install-rtk.sh" || { echo "FAIL: no idempotency guard"; exit 1; }
echo "PASS"
