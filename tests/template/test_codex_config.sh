#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
existing='[tui]
status_line = ["old"]

[other]
x = 1'
# Plain modify script (no template directives) — run directly, stdin = current file.
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_codex/modify_config.toml.toml")"
echo "$out" | grep -q 'model-with-reasoning' || { echo "FAIL: status_line not set"; exit 1; }
echo "$out" | grep -q '\[other\]' || { echo "FAIL: other section lost"; exit 1; }
echo "$out" | grep -c 'status_line' | grep -qx 1 || { echo "FAIL: duplicate status_line"; exit 1; }
# Idempotency: piping the output back through the script must be byte-identical.
out2="$(printf '%s' "$out" | bash "$here/home/private_dot_codex/modify_config.toml.toml")"
[ "$out" = "$out2" ] || { echo "FAIL: not idempotent"; exit 1; }
echo "PASS"
