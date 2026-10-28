#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/run_before_29-install-claude-code.sh"
shellcheck -s bash "$script"
fail() { echo "FAIL: $1"; exit 1; }

# Runs the real script on a PATH of nothing but stubs that log what they were
# asked to do, so a real claude or curl on the host can never be reached, with
# uname pinned to Linux so the Windows branch never touches a real registry.
run_case() {
    local d=$1
    HOME="$d/home" PATH="$d/stubs" "$BASH" "$script"
}
new_case() {
    local d
    d="$(mktemp -d)"
    mkdir -p "$d/home" "$d/stubs"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$BASH" > "$d/stubs/bash"
    printf '#!/bin/sh\necho Linux\n' > "$d/stubs/uname"
    printf '#!/bin/sh\necho "curl $*" >> "%s/log"\necho "echo installer-ran >> %s/log"\n' "$d" "$d" > "$d/stubs/curl"
    chmod 755 "$d/stubs/bash" "$d/stubs/uname" "$d/stubs/curl"
    : > "$d/log"
    printf '%s' "$d"
}
fake_claude() {
    printf '#!/bin/sh\necho "claude $*" >> "%s/log"\n' "$1" > "$2"
    chmod 755 "$2"
}

# A native build present means nothing is installed or migrated.
d="$(new_case)"
mkdir -p "$d/home/.local/bin"
fake_claude "$d" "$d/home/.local/bin/claude"
run_case "$d" >/dev/null
[ ! -s "$d/log" ] || fail "native build present, but the script still ran: $(cat "$d/log")"
rm -rf "$d"

# A package-manager install is migrated with `claude install`, not reinstalled.
d="$(new_case)"
fake_claude "$d" "$d/stubs/claude"
run_case "$d" >/dev/null
grep -qx 'claude install' "$d/log" || fail "package-managed claude was not migrated"
grep -q '^curl' "$d/log" && fail "package-managed claude also ran the vendor installer"
rm -rf "$d"

# No claude at all runs the vendor installer.
d="$(new_case)"
run_case "$d" >/dev/null
grep -q 'curl -fsSL https://claude.ai/install.sh' "$d/log" || fail "vendor installer not fetched"
grep -qx 'installer-ran' "$d/log" || fail "fetched installer was not executed"
rm -rf "$d"

# The registry PATH logic is the riskiest part and only runs on Windows, so it
# is checked here wherever PowerShell exists: the whole block must parse, and
# the merge must normalise, de-duplicate and reorder without touching the rest.
ps_bin="$(command -v pwsh || command -v powershell || true)"
if [ -z "$ps_bin" ]; then
    echo "SKIP: no PowerShell, registry PATH logic not exercised"
    echo "PASS"
    exit 0
fi
ps_src="$(sed -n "/<<'PS'/,/^PS\$/p" "$script" | sed '1d;$d')"
merge_fn="$(sed -n '/^function Merge-UserPath/,/^}/p' <<<"$ps_src")"
[ -n "$merge_fn" ] || fail "Merge-UserPath not found in the script's PowerShell block"

# shellcheck disable=SC2016  # the $ belong to PowerShell, not bash
PS_SRC="$ps_src" "$ps_bin" -NoProfile -Command '
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($env:PS_SRC, [ref]$null, [ref]$errs)
if ($errs.Count) { $errs | ForEach-Object { $_.Message }; exit 1 }' ||
    fail "the script's PowerShell block does not parse"

# Each row: existing PATH | expected result, where <none> means "no write".
dir='C:\U\me\.local\bin'
cases=(
    "|$dir"
    "C:\\a;C:\\b|$dir;C:\\a;C:\\b"
    "$dir;C:\\a|<none>"
    "c:\\u\\ME\\.local\\bin\\;C:\\a|<none>"
    "%TESTPROFILE%\\.local\\bin;C:\\a|<none>"
    "C:\\Users\\me\\AppData\\Local\\Microsoft\\WinGet\\Links;$dir|$dir;C:\\Users\\me\\AppData\\Local\\Microsoft\\WinGet\\Links"
    "%LOCALAPPDATA%\\x;;$dir\\;C:\\a;|$dir;%LOCALAPPDATA%\\x;C:\\a"
)
for c in "${cases[@]}"; do
    have="${c%%|*}" want="${c#*|}"
    # shellcheck disable=SC2016  # the $ belong to PowerShell, not bash
    got="$(TESTPROFILE='C:\U\me' FN="$merge_fn" HAVE="$have" DIR="$dir" "$ps_bin" -NoProfile -Command '
. ([scriptblock]::Create($env:FN))
$r = Merge-UserPath $env:HAVE $env:DIR
if ($null -eq $r) { "<none>" } else { $r }' | tr -d '\r')"
    [ "$got" = "$want" ] || fail "Merge-UserPath '$have': want '$want', got '$got'"
done

echo "PASS"
