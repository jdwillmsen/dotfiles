#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns here match literal shell text in the script under test
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-persistence.sh"
shellcheck -s bash "$script"

grep -q '\[ "\$(id -u)" = 0 \] ||' "$script" || { echo "FAIL: no root check"; exit 1; }
line_no=$(grep -n '\[ "\$(id -u)" = 0 \] ||' "$script" | head -1 | cut -d: -f1)
enable_line=$(grep -n '^\s*loginctl enable-linger' "$script" | head -1 | cut -d: -f1)
[ "$line_no" -lt "$enable_line" ] || { echo "FAIL: root check must run before enabling linger"; exit 1; }

grep -q 'SUDO_USER' "$script" || { echo "FAIL: no fallback to \$SUDO_USER for the target user"; exit 1; }
grep -q 'TARGET_USER' "$script" || { echo "FAIL: no TARGET_USER override"; exit 1; }
echo "PASS"
