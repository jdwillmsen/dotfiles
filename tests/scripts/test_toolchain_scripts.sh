#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns here match literal shell text in the scripts under test
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
cli="$here/home/run_once_42-install-cli-tools.sh"
py="$here/home/run_once_45-install-python-tools.sh"
cloud="$here/home/run_once_46-install-cloud-clis.sh"
go="$here/home/run_once_47-install-go.sh"
dev="$here/home/run_once_49-install-dev-tools.sh.tmpl"
shellcheck -s bash "$cli" "$py" "$cloud" "$go"
# $dev is a template: the installDevTooling guard makes everything below it
# unreachable when rendered off, which is real to that render but not a
# defect to flag, so shellcheck the on render — the one that actually runs.
chez_render "$(chez_init personal true)" "$dev" | shellcheck -s bash -

fail() { echo "FAIL: $1"; [ -z "${2:-}" ] || echo "--- $2"; exit 1; }

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
# bubblewrap is the one entry here that exists to *add* a boundary rather than
# a convenience: it is the sandbox Codex confines its own tool calls to, and
# without it Codex runs them against the real filesystem instead.
APT_ALLOWED='git-delta fd-find eza zoxide fzf direnv neovim unzip sox cmake ripgrep gh kubectl age openjdk-21-jdk bubblewrap'
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

# Run the provisioner against an inert apt/sudo pair. This verifies the new
# sandbox dependency reaches the root-facing invocation, rather than merely
# appearing in the declarative table and its reviewed allowlist.
apt_tmp="$(mktemp -d "$CHEZ_TMP_ROOT/apt-provision.XXXXXXXX")"
apt_stub="$apt_tmp/stub"; apt_sysbin="$apt_tmp/sysbin"
mkdir -p "$apt_stub" "$apt_sysbin"
cat >"$apt_stub/sudo" <<'SH'
#!/usr/bin/env sh
[ "$1" = -n ] && shift
[ "${1:-}" = true ] && exit 0
exec "$@"
SH
cat >"$apt_stub/apt-get" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$APT_LOG"
SH
chmod 755 "$apt_stub/sudo" "$apt_stub/apt-get"
for utility in bash sh env mkdir ln; do
    utility_path="$(type -P "$utility")" || fail "cannot seal $utility"
    ln -s "$utility_path" "$apt_sysbin/$utility"
done
apt_log="$apt_tmp/apt.log"
env -i PATH="$apt_stub:$apt_sysbin" HOME="$apt_tmp/home" APT_LOG="$apt_log" \
    bash "$cli" >/dev/null
grep -qxF 'install -y -qq bubblewrap' "$apt_log" ||
    fail "bubblewrap did not reach the apt-get invocation"

# Same boundary, other script: unzip is the only package it may install.
# Process substitution, not a pipeline: `fail` in a piped-into loop runs in a
# subshell and its exit never reaches this script.
while IFS= read -r pkg; do
    apt_allowed "$pkg" ||
        fail "cloud CLI script installs unreviewed apt package '$pkg'"
done < <(grep -oE 'sudo -n apt-get install[^|]*' "$cloud" | awk '{print $NF}')
# rtk shells out to rg on every search, so ripgrep is a hard dependency of the
# rtk install rather than an optional CLI — it must stay in the table.
grep -qE '^rg\|' <<<"$rows" || fail "ripgrep row missing from the tool table"
# An unlocked `cargo install` re-resolves transitive dependencies to their
# newest semver-compatible releases, which is how eza's build broke on palette
# while the same version built fine from its own lockfile.
grep -q 'cargo install --locked' "$cli" || fail "cargo installs must be --locked"

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

# The outage this covers was invisible to source-reading: the guard was
# `command -v terraform`, so a binary older than the infrastructure tree's
# required_version read as done and was never replaced. Only running the script
# against a terraform that reports a *version* shows the difference.
tf_min="$(sed -n 's/^TERRAFORM_MIN_VERSION=//p' "$cloud")"
tf_fallback="$(sed -n 's/^TERRAFORM_FALLBACK_VERSION=//p' "$cloud")"
if [ -z "$tf_min" ] || [ -z "$tf_fallback" ]; then fail "terraform version constants missing"; fi

# No local EXIT trap: bash keeps one handler per signal, so installing one here
# would replace the harness teardown. Allocating under its root lets it reap this.
tft="$(mktemp -d "$CHEZ_TMP_ROOT/terraform.XXXXXXXX")"
# The minimum is pinned in the copy under test so the cases below keep their
# meaning when the real one moves.
sed 's/^TERRAFORM_MIN_VERSION=.*/TERRAFORM_MIN_VERSION=1.16.3/' "$cloud" >"$tft/cloud.sh"
tf_stub="$tft/stub"; tf_brew="$tft/brew"; tf_home="$tft/home"; tf_log="$tft/log"
tf_bin="$tf_home/.local/bin/terraform"
mkdir -p "$tf_stub" "$tf_brew"

# The archive is a marker naming its own URL: the checksum stub can then derive
# the matching digest, and the unzip stub the version to unpack.
cat >"$tf_stub/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"; out=""
while [ $# -gt 0 ]; do
    if [ "$1" = -o ]; then out="$2"; fi
    shift
done
echo "curl $url" >>"$STUB_LOG"
case "$url" in
    */releases/latest)
        [ -n "${LATEST:-}" ] || exit 22
        printf '{"tag_name": "v%s"}\n' "$LATEST"
        ;;
    *_SHA256SUMS)
        v="${url##*/terraform_}"; v="${v%_SHA256SUMS}"
        archive="terraform_${v}_linux_amd64.zip"
        case "${SUMS_MODE:-ok}" in
            missing) exit 22 ;;
            bad) sum="$(printf 'tampered\n' | sha256sum)" ;;
            *) sum="$(printf 'archive %s\n' "${url%/*}/$archive" | sha256sum)" ;;
        esac
        printf '%s  %s\n' "${sum%% *}" "$archive"
        ;;
    *.zip) printf 'archive %s\n' "$url" >"$out" ;;
    *) exit 22 ;;
esac
SH
cat >"$tf_stub/unzip" <<'SH'
#!/usr/bin/env bash
read -r _ url <"$2"
v="${url##*/terraform_}"
printf '#!/usr/bin/env bash\necho "Terraform v%s"\necho "on linux_amd64"\n' "${v%%_*}" >"$4/terraform"
SH
cat >"$tf_stub/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac
SH
for present in aws gcloud az; do printf '#!/usr/bin/env bash\n' >"$tf_stub/$present"; done
# BREW_LANDS is the version the manager's newest package carries; empty models
# a formula that has nothing newer to offer. BREW_OWNS=0 models a terraform that
# brew never installed, which it refuses to upgrade.
cat >"$tf_brew/brew" <<'SH'
#!/usr/bin/env bash
echo "brew $*" >>"$STUB_LOG"
if [ "$1" = upgrade ] && [ "${BREW_OWNS:-1}" = 0 ]; then exit 1; fi
[ -n "${BREW_LANDS:-}" ] || exit 0
printf '#!/usr/bin/env bash\necho "Terraform v%s"\n' "$BREW_LANDS" >"$TF_BIN"
chmod 755 "$TF_BIN"
SH
chmod 755 "$tf_stub"/* "$tf_brew/brew"

# A sealed PATH: inheriting the caller's would let this machine's real
# terraform, curl and package managers answer for the stubs.
tf_sys="$tft/sysbin"; mkdir -p "$tf_sys"
for u in bash env sed head awk mktemp sha256sum install rm mkdir chmod; do
    up="$(type -P "$u")" || true
    [ -n "$up" ] || fail "cannot sandbox $u: no external binary"
    ln -sf "$up" "$tf_sys/$u"
done

# $1 is the version already on the box ("" for absent).
tf_run() {
    : >"$tf_log"
    rm -rf "$tf_home"; mkdir -p "${tf_bin%/*}"
    if [ -n "$1" ]; then
        printf '#!/usr/bin/env bash\necho "Terraform v%s"\necho "on linux_amd64"\n' "$1" >"$tf_bin"
        chmod 755 "$tf_bin"
    fi
    local path="$tf_stub:$tf_sys"
    [ "${WITH_BREW:-0}" = 0 ] || path="$tf_brew:$path"
    tf_rc=0
    tf_out="$(env -i PATH="$path" HOME="$tf_home" STUB_LOG="$tf_log" TF_BIN="$tf_bin" \
        LATEST="${LATEST-9.9.9}" SUMS_MODE="${SUMS_MODE:-ok}" \
        BREW_LANDS="${BREW_LANDS:-}" BREW_OWNS="${BREW_OWNS:-1}" \
        bash "${TF_SCRIPT:-$tft/cloud.sh}" 2>&1)" || tf_rc=$?
    [ "$tf_rc" -eq 0 ] || fail "cloud CLI script exited $tf_rc with terraform '${1:-absent}'" "$tf_out"
}
tf_have() {
    [ -x "$tf_bin" ] || return 0
    "$tf_bin" | sed -n '1s/^Terraform v//p'
}
tf_expect() { [ "$(tf_have)" = "$1" ] || fail "$2 (terraform is '$(tf_have)', want '$1')" "$tf_out"; }
tf_fetched() { grep -q '\.zip$' "$tf_log"; }

tf_run ''
tf_expect 9.9.9 "absent terraform was not installed"

# 1.9.9 sorts above 1.16.3 as a string and 1.16.10 below it, so these two are
# the cases a lexical comparison gets backwards.
for old in 1.16.0 1.16.2 1.9.9 0.15.5; do
    tf_run "$old"
    tf_expect 9.9.9 "terraform $old is below the minimum but was not upgraded"
done
for current in 1.16.3 1.16.10 1.17.0 2.0.0; do
    tf_run "$current"
    tf_expect "$current" "terraform $current meets the minimum but was replaced"
    if [ -s "$tf_log" ]; then fail "terraform $current still reached the network" "$(cat "$tf_log")"; fi
done

# A binary that reports no version cannot be shown to meet the minimum.
tf_run 1.16.0
printf '#!/usr/bin/env bash\nexit 1\n' >"$tf_bin"
tf_out="$(env -i PATH="$tf_stub:$tf_sys" HOME="$tf_home" STUB_LOG="$tf_log" LATEST=9.9.9 \
    bash "$tft/cloud.sh" 2>&1)" || fail "unreadable terraform aborted the script" "$tf_out"
tf_expect 9.9.9 "terraform with no readable version was kept"

LATEST='' tf_run 1.16.0
tf_expect "$tf_fallback" "an unreachable release index did not fall back to the pinned version"
# An offline machine installs the fallback, so a fallback under the real minimum
# would upgrade to a binary the very next run rejects again.
LATEST='' TF_SCRIPT="$cloud" tf_run "$tf_fallback"
if [ -s "$tf_log" ]; then
    fail "terraform fallback $tf_fallback is below the minimum $tf_min" "$tf_out"
fi

# An upgrade that cannot be verified must leave the working binary in place.
for mode in bad missing; do
    SUMS_MODE="$mode" tf_run 1.16.0
    tf_fetched || fail "checksum case '$mode' never downloaded an archive" "$tf_out"
    tf_expect 1.16.0 "terraform was replaced despite '$mode' checksums"
done

# Where a package manager owns the binary, it does the upgrade — and a package
# that has nothing new enough is reported rather than passing as upgraded.
WITH_BREW=1 BREW_LANDS=1.16.4 tf_run ''
grep -qx 'brew install terraform' "$tf_log" || fail "absent terraform not installed through brew" "$tf_out"
tf_expect 1.16.4 "brew install left no terraform behind"
WITH_BREW=1 BREW_LANDS=1.16.4 tf_run 1.16.0
grep -qx 'brew upgrade terraform' "$tf_log" || fail "old terraform not upgraded through brew" "$tf_out"
tf_fetched && fail "brew-managed terraform was also downloaded directly" "$tf_out"
echo "$tf_out" | grep -q 'still below' && fail "a successful brew upgrade reported as too old" "$tf_out"
# A terraform brew never installed: the upgrade is refused, so brew installs its own.
WITH_BREW=1 BREW_OWNS=0 BREW_LANDS=1.16.4 tf_run 1.16.0
grep -qx 'brew install terraform' "$tf_log" ||
    fail "a terraform brew does not own was not installed through brew" "$tf_out"
tf_expect 1.16.4 "a terraform brew does not own stayed below the minimum"
WITH_BREW=1 tf_run 1.16.0
echo "$tf_out" | grep -q 'still below 1.16.3 after brew upgrade' ||
    fail "a brew upgrade that left terraform too old went unreported" "$tf_out"
WITH_BREW=1 tf_run 1.16.3
if [ -s "$tf_log" ]; then fail "current terraform still invoked brew" "$(cat "$tf_log")"; fi

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

# --- 49: the dev tooling catalog ---------------------------------------------
dev_rows="$(sed -n "/^TOOLS='$/,/^'$/p" "$dev" | grep '|')"
[ -n "$dev_rows" ] || fail "dev tooling TOOLS table not found"
while IFS= read -r row; do
    n="$(awk -F'|' '{print NF}' <<< "$row")"
    [ "$n" = 7 ] || fail "dev row '$row' has $n fields, expected 7"
done <<< "$dev_rows"

# This script is the second place repo content reaches root, and it reaches
# further than 42 does: an apt-repo row installs a signing key and a source
# list, after which that vendor can hand root anything it publishes. Pin the
# hosts as well as the packages, so adding a trust root is a reviewed edit here
# rather than a URL in a table where every other field is harmless.
VENDOR_ALLOWED='get.docker.com sh.rustup.rs raw.githubusercontent.com cli.github.com pkgs.k8s.io github.com'
vendor_allowed() {
    local want="$1" h
    [ -n "$want" ] || return 1
    for h in $VENDOR_ALLOWED; do
        [ "$h" = "$want" ] && return 0
    done
    return 1
}
url_host() { sed -E 's@^https://([^/]+)/.*@\1@; s@^https://([^/]+)$@\1@' <<< "$1"; }

while IFS='|' read -r cmd kind _guard package url extra version; do
    [ -n "$cmd" ] || continue
    case "${kind%%+*}" in
        apt)
            apt_allowed "${package%%>*}" ||
                fail "dev tooling apt package '$package' is not in the reviewed allowlist"
            ;;
        apt-repo)
            apt_allowed "$package" ||
                fail "dev tooling apt package '$package' is not in the reviewed allowlist"
            vendor_allowed "$(url_host "$url")" ||
                fail "$cmd signing key host is not in the reviewed allowlist"
            vendor_allowed "$(url_host "${extra%% *}")" ||
                fail "$cmd apt source host is not in the reviewed allowlist"
            ;;
        script)
            vendor_allowed "$(url_host "$url")" ||
                fail "$cmd installer host is not in the reviewed allowlist"
            ;;
        binary)
            vendor_allowed "$(url_host "$url")" ||
                fail "$cmd release host is not in the reviewed allowlist"
            # A release asset has no signed repository behind it, so the pinned
            # version and the vendor digest are the only things standing between
            # a retagged release and a binary that talks to the cluster.
            [ -n "$version" ] || fail "$cmd binary row has no pinned version"
            [ -n "$extra" ] || fail "$cmd binary row has no checksum source"
            grep -q '%v' <<< "$url" || fail "$cmd asset url does not use the pinned version"
            ;;
        *) fail "$cmd has unknown install kind '$kind'" ;;
    esac
done <<< "$dev_rows"

grep -q 'sudo -n' "$dev" || fail "dev tooling must require non-interactive sudo"
grep -qE 'sudo[^-]*apt-get' "$dev" && ! grep -q 'sudo -n apt-get' "$dev" &&
    fail "dev tooling invokes apt-get without sudo -n"
# An unsigned or globally-signed source lets any key on the machine sign for it.
grep -q 'signed-by=' "$dev" || fail "dev tooling apt sources must be signed-by pinned"
grep -qF '${CI:-}' "$dev" || fail "dev tooling install not skipped under CI"
grep -q 'checksum mismatch' "$dev" || fail "dev tooling binary mismatch not rejected"
grep -q 'checksums unavailable' "$dev" || fail "dev tooling must refuse an unverifiable download"
# 47 owns Go, from the upstream tarball, because go.mod pins a toolchain distro
# packages trail — a catalog row would quietly reintroduce the older one.
grep -qE '^go\|' <<< "$dev_rows" && fail "go must stay with 47, not the catalog"

# chezmoi does not stop a run_once_ script from executing for an entry matched
# only by .chezmoiignore (verified against a minimal reproduction) — the ignore
# rule alone would leave installDevTooling's default `false` installing a
# Docker daemon and a kubectl anyway. This is what actually has to hold.
off_render="$(chez_render "$(chez_init personal)" "$dev")"
echo "$off_render" | grep -q 'installDevTooling is off — skipping' ||
    fail "dev tooling template does not guard on installDevTooling when off"
on_render="$(chez_render "$(chez_init personal true)" "$dev")"
echo "$on_render" | grep -q 'installDevTooling is off — skipping' &&
    fail "dev tooling template still guards when installDevTooling is on"
echo "$on_render" | grep -q 'Dev tooling provisioning complete' ||
    fail "dev tooling template body missing from the opted-in render"

# --- shared: set -e hazards --------------------------------------------------
for s in "$cli" "$py" "$cloud" "$go" "$dev"; do
    grep -qE '^[[:space:]]*(command -v|\[ -n).*&&$' "$s" &&
        fail "$(basename "$s"): trailing '&&' continuation aborts under set -e"
done

echo "PASS"
