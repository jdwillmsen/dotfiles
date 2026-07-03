#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
chez_require_key
render() { chez_render "$(chez_init "$1")" "$here/home/dot_gitconfig.tmpl"; }
p="$(render personal)"
echo "$p" | grep -q "jdwillmsen@gmail.com" || { echo "FAIL: personal email"; exit 1; }
echo "$p" | grep -q "signingkey = 80F11F099D474F1F" || { echo "FAIL: signing key"; exit 1; }
echo "$p" | grep -q "helper = store" && { echo "FAIL: plaintext store helper still present"; exit 1; }
e="$(render ephemeral)"
echo "$e" | grep -q "gpgsign = false" || { echo "FAIL: ephemeral should disable signing"; exit 1; }

# [include] of ~/.gitconfig.local must render as the LAST section: git lets
# later values override earlier ones, so machine-local only wins from the end.
last_section="$(echo "$p" | grep -oE '^\[[a-z]+\]' | tail -1)"
[ "$last_section" = "[include]" ] || { echo "FAIL: [include] not last section (got $last_section)"; exit 1; }
echo "$p" | grep -q 'path = ~/.gitconfig.local' || { echo "FAIL: gitconfig.local include missing"; exit 1; }

# role=work reads the encrypted work-identity slot, which only exists as a
# destination file after a real apply (run_before writes the CI/local age
# identity, then chezmoi decrypts) — probe via chez_apply, not chez_render.
dest="$(mktemp -d)"
chez_apply "$(chez_init work)" "$dest" >/dev/null
w="$(grep -A2 '\[user\]' "$dest/.gitconfig")"
echo "$w" | grep -q "jdwillmsen@gmail.com" || { echo "FAIL: work role should fall back to default email for blank work-identity"; exit 1; }
echo "PASS"
