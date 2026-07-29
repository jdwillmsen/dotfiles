#!/usr/bin/env bash
set -euo pipefail
# Package ids diverge per manager (delta is "git-delta" on brew and cargo, "delta"
# on scoop), so each tool carries its own row rather than assuming one name.
# Fields: command|brew|winget|scoop|cargo — empty field means that manager is skipped.
TOOLS='
delta|git-delta|dandavison.delta|delta|git-delta
fd|fd|sharkdp.fd|fd|fd-find
eza|eza|eza-community.eza|eza|eza
zoxide|zoxide|ajeetdsouza.zoxide|zoxide|zoxide
starship|starship|Starship.Starship|starship|starship
'

install_one() {
    local cmd=$1 brew_id=$2 winget_id=$3 scoop_id=$4 cargo_id=$5
    if command -v "$cmd" &>/dev/null; then
        echo "$cmd already installed — skipping"; return 0
    fi
    # Prebuilt-binary managers first; cargo compiles from source and is the fallback.
    if [ -n "$brew_id" ] && command -v brew &>/dev/null; then
        brew install "$brew_id" || echo "$cmd brew install failed"
    elif [ -n "$winget_id" ] && command -v winget &>/dev/null; then
        # An MSI-based tool (starship) lands outside this shell's inherited PATH,
        # so command -v misses it and winget then exits non-zero with "no upgrade
        # found" — reported as a failure when nothing is wrong. Ask winget first.
        if winget list --id "$winget_id" --exact &>/dev/null; then
            echo "$cmd already installed — restart your shell to pick it up on PATH"
        else
            winget install --id "$winget_id" --silent \
                --accept-package-agreements --accept-source-agreements ||
                echo "$cmd winget install failed"
        fi
    elif [ -n "$scoop_id" ] && command -v scoop &>/dev/null; then
        scoop install "$scoop_id" || echo "$cmd scoop install failed"
    elif [ -n "$cargo_id" ] && command -v cargo &>/dev/null; then
        cargo install "$cargo_id" || echo "$cmd cargo install failed"
    else
        echo "$cmd requires brew, winget, scoop, or cargo — install one first"
    fi
}

# A single tool failing must not abort the rest, so install_one never returns
# non-zero and the loop runs to completion under `set -e`.
while IFS='|' read -r cmd brew_id winget_id scoop_id cargo_id; do
    [ -n "$cmd" ] || continue
    install_one "$cmd" "$brew_id" "$winget_id" "$scoop_id" "$cargo_id"
done <<< "$TOOLS"

echo "CLI tool provisioning complete"
