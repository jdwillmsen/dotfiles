#!/usr/bin/env bash
set -euo pipefail
# Dev/infra tooling for a full development machine — the layer above the
# editor-adjacent CLIs in 42. Opt-in: a personal laptop should not sprout a
# Docker daemon and a kubectl because it applied dotfiles, so the whole script
# is gated on the installDevTooling prompt via home/.chezmoiignore.
#
# Data-driven the same way 42 is: adding a tool is a table row, not new logic.
# Rows carry an install kind because these tools do not share one distribution
# channel the way 42's do — some ship a distro package, some a signed vendor
# apt repo, some only a curl-pipe installer or a bare release asset.
#
# Fields: command|kind|guard|package|url|extra|version
#
#   command   binary that proves the tool is present (the default guard)
#   kind      apt | apt-repo | script | binary, optionally suffixed `+root`
#             for an installer that elevates internally (docker, helm) — the
#             suffix keeps that fact in the row rather than as a tool name
#             hardcoded in the dispatcher
#   guard     optional $HOME-relative path checked instead of `command -v`,
#             for tools whose binary is not on an unattended apply's PATH
#   package   apt: package id, `pkg>binary` when Debian renames the binary
#             apt-repo: package id
#             script: arguments passed to the installer
#   url       apt-repo: signing key
#             script: installer
#             binary: release asset, %v substituted with version
#   extra     apt-repo: apt source spec, minus the [options] block
#             script: shell run after the installer
#             binary: checksum file, %v substituted with version
#   version   binary: the pinned release
#
# Go is deliberately absent: 47 already owns it, from the upstream tarball
# rather than a distro package, because go.mod pins a toolchain the statusline
# build needs and distro packages trail it by a release or more.
# shellcheck disable=SC2016  # post-install snippets expand at eval time, not here
TOOLS='
docker|script+root|||https://get.docker.com|sudo -n usermod -aG docker "$(id -un)"|
node|script|.nvm/versions/node||https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh|export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; nvm install --lts; corepack enable; corepack prepare pnpm@latest --activate|
cargo|script||-y --no-modify-path|https://sh.rustup.rs||
helm|script+root|||https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3||
gh|apt-repo||gh|https://cli.github.com/packages/githubcli-archive-keyring.gpg|https://cli.github.com/packages stable main|
kubectl|apt-repo||kubectl|https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key|https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /|
talosctl|binary|||https://github.com/siderolabs/talos/releases/download/%v/talosctl-linux-amd64|https://github.com/siderolabs/talos/releases/download/%v/sha256sum.txt|v1.13.8
sops|binary|||https://github.com/getsops/sops/releases/download/%v/sops-%v.linux.amd64|https://github.com/getsops/sops/releases/download/%v/sops-%v.checksums.txt|v3.10.2
age|apt||age|||
java|apt||openjdk-21-jdk|||
'

BIN="$HOME/.local/bin"

# Vendor archives and a Docker daemon are dead weight in a CI container, and the
# smoke test applies with a real machine role into a throwaway HOME. The ignore
# rule in .chezmoiignore is the real gate; this guard covers a direct run.
[ -z "${CI:-}" ] || { echo "CI detected — skipping dev tooling install"; exit 0; }

# Linux/apt only for v1. The vendor installers below assume a Debian userland,
# and 42 already covers the brew/winget/scoop machines for its own tools.
if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo "dev tooling catalog is linux/amd64 only — skipping"; exit 0
fi

# apt, the vendor repos, and the two vendor installers that write outside $HOME
# all need root. `chezmoi apply` runs unattended, so a password prompt would
# hang it rather than fail it — require sudo to already be password-free.
have_root() { command -v sudo &>/dev/null && sudo -n true 2>/dev/null; }

APT_REFRESHED=0
apt_refresh() {
    [ "$APT_REFRESHED" = 0 ] || return 0
    DEBIAN_FRONTEND=noninteractive sudo -n apt-get update -qq || return 1
    APT_REFRESHED=1
}

install_apt() {
    local cmd=$1 spec=$2
    local pkg=${spec%%>*} altbin=${spec#*>}
    apt_refresh || { echo "$cmd: apt update failed"; return 0; }
    DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y -qq "$pkg" || {
        echo "$cmd apt install failed"; return 0
    }
    # Same shim 42 carries: without it the next apply sees the tool as missing
    # and reinstalls it. Resolve the target first — an unresolvable name would
    # hand ln an empty operand and abort every tool queued behind this one.
    if [ "$altbin" != "$spec" ] && ! command -v "$cmd" &>/dev/null; then
        local target
        target="$(command -v "$altbin" || true)"
        if [ -z "$target" ]; then
            echo "$cmd installed as $altbin but $altbin is not on PATH — no shim"; return 0
        fi
        mkdir -p "$BIN"
        ln -sf "$target" "$BIN/$cmd"
    fi
}

install_apt_repo() {
    local cmd=$1 pkg=$2 keyurl=$3 source=$4
    local keyring="/etc/apt/keyrings/${cmd}.gpg"
    local tmp; tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 30 -o "$tmp/key" "$keyurl"; then
        echo "$cmd signing key download failed"; rm -rf "$tmp"; return 0
    fi
    # Vendors publish the key either ASCII-armored or already binary, and apt
    # rejects the armored form in a signed-by keyring. Convert by what the file
    # actually is rather than by which vendor it came from.
    if head -c 5 "$tmp/key" | grep -q -- '-----'; then
        gpg --dearmor < "$tmp/key" > "$tmp/keyring.gpg" || {
            echo "$cmd signing key is not a valid keyring"; rm -rf "$tmp"; return 0
        }
    else
        cp "$tmp/key" "$tmp/keyring.gpg"
    fi
    sudo -n install -D -m 0644 "$tmp/keyring.gpg" "$keyring" || {
        echo "$cmd keyring install failed"; rm -rf "$tmp"; return 0
    }
    rm -rf "$tmp"
    # signed-by pins the repo to this one key, so a compromise of any other apt
    # key on the machine cannot sign packages for it.
    printf 'deb [arch=%s signed-by=%s] %s\n' \
        "$(dpkg --print-architecture)" "$keyring" "$source" |
        sudo -n tee "/etc/apt/sources.list.d/${cmd}.list" >/dev/null || {
        echo "$cmd source list write failed"; return 0
    }
    # A new source has to be read before the package exists to install.
    APT_REFRESHED=0
    install_apt "$cmd" "$pkg"
}

install_script() {
    local cmd=$1 args=$2 url=$3 post=$4
    # Installers are piped to bash, not sh: helm's and nvm's use arrays and
    # other bash-only syntax, and dash silently mis-parses them.
    # shellcheck disable=SC2086  # args is a deliberate word-split argument list
    if ! curl -fsSL --max-time 120 "$url" | bash -s -- $args; then
        echo "$cmd install failed"; return 0
    fi
    # Post-install steps are per-tool shell (group membership, a node version to
    # pick) that no column shape generalises, so the table carries the snippet.
    # It is repo-controlled text, reviewed with the row it belongs to.
    if [ -n "$post" ]; then
        eval "$post" || echo "$cmd post-install step failed"
    fi
}

install_binary() {
    local cmd=$1 url=$2 sumurl=$3 version=$4
    url=${url//%v/$version}
    sumurl=${sumurl//%v/$version}
    local asset=${url##*/}
    local tmp; tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 300 -o "$tmp/$asset" "$url"; then
        echo "$cmd download failed"; rm -rf "$tmp"; return 0
    fi
    # These land on PATH and then talk to clusters and decrypt secrets, so an
    # artifact that cannot be checked against the vendor's digest is refused
    # rather than installed anyway — same rule 46 and 47 follow.
    local want got
    want="$(curl -fsSL --max-time 30 "$sumurl" 2>/dev/null |
        awk -v a="$asset" '$2 == a || $2 == "*" a { print $1; exit }')"
    got="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    if [ -z "$want" ]; then
        echo "$cmd checksums unavailable — not installing" >&2
    elif [ "$want" != "$got" ]; then
        echo "$cmd checksum mismatch (got $got, want $want) — not installing" >&2
    else
        mkdir -p "$BIN"
        install -m 0755 "$tmp/$asset" "$BIN/$cmd" && echo "$cmd $version installed"
    fi
    rm -rf "$tmp"
}

install_one() {
    local cmd=$1 spec=$2 guard=$3 package=$4 url=$5 extra=$6 version=$7
    local kind=${spec%%+*} opt=${spec#*+}
    if [ -n "$guard" ]; then
        if [ -e "$HOME/$guard" ]; then
            echo "$cmd already installed — skipping"; return 0
        fi
    elif command -v "$cmd" &>/dev/null; then
        echo "$cmd already installed — skipping"; return 0
    fi
    case $kind in
        apt|apt-repo) opt=root ;;
    esac
    if [ "$opt" = root ] && ! have_root; then
        echo "$cmd needs passwordless sudo — skipping"; return 0
    fi
    case $kind in
        apt) install_apt "$cmd" "$package" ;;
        apt-repo) install_apt_repo "$cmd" "$package" "$url" "$extra" ;;
        script) install_script "$cmd" "$package" "$url" "$extra" ;;
        binary) install_binary "$cmd" "$url" "$extra" "$version" ;;
        *) echo "$cmd: unknown install kind '$kind'" ;;
    esac
}

# A single tool failing must not abort the rest, so install_one never returns
# non-zero and the loop runs to completion under `set -e`.
while IFS='|' read -r cmd kind guard package url extra version; do
    [ -n "$cmd" ] || continue
    install_one "$cmd" "$kind" "$guard" "$package" "$url" "$extra" "$version"
done <<< "$TOOLS"

echo "Dev tooling provisioning complete"
