#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$here/home/run_once_42-install-cli-tools.sh"
py="$here/home/run_once_45-install-python-tools.sh"
cloud="$here/home/run_once_46-install-cloud-clis.sh"
shellcheck -s bash "$cli" "$py" "$cloud"

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

# Debian ships fd as fdfind; without the shim `command -v fd` keeps failing and
# every apply reinstalls it.
grep -q 'fd-find>fdfind' "$cli" || fail "fd apt row missing the binary-name override"
grep -q 'ln -sf' "$cli" || fail "no shim for divergent Debian binary names"

# --- 45: python tooling ------------------------------------------------------
grep -q 'INSTALLER_NO_MODIFY_PATH=1' "$py" || fail "uv installer must not edit chezmoi-managed rc files"
grep -q 'uv tool install pipx' "$py" || fail "pipx must install via uv"
# uv is installed into ~/.local/bin by this same script; without the PATH
# prepend the very next step cannot see it and pipx is silently skipped.
for s in "$py" "$cloud"; do
    grep -q 'export PATH="$BIN:$PATH"' "$s" ||
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
grep -q '${CI:-}' "$cloud" || fail "cloud CLI install not skipped under CI"
grep -q 'path-update false' "$cloud" || fail "gcloud installer must not edit managed rc files"

for tool in terraform aws gcloud az; do
    grep -q "command -v $tool &>/dev/null" "$cloud" || fail "$tool missing idempotency guard"
done

# The pinned version is a fallback for offline/rate-limited machines; if the
# lookup is dropped the pin silently becomes the permanent version.
grep -q 'releases/latest' "$cloud" || fail "terraform version lookup missing"
grep -q 'TERRAFORM_FALLBACK_VERSION' "$cloud" || fail "terraform pinned fallback missing"

# --- shared: set -e hazards --------------------------------------------------
for s in "$cli" "$py" "$cloud"; do
    grep -qE '^[[:space:]]*(command -v|\[ -n).*&&$' "$s" &&
        fail "$(basename "$s"): trailing '&&' continuation aborts under set -e"
done

echo "PASS"
