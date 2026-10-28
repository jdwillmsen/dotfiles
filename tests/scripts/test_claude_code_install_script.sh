#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/run_once_before_29-install-claude-code.sh"
shellcheck -s bash "$script"

# Runs the real script on a sealed PATH of stubs that log what they were asked
# to do, with uname pinned to Linux so the Windows PATH branch never touches
# the registry of the machine running the test.
run_case() {
    local home=$1 stubs=$2
    HOME="$home" PATH="$stubs:/usr/bin:/bin" bash "$script"
}
new_case() {
    local d
    d="$(mktemp -d)"
    mkdir -p "$d/home" "$d/stubs"
    printf '#!/bin/sh\necho Linux\n' > "$d/stubs/uname"
    printf '#!/bin/sh\necho "curl $*" >> "%s/log"\necho "echo installer-ran >> %s/log"\n' "$d" "$d" > "$d/stubs/curl"
    chmod 755 "$d/stubs/uname" "$d/stubs/curl"
    : > "$d/log"
    printf '%s' "$d"
}
fail() { echo "FAIL: $1"; exit 1; }

# A native build present means nothing is installed or migrated.
d="$(new_case)"
mkdir -p "$d/home/.local/bin"
printf '#!/bin/sh\necho "claude $*" >> "%s/log"\n' "$d" > "$d/home/.local/bin/claude"
chmod 755 "$d/home/.local/bin/claude"
run_case "$d/home" "$d/stubs" >/dev/null
[ ! -s "$d/log" ] || fail "native build present, but the script still ran: $(cat "$d/log")"
rm -rf "$d"

# A package-manager install is migrated with `claude install`, not reinstalled.
d="$(new_case)"
printf '#!/bin/sh\necho "claude $*" >> "%s/log"\n' "$d" > "$d/stubs/claude"
chmod 755 "$d/stubs/claude"
run_case "$d/home" "$d/stubs" >/dev/null
grep -qx 'claude install' "$d/log" || fail "package-managed claude was not migrated"
grep -q '^curl' "$d/log" && fail "package-managed claude also ran the vendor installer"
rm -rf "$d"

# No claude at all runs the vendor installer.
d="$(new_case)"
run_case "$d/home" "$d/stubs" >/dev/null
grep -q 'curl -fsSL https://claude.ai/install.sh' "$d/log" || fail "vendor installer not fetched"
grep -qx 'installer-ran' "$d/log" || fail "fetched installer was not executed"
rm -rf "$d"

echo "PASS"
