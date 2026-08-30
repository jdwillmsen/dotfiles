#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/run_before_00-write-ci-age-key.sh"
shellcheck -s bash "$script"

fail() { echo "FAIL: $1"; exit 1; }

# The key path must match .chezmoi.toml.tmpl's [age].identity, which
# tests/template/test_age_key_source.sh pins to the same basename.
tmp="$(mktemp -d)"
key='AGE-SECRET-KEY-1TESTONLYNOTAREALIDENTITY'
CHEZMOI_AGE_KEY="$key" RUNNER_TEMP="$tmp" bash "$script"
written="$tmp/chezmoi-age-key.txt"
[ -f "$written" ] || fail "no key file written when CHEZMOI_AGE_KEY is set"

# A trailing newline makes age reject the identity, so the write must be byte-exact.
[ "$(wc -c <"$written")" = "${#key}" ] || fail "key file is not byte-exact (stray newline?)"
[ "$(cat "$written")" = "$key" ] || fail "key file contents do not match CHEZMOI_AGE_KEY"

# Locally the on-disk identity is used instead, so an unset env key must leave
# no file behind rather than truncating one.
empty="$(mktemp -d)"
env -u CHEZMOI_AGE_KEY RUNNER_TEMP="$empty" bash "$script"
[ -e "$empty/chezmoi-age-key.txt" ] && fail "key file written despite CHEZMOI_AGE_KEY being unset"

rm -rf "$tmp" "$empty"
echo "PASS"
