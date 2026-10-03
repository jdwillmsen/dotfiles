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
# The jdwlabs infrastructure tree declares a required_version, and an older
# binary fails `terraform init` outright. Raise this with that constraint:
# editing it changes this script's content, which is what makes a run_once_
# script run again on machines that already have it recorded.
TERRAFORM_MIN_VERSION=1.16.3
TERRAFORM_FALLBACK_VERSION=1.16.4

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

# Numeric per component: compared as strings, 1.9.0 ranks above 1.16.0. Done in
# the shell rather than with `sort -V`, which not every platform's sort has.
version_lt() {
    local -a have want
    local i h w
    IFS=. read -ra have <<< "$1"
    IFS=. read -ra want <<< "$2"
    for i in 0 1 2; do
        h=$((10#${have[i]:-0})) w=$((10#${want[i]:-0}))
        if ((h < w)); then return 0; fi
        if ((h > w)); then return 1; fi
    done
    return 1
}

# Print the numeric Terraform version on PATH; missing or unreadable versions
# produce no output without failing the caller.
terraform_version() {
    command -v terraform &>/dev/null || return 0
    terraform version 2>/dev/null | sed -n '1s/^Terraform v\([0-9][0-9.]*\).*/\1/p' || true
}

# Keep Terraform at or above TERRAFORM_MIN_VERSION, upgrading through a package
# manager or a checksum-verified Linux x64 download when needed.
install_terraform() {
    local have verb=install
    have="$(terraform_version)"
    if command -v terraform &>/dev/null; then
        # A binary whose version cannot be read is treated as too old: replacing
        # it costs one download, trusting it costs a failed init later.
        if ! version_lt "${have:-0}" "$TERRAFORM_MIN_VERSION"; then
            echo "terraform $have already installed — skipping"; return 0
        fi
        echo "terraform ${have:-of unknown version} is below $TERRAFORM_MIN_VERSION — upgrading"
        verb=upgrade
    fi
    # An upgrade falls back to an install: the binary found on PATH need not be
    # one this manager put there, and a manager will not upgrade what it lacks.
    local manager=""
    local -a winget_args=(--id Hashicorp.Terraform --silent
        --accept-package-agreements --accept-source-agreements)
    if command -v brew &>/dev/null; then
        manager=brew
        { [ "$verb" = upgrade ] && brew upgrade terraform; } ||
            brew install terraform || echo "terraform brew $verb failed"
    elif command -v winget &>/dev/null; then
        manager=winget
        { [ "$verb" = upgrade ] && winget upgrade "${winget_args[@]}"; } ||
            winget install "${winget_args[@]}" || echo "terraform winget $verb failed"
    elif command -v scoop &>/dev/null; then
        manager=scoop
        { [ "$verb" = upgrade ] && scoop update terraform; } ||
            scoop install terraform || echo "terraform scoop $verb failed"
    fi
    if [ -n "$manager" ]; then
        # The manager owns the version here, and its newest package can itself
        # trail the minimum. Only an upgrade is re-checked: a first install is
        # not on this shell's PATH yet on every platform.
        if [ "$verb" = upgrade ] && version_lt "$(terraform_version)" "$TERRAFORM_MIN_VERSION"; then
            echo "terraform is still below $TERRAFORM_MIN_VERSION after $manager $verb — upgrade it by hand" >&2
        fi
        return 0
    fi
    is_linux_x64 || { echo "terraform needs brew, winget, or scoop on this platform"; return 0; }
    have_unzip || { echo "terraform needs unzip — install it first"; return 0; }

    # Pin only as a floor: the release index is authoritative, but a rate-limited
    # or offline machine still gets a working binary rather than no binary. The
    # `|| true` is what lets it: under pipefail a failed fetch fails the
    # assignment, and set -e would end the script before the fallback applies.
    local version tmp
    version="$(curl -fsSL --max-time 15 \
        https://api.github.com/repos/hashicorp/terraform/releases/latest 2>/dev/null |
        sed -n 's/.*"tag_name": *"v\([0-9.]*\)".*/\1/p' | head -1 || true)"
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
        awk -v a="$archive" '$2 == a { print $1; exit }' || true)"
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
