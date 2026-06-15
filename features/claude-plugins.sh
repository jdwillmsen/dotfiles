#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require git
require claude

# ── Caveman ──────────────────────────────────────────────────────────────────
# Ultra-compressed output mode (~75% fewer tokens, full technical accuracy).
# Installed as a native Claude Code plugin; the plugin ships its own hooks, so
# no manual settings.json wiring is needed. Activate with /caveman, deactivate
# with /uncaveman.
MARKETPLACE_URL="https://github.com/JuliusBrussee/caveman"

if claude plugin marketplace list 2>/dev/null | grep -qw caveman; then
    skip "Caveman marketplace already added"
else
    info "Adding caveman marketplace..."
    claude plugin marketplace add "$MARKETPLACE_URL" \
        || { warn "Could not add caveman marketplace — skipping"; exit 0; }
    success "Caveman marketplace added"
fi

if claude plugin list 2>/dev/null | grep -q 'caveman@caveman'; then
    skip "Caveman plugin already installed"
else
    info "Installing caveman plugin..."
    claude plugin install caveman@caveman --scope user \
        || { warn "Could not install caveman plugin — skipping"; exit 0; }
    success "Caveman plugin installed"
fi
