#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
src="$here/home/run_onchange_after_50-install-whisper-local.sh.tmpl"

rendered="$(chez_render "$(chez_init personal)" "$src")"
echo "$rendered" | shellcheck -s bash -

# Windows render must pin a version and verify the download checksum.
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
    echo "$rendered" | grep -qE 'VERSION="v[0-9]+\.[0-9]+\.[0-9]+"' || { echo "FAIL: no pinned version"; exit 1; }
    echo "$rendered" | grep -q 'sha256' || { echo "FAIL: no checksum verification"; exit 1; }
    echo "$rendered" | grep -q 'already installed' || { echo "FAIL: no idempotency guard"; exit 1; }
fi

# Non-Windows platforms must ignore the AppData tree entirely.
grep -q 'AppData' "$here/home/.chezmoiignore" || { echo "FAIL: AppData not ignored off-Windows"; exit 1; }
echo "PASS"
