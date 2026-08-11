#!/usr/bin/env bash
set -euo pipefail
# The statusline is a Go binary built from scripts/claude-status by an apply.
# Without a toolchain that build is skipped and Claude Code silently falls back
# to its default statusline, so Go is a dependency of this repo, not a
# preference.
BIN="$HOME/.local/bin"
OPT="$HOME/.local/opt"
GO_FALLBACK_VERSION=go1.26.5
GO_FALLBACK_SHA256=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053

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
# toolchain the build actually needs, so take the upstream tarball. The index
# carries the digest for every file, so version and digest are read from one
# fetch; the pinned pair below is the floor for a machine that cannot reach it.
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

version=""
digest=""
if curl -fsSL --max-time 15 'https://go.dev/dl/?mode=json' -o "$tmp/index.json" 2>/dev/null; then
    version="$(sed -n 's/.*"version": *"\(go[0-9.]*\)".*/\1/p' "$tmp/index.json" | head -1)"
    # The digest belongs to a specific file, not the release, so it is read from
    # the object that names this tarball rather than the first sha256 in the
    # document — that one is the source archive's.
    [ -n "$version" ] && digest="$(awk -v f="\"${version}.linux-amd64.tar.gz\"" '
        $0 ~ "\"filename\": " f { found = 1 }
        found && /"sha256":/ { gsub(/[",]/, "", $2); print $2; exit }
    ' "$tmp/index.json")"
fi
if [ -z "$version" ] || [ -z "$digest" ]; then
    version=$GO_FALLBACK_VERSION
    digest=$GO_FALLBACK_SHA256
    echo "version index unavailable — falling back to pinned $version"
fi

if ! curl -fsSL --max-time 300 -o "$tmp/go.tar.gz" \
    "https://go.dev/dl/${version}.linux-amd64.tar.gz"; then
    echo "go download failed"; exit 0
fi
# Go ends up on PATH ahead of the system directories and builds the statusline
# binary Claude Code runs, so a swapped archive would compromise every later
# build. Refuse it rather than fall back to installing it unverified.
got="$(sha256sum "$tmp/go.tar.gz" | awk '{print $1}')"
if [ "$got" != "$digest" ]; then
    echo "go checksum mismatch (got $got, want $digest) — not installing" >&2
    exit 1
fi

mkdir -p "$OPT" "$BIN"
rm -rf "$OPT/go"
tar -xzf "$tmp/go.tar.gz" -C "$OPT"
for c in go gofmt; do
    if [ -x "$OPT/go/bin/$c" ]; then ln -sf "$OPT/go/bin/$c" "$BIN/$c"; fi
done
echo "$version installed"
