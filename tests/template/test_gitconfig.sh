#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
chez_require_key
render() { chez_render "$(chez_init "$1")" "$here/home/dot_gitconfig.tmpl"; }
p="$(render personal)"
# noreply, not the real address: this is the base layer, applying to any repo no
# machine-local includeIf claims. A real address in public history is permanent.
echo "$p" | grep -q "42048994+jdwillmsen@users.noreply.github.com" || { echo "FAIL: personal email"; exit 1; }
echo "$p" | grep -q "jdwillmsen@gmail.com" && { echo "FAIL: real address must not be a template default"; exit 1; }
echo "$p" | grep -q "signingkey = 949C342C7907CC24" || { echo "FAIL: signing key"; exit 1; }
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
echo "$w" | grep -q "42048994+jdwillmsen@users.noreply.github.com" || { echo "FAIL: work role should fall back to default email for blank work-identity"; exit 1; }

# delta config is gated on the binary resolving at apply time — naming a pager
# that is not on PATH breaks every paging command. Assert whichever branch this
# machine is actually in, so both are covered across CI and dev machines.
if command -v delta &>/dev/null; then
    echo "$p" | grep -q "pager = delta" || { echo "FAIL: delta present but pager not configured"; exit 1; }
    echo "$p" | grep -q "diffFilter = delta --color-only" || { echo "FAIL: delta diffFilter missing"; exit 1; }
else
    echo "$p" | grep -q "delta" && { echo "FAIL: delta config emitted without the binary"; exit 1; }
fi
echo "PASS"
