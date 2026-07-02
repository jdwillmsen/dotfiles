#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# CI path: env key present → rendered config must point identity at a temp key file.
# Rendering the config template itself via stdin is the chezmoi-documented pattern
# for probing .chezmoi.toml.tmpl in isolation (execute-template --init skips [data]).
out="$(CHEZMOI_AGE_KEY='AGE-SECRET-KEY-TEST' RUNNER_TEMP="$(mktemp -d)" chezmoi execute-template --init \
    --promptString machineRole=ephemeral < "$here/home/.chezmoi.toml.tmpl")"
echo "$out" | grep -q 'chezmoi-age-key.txt' || { echo "FAIL: env key not wired to temp identity"; exit 1; }
# Placeholder recipient must be gone.
grep -q 'age1PLACEHOLDER' "$here/home/.chezmoi.toml.tmpl" && { echo "FAIL: placeholder recipient remains"; exit 1; }
echo "PASS"
