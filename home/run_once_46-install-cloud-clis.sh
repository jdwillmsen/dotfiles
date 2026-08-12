#!/usr/bin/env bash
set -euo pipefail
# Infrastructure CLIs for the jdwlabs infrastructure/ and deployments/ trees.
# Every install here lands under ~/.local so `chezmoi apply` stays password-free;
# the vendor packages that would need root (apt repos with their own signing
# keys) are deliberately not used.
BIN="$HOME/.local/bin"
OPT="$HOME/.local/opt"
# az installs through uv, which the preceding script may have just placed in
# $BIN — a directory the apply shell inherited its PATH from before it existed.
export PATH="$BIN:$PATH"
TERRAFORM_FALLBACK_VERSION=1.15.8

# The vendor archives run to hundreds of megabytes. A CI apply — including the
# smoke test, which applies with a real machine role into a throwaway HOME —
# would pay that download on every run and gain nothing from it.
[ -z "${CI:-}" ] || { echo "CI detected — skipping cloud CLI install"; exit 0; }

is_linux_x64() { [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; }

# The vendor archives are zip-only; without unzip the download is dead weight.
have_unzip() {
    command -v unzip &>/dev/null && return 0
    command -v apt-get &>/dev/null && sudo -n true 2>/dev/null || return 1
    DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y -qq unzip
}

install_terraform() {
    if command -v terraform &>/dev/null; then
        echo "terraform already installed — skipping"; return 0
    fi
    if command -v brew &>/dev/null; then
        brew install terraform || echo "terraform brew install failed"; return 0
    elif command -v winget &>/dev/null; then
        winget install --id Hashicorp.Terraform --silent \
            --accept-package-agreements --accept-source-agreements ||
            echo "terraform winget install failed"
        return 0
    elif command -v scoop &>/dev/null; then
        scoop install terraform || echo "terraform scoop install failed"; return 0
    fi
    is_linux_x64 || { echo "terraform needs brew, winget, or scoop on this platform"; return 0; }
    have_unzip || { echo "terraform needs unzip — install it first"; return 0; }

    # Pin only as a floor: the release index is authoritative, but a rate-limited
    # or offline machine still gets a working binary rather than no binary.
    local version tmp
    version="$(curl -fsSL --max-time 15 \
        https://api.github.com/repos/hashicorp/terraform/releases/latest 2>/dev/null |
        sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p' | head -1)"
    version=${version:-$TERRAFORM_FALLBACK_VERSION}

    local base="https://releases.hashicorp.com/terraform/${version}"
    local archive="terraform_${version}_linux_amd64.zip"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 120 -o "$tmp/tf.zip" "$base/$archive"; then
        echo "terraform download failed"; rm -rf "$tmp"; return 0
    fi
    # The vendor publishes a digest for every artifact; a binary that lands on
    # PATH and then provisions infrastructure is not worth installing unchecked.
    local want got
    want="$(curl -fsSL --max-time 30 "$base/terraform_${version}_SHA256SUMS" 2>/dev/null |
        awk -v a="$archive" '$2 == a { print $1; exit }')"
    got="$(sha256sum "$tmp/tf.zip" | awk '{print $1}')"
    if [ -z "$want" ]; then
        echo "terraform checksums unavailable — not installing" >&2
    elif [ "$want" != "$got" ]; then
        echo "terraform checksum mismatch (got $got, want $want) — not installing" >&2
    else
        mkdir -p "$BIN"
        unzip -oq "$tmp/tf.zip" -d "$tmp" && install -m 0755 "$tmp/terraform" "$BIN/terraform" &&
            echo "terraform $version installed"
    fi
    rm -rf "$tmp"
}

install_aws() {
    if command -v aws &>/dev/null; then
        echo "aws already installed — skipping"; return 0
    fi
    if command -v brew &>/dev/null; then
        brew install awscli || echo "aws brew install failed"; return 0
    elif command -v winget &>/dev/null; then
        winget install --id Amazon.AWSCLI --silent \
            --accept-package-agreements --accept-source-agreements ||
            echo "aws winget install failed"
        return 0
    fi
    is_linux_x64 || { echo "aws needs brew or winget on this platform"; return 0; }
    have_unzip || { echo "aws needs unzip — install it first"; return 0; }

    local tmp; tmp="$(mktemp -d)"
    if curl -fsSL --max-time 300 -o "$tmp/awscli.zip" \
        https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip; then
        mkdir -p "$BIN"
        unzip -oq "$tmp/awscli.zip" -d "$tmp" &&
            "$tmp/aws/install" --install-dir "$OPT/aws-cli" --bin-dir "$BIN" --update >/dev/null &&
            echo "aws installed"
    else
        echo "aws download failed"
    fi
    rm -rf "$tmp"
}

install_gcloud() {
    if command -v gcloud &>/dev/null; then
        echo "gcloud already installed — skipping"; return 0
    fi
    if command -v brew &>/dev/null; then
        brew install --cask google-cloud-sdk || echo "gcloud brew install failed"; return 0
    elif command -v winget &>/dev/null; then
        winget install --id Google.CloudSDK --silent \
            --accept-package-agreements --accept-source-agreements ||
            echo "gcloud winget install failed"
        return 0
    fi
    is_linux_x64 || { echo "gcloud needs brew or winget on this platform"; return 0; }

    local tmp; tmp="$(mktemp -d)"
    if curl -fsSL --max-time 600 -o "$tmp/gcloud.tar.gz" \
        https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz; then
        mkdir -p "$OPT" "$BIN"
        rm -rf "$OPT/google-cloud-sdk"
        tar -xzf "$tmp/gcloud.tar.gz" -C "$OPT"
        # Shell rc files are chezmoi-managed, so the bundled installer must not
        # edit them; symlinking the entry points is what puts gcloud on PATH.
        "$OPT/google-cloud-sdk/install.sh" --quiet --path-update false \
            --command-completion false --usage-reporting false >/dev/null &&
            echo "gcloud installed"
        for c in gcloud gsutil bq; do
            [ -x "$OPT/google-cloud-sdk/bin/$c" ] && ln -sf "$OPT/google-cloud-sdk/bin/$c" "$BIN/$c"
        done
    else
        echo "gcloud download failed"
    fi
    rm -rf "$tmp"
}

install_az() {
    if command -v az &>/dev/null; then
        echo "az already installed — skipping"; return 0
    fi
    if command -v brew &>/dev/null; then
        brew install azure-cli || echo "az brew install failed"
    elif command -v winget &>/dev/null; then
        winget install --id Microsoft.AzureCLI --silent \
            --accept-package-agreements --accept-source-agreements ||
            echo "az winget install failed"
    elif command -v uv &>/dev/null; then
        # The vendor Linux installer adds a root-owned apt repo; the CLI is a
        # plain Python application, so an isolated uv tool environment gives the
        # same binary without touching system package trust.
        uv tool install azure-cli || echo "az uv install failed"
    else
        echo "az needs brew, winget, or uv — none present"
    fi
}

install_terraform
install_aws
install_gcloud
install_az

echo "Cloud CLI provisioning complete"
