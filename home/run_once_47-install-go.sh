#!/usr/bin/env bash
set -euo pipefail
# The statusline is a Go binary built from scripts/claude-status by an apply.
# Without a toolchain that build is skipped and Claude Code silently falls back
# to its default statusline, so Go is a dependency of this repo, not a
# preference.
BIN="$HOME/.local/bin"
OPT="$HOME/.local/opt"
GO_FALLBACK_VERSION=go1.26.5

# CI provisions its own toolchain for the job that needs it; downloading a
# second one into the chezmoi job would only slow every run down.
[ -z "${CI:-}" ] || { echo "CI detected — skipping Go install"; exit 0; }

if command -v go &>/dev/null; then
    echo "go already installed — skipping"; exit 0
fi
if command -v brew &>/dev/null; then
    brew install go || echo "go brew install failed"; exit 0
elif command -v winget &>/dev/null; then
    winget install --id GoLang.Go --silent \
        --accept-package-agreements --accept-source-agreements ||
        echo "go winget install failed"
    exit 0
elif command -v scoop &>/dev/null; then
    scoop install go || echo "go scoop install failed"; exit 0
fi

if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; then
    echo "go needs brew, winget, or scoop on this platform"; exit 0
fi
# Distro packages trail the language by a release or more, and go.mod pins a
# toolchain the build actually needs, so take the upstream tarball. The pin is
# only a floor for machines that cannot reach the version index.
version="$(curl -fsSL --max-time 15 'https://go.dev/dl/?mode=json' 2>/dev/null |
    sed -n 's/.*"version": *"\(go[0-9.]*\)".*/\1/p' | head -1)"
version=${version:-$GO_FALLBACK_VERSION}

tmp="$(mktemp -d)"
if curl -fsSL --max-time 300 -o "$tmp/go.tar.gz" \
    "https://go.dev/dl/${version}.linux-amd64.tar.gz"; then
    mkdir -p "$OPT" "$BIN"
    rm -rf "$OPT/go"
    tar -xzf "$tmp/go.tar.gz" -C "$OPT"
    for c in go gofmt; do
        [ -x "$OPT/go/bin/$c" ] && ln -sf "$OPT/go/bin/$c" "$BIN/$c"
    done
    echo "$version installed"
else
    echo "go download failed"
fi
rm -rf "$tmp"
