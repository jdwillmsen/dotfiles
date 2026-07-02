#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
render() { chez_render "$(chez_init "$1")" "$here/home/dot_gitconfig.tmpl"; }
p="$(render personal)"
echo "$p" | grep -q "jdwillmsen@gmail.com" || { echo "FAIL: personal email"; exit 1; }
echo "$p" | grep -q "signingkey = 80F11F099D474F1F" || { echo "FAIL: signing key"; exit 1; }
echo "$p" | grep -q "helper = store" && { echo "FAIL: plaintext store helper still present"; exit 1; }
e="$(render ephemeral)"
echo "$e" | grep -q "gpgsign = false" || { echo "FAIL: ephemeral should disable signing"; exit 1; }
echo "PASS"
