#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/run_once_44-install-nerd-font.sh"
shellcheck -s bash "$script"
grep -q 'font_present' "$script" || { echo "FAIL: no idempotency guard"; exit 1; }
# winget's MSI registers the family as "JetBrainsMono NF" while the upstream
# Nerd Fonts archives use "JetBrainsMono Nerd Font"; a check that accepts only
# one spelling reinstalls the font on every machine served by the other.
grep -q 'NF|Nerd Font' "$script" || { echo "FAIL: guard must accept both family spellings"; exit 1; }
echo "PASS"
