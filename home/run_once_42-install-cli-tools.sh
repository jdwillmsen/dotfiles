#!/usr/bin/env bash
set -euo pipefail
# Package ids diverge per manager (delta is "git-delta" on brew, apt and cargo,
# "delta" on scoop), so each tool carries its own row rather than assuming one name.
# Fields: command|brew|winget|scoop|apt|cargo — empty field means that manager is skipped.
# An apt id may be written pkg>binary when the Debian package installs the tool
# under a different binary name than upstream (fd ships as fdfind).
TOOLS='
delta|git-delta|dandavison.delta|delta|git-delta|git-delta
fd|fd|sharkdp.fd|fd|fd-find>fdfind|fd-find
eza|eza|eza-community.eza|eza|eza|eza
zoxide|zoxide|ajeetdsouza.zoxide|zoxide|zoxide|zoxide
starship|starship|Starship.Starship|starship||starship
fzf|fzf|junegunn.fzf|fzf|fzf|
direnv|direnv|direnv.direnv|direnv|direnv|
nvim|neovim|Neovim.Neovim|neovim|neovim|
'

# apt is the only manager here that needs root. `chezmoi apply` runs unattended
# (CI, devcontainers, bootstrap), so a password prompt would hang it — require
# a non-interactive sudo and fall through to the next manager otherwise.
apt_install() {
    local cmd=$1 spec=$2
    local pkg=${spec%%>*} altbin=${spec#*>}
    DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y -qq "$pkg" || {
        echo "$cmd apt install failed"; return 0
    }
    # Shim the Debian binary name onto the upstream one, or the next apply sees
    # the tool as still missing and reinstalls it every time. Resolve the target
    # first: an unresolvable name would hand ln an empty operand, and its failure
    # under `set -e` takes down every tool still queued behind this one.
    if [ "$altbin" != "$spec" ] && ! command -v "$cmd" &>/dev/null; then
        local target
        target="$(command -v "$altbin" || true)"
        if [ -z "$target" ]; then
            echo "$cmd installed as $altbin but $altbin is not on PATH — no shim"; return 0
        fi
        mkdir -p "$HOME/.local/bin"
        ln -sf "$target" "$HOME/.local/bin/$cmd"
    fi
}

install_one() {
    local cmd=$1 brew_id=$2 winget_id=$3 scoop_id=$4 apt_id=$5 cargo_id=$6
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
    elif [ -n "$apt_id" ] && command -v apt-get &>/dev/null && sudo -n true 2>/dev/null; then
        apt_install "$cmd" "$apt_id"
    elif [ -n "$cargo_id" ] && command -v cargo &>/dev/null; then
        cargo install "$cargo_id" || echo "$cmd cargo install failed"
    else
        echo "$cmd requires brew, winget, scoop, passwordless-sudo apt, or cargo — install one first"
    fi
}

# A single tool failing must not abort the rest, so install_one never returns
# non-zero and the loop runs to completion under `set -e`.
while IFS='|' read -r cmd brew_id winget_id scoop_id apt_id cargo_id; do
    [ -n "$cmd" ] || continue
    install_one "$cmd" "$brew_id" "$winget_id" "$scoop_id" "$apt_id" "$cargo_id"
done <<< "$TOOLS"

echo "CLI tool provisioning complete"
