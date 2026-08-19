#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns here match literal shell text in the scripts under test
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$here/home/run_once_42-install-cli-tools.sh"
py="$here/home/run_once_45-install-python-tools.sh"
cloud="$here/home/run_once_46-install-cloud-clis.sh"
go="$here/home/run_once_47-install-go.sh"
voice="$here/home/run_once_48-install-voice-audio-forward.sh"
shellcheck -s bash "$cli" "$py" "$cloud" "$go" "$voice"

fail() { echo "FAIL: $1"; exit 1; }

# --- 42: the manager table ---------------------------------------------------
# read -r splits on a fixed field count, so a row with the wrong number of
# separators silently shifts every id one manager to the left.
rows="$(sed -n "/^TOOLS='$/,/^'$/p" "$cli" | grep '|')"
[ -n "$rows" ] || fail "TOOLS table not found"
while IFS= read -r row; do
    n="$(awk -F'|' '{print NF}' <<< "$row")"
    [ "$n" = 6 ] || fail "row '$row' has $n fields, expected 6"
done <<< "$rows"

# apt is the only manager needing root, and `chezmoi apply` runs unattended —
# an interactive sudo would hang the apply rather than fail it.
grep -q 'sudo -n' "$cli" || fail "apt branch must require non-interactive sudo"
grep -qE 'sudo[^-]*apt-get' "$cli" && ! grep -q 'sudo -n apt-get' "$cli" &&
    fail "apt-get invoked without sudo -n"

# The apt column is the one place where repo content reaches root: on a machine
# with passwordless sudo, an apply installs whatever these rows name, and the
# package's maintainer scripts run as root. Pin the set so a changed or added
# package has to be an explicit, reviewed edit here rather than a one-word diff
# in the table that reads like every other manager id.
APT_ALLOWED='git-delta fd-find eza zoxide fzf direnv neovim unzip sox pulseaudio-utils libasound2-plugins alsa-utils cmake'
# Whole-token comparison, not `grep -w`: a hyphen is a word boundary to grep,
# so `fd` and `find` would both pass against the allowed `fd-find`, and a
# security boundary that accepts substrings of its own entries is not one.
apt_allowed() {
    local want="$1" p
    [ -n "$want" ] || return 1
    for p in $APT_ALLOWED; do
        [ "$p" = "$want" ] && return 0
    done
    return 1
}
while IFS= read -r row; do
    apt_field="$(awk -F'|' '{print $5}' <<< "$row")"
    [ -n "$apt_field" ] || continue
    pkg="${apt_field%%>*}"
    apt_allowed "$pkg" ||
        fail "apt package '$pkg' is not in the reviewed allowlist"
done <<< "$rows"
# Same boundary, other script: unzip is the only package it may install.
# Process substitution, not a pipeline: `fail` in a piped-into loop runs in a
# subshell and its exit never reaches this script.
while IFS= read -r pkg; do
    apt_allowed "$pkg" ||
        fail "cloud CLI script installs unreviewed apt package '$pkg'"
done < <(grep -oE 'sudo -n apt-get install[^|]*' "$cloud" | awk '{print $NF}')
# Same boundary again: voice-audio-forward's apt package list.
voice_pkgs="$(grep "^APT_PKGS=" "$voice" | sed "s/^APT_PKGS='//;s/'$//")"
[ -n "$voice_pkgs" ] || fail "voice-audio-forward APT_PKGS not found"
for pkg in $voice_pkgs; do
    apt_allowed "$pkg" ||
        fail "voice-audio-forward script installs unreviewed apt package '$pkg'"
done

# Debian ships fd as fdfind; without the shim `command -v fd` keeps failing and
# every apply reinstalls it.
grep -q 'fd-find>fdfind' "$cli" || fail "fd apt row missing the binary-name override"
grep -q 'ln -sf' "$cli" || fail "no shim for divergent Debian binary names"
# An unresolvable name would hand ln an empty operand; its failure under set -e
# takes down every tool still queued behind it.
grep -qF 'command -v "$altbin" || true' "$cli" || fail "shim target not resolved defensively"

# --- 45: python tooling ------------------------------------------------------
grep -q 'INSTALLER_NO_MODIFY_PATH=1' "$py" || fail "uv installer must not edit chezmoi-managed rc files"
grep -q 'uv tool install pipx' "$py" || fail "pipx must install via uv"
# uv is installed into ~/.local/bin by this same script; without the PATH
# prepend the very next step cannot see it and pipx is silently skipped.
for s in "$py" "$cloud"; do
    grep -qF 'export PATH="$BIN:$PATH"' "$s" ||
        fail "$(basename "$s"): must put ~/.local/bin on PATH before using uv"
done
# Recent distros refuse pip installs into the system interpreter (PEP 668).
# Comments are stripped first — the rationale for avoiding pip names it.
sed 's/#.*//' "$py" | grep -q 'pip install' &&
    fail "must not pip-install into the system interpreter"

# --- 46: cloud CLIs ----------------------------------------------------------
# Password-free apply is the invariant these scripts exist to preserve: no
# vendor apt repos, no root-owned install trees.
grep -qE 'apt-add-repository|add-apt-repository|/etc/apt/sources.list' "$cloud" &&
    fail "cloud CLIs must not add system apt repositories"
grep -q 'sudo -n' "$cloud" || fail "unzip fallback must require non-interactive sudo"
# Without this the smoke test downloads hundreds of megabytes on every CI run.
grep -qF '${CI:-}' "$cloud" || fail "cloud CLI install not skipped under CI"
grep -q 'path-update false' "$cloud" || fail "gcloud installer must not edit managed rc files"

for tool in terraform aws gcloud az; do
    grep -q "command -v $tool &>/dev/null" "$cloud" || fail "$tool missing idempotency guard"
done

# The pinned version is a fallback for offline/rate-limited machines; if the
# lookup is dropped the pin silently becomes the permanent version.
grep -q 'releases/latest' "$cloud" || fail "terraform version lookup missing"
grep -q 'TERRAFORM_FALLBACK_VERSION' "$cloud" || fail "terraform pinned fallback missing"

# Downloaded artifacts that land on PATH are verified against the vendor's own
# digest, and an unverifiable download is refused rather than installed anyway.
grep -q 'SHA256SUMS' "$cloud" || fail "terraform download not checksum-verified"
grep -q 'checksums unavailable' "$cloud" || fail "terraform must refuse an unverifiable download"
grep -q 'checksum mismatch' "$cloud" || fail "terraform mismatch not rejected"

# --- 47: go ------------------------------------------------------------------
# The statusline build is the reason Go is here; a distro package that trails
# go.mod's pinned toolchain would fail that build rather than skip it.
grep -q 'apt-get\|apt install' "$go" && fail "go must come from the upstream tarball, not a distro package"
grep -q 'command -v go &>/dev/null' "$go" || fail "go missing idempotency guard"
grep -q 'GO_FALLBACK_VERSION' "$go" || fail "go pinned fallback missing"
# Go lands on PATH ahead of the system directories and builds the statusline
# binary Claude Code executes, so an unverified tarball compromises every later
# build. The pinned version carries a pinned digest for the same reason.
grep -q 'GO_FALLBACK_SHA256' "$go" || fail "go pinned fallback has no digest"
grep -q 'sha256sum' "$go" || fail "go tarball not checksum-verified"
grep -q 'checksum mismatch' "$go" || fail "go mismatch not rejected"
# The digest must come from the object naming this tarball: the first sha256 in
# the index belongs to the source archive.
grep -qF 'linux-amd64.tar.gz\""' "$go" || fail "go digest not keyed to the platform archive"
grep -qF '${CI:-}' "$go" || fail "go install not skipped under CI"

# The build script runs in its own process; without the PATH prepend it cannot
# see a Go that this same apply just installed, and silently skips the build.
build="$here/home/run_onchange_after_20-build-claude-status.sh.tmpl"
grep -qF 'export PATH="$HOME/.local/bin:$PATH"' "$build" ||
    fail "claude-status build must put ~/.local/bin on PATH before probing for go"

# --- shared: set -e hazards --------------------------------------------------
for s in "$cli" "$py" "$cloud" "$go"; do
    grep -qE '^[[:space:]]*(command -v|\[ -n).*&&$' "$s" &&
        fail "$(basename "$s"): trailing '&&' continuation aborts under set -e"
done

echo "PASS"
