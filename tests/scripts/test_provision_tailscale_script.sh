#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-tailscale.sh"
shellcheck -s bash "$script"

fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && echo "--- $2"
    exit 1
}

[ -x "$script" ] || fail "provision-tailscale.sh must be executable"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Every privileged effect the script has — apt, systemctl, tailscale and the
# keyring downloads — is stubbed on PATH, so the script's real behaviour can be
# driven and observed without root or a tailnet.
stub="$tmp/stub"; pkg="$tmp/pkg"; mkdir -p "$stub" "$pkg"

cat >"$stub/id" <<'SH'
#!/usr/bin/env bash
[ "$1" = "-u" ] || exit 1
echo "${FAKE_UID:-1000}"
SH

cat >"$stub/curl" <<'SH'
#!/usr/bin/env bash
url="${!#}"
echo "curl $url" >>"$STUB_LOG"
if [ "${CURL_MODE:-ok}" = truncated ]; then
    printf 'partial-body-no-trailer'
    exit 1
fi
printf 'stub-body-for %s\n' "$url"
SH

# Models the real package install: apt is what puts `tailscale` on PATH.
cat >"$stub/apt-get" <<'SH'
#!/usr/bin/env bash
echo "apt-get $*" >>"$STUB_LOG"
if [ "$1" = install ]; then
    install -m 0755 "$PKG_DIR/tailscale" "$STUB_DIR/tailscale"
fi
SH

cat >"$stub/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
SH

cat >"$pkg/tailscale" <<'SH'
#!/usr/bin/env bash
echo "tailscale $*" >>"$STUB_LOG"
case "$1" in
    status)
        [ "${TS_STATUS_RC:-0}" = 0 ] || exit "${TS_STATUS_RC}"
        printf '{\n  "BackendState": "Running",\n  "Self": {\n    "HostName": "box",\n    "DNSName": "%s"\n  }\n}\n' \
            "${TS_DNSNAME:-devbox.tailnet-stub.ts.net.}"
        ;;
    debug)   printf '{\n\t"CorpDNS": true,\n\t"RunSSH": %s,\n\t"WantRunning": true\n}\n' "${TS_RUNSSH:-true}" ;;
    version) printf '1.102.3\n  tailscale commit: deadbeef\n' ;;
    ip)      echo "100.64.0.1" ;;
esac
SH
chmod +x "$stub"/* "$pkg/tailscale"

# A sealed PATH of just the stubs plus the utilities the script actually
# shells out to. Inheriting the caller's PATH would let a real `tailscale` on
# the test machine answer for the stub, so the "not installed yet" and
# "misconfigured node" cases would silently test nothing.
sysbin="$tmp/sysbin"; mkdir -p "$sysbin"
for u in bash env mktemp chmod mv rm sed grep head install; do
    ln -s "$(command -v "$u")" "$sysbin/$u" \
        || { echo "FAIL: cannot sandbox $u"; exit 1; }
done
sandbox="$stub:$sysbin"

printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$tmp/os-release"
printf 'ID=fedora\n' >"$tmp/os-release-fedora"

keyring="$tmp/keyring.gpg"
sources="$tmp/tailscale.list"
log="$tmp/log"

# Baseline: root, Ubuntu, package installed, node joined and fully converged.
# Each case overrides only the state it is actually exercising.
run() {
    : >"$log"
    rm -f "$keyring" "$sources" "$stub/tailscale" "$keyring".* "$sources".*
    if [ "${SEED_REPO:-1}" = 1 ]; then
        echo seeded >"$keyring"
        echo seeded >"$sources"
    fi
    if [ "${SEED_PKG:-1}" = 1 ]; then
        install -m 0755 "$pkg/tailscale" "$stub/tailscale"
    fi
    rc=0
    out="$(env PATH="$sandbox" \
        STUB_LOG="$log" STUB_DIR="$stub" PKG_DIR="$pkg" \
        FAKE_UID="${FAKE_UID:-0}" \
        OS_RELEASE="${OS_RELEASE:-$tmp/os-release}" \
        KEYRING="$keyring" SOURCES="$sources" BASE_URL="https://stub.invalid/ubuntu" \
        CURL_MODE="${CURL_MODE:-ok}" \
        TS_STATUS_RC="${TS_STATUS_RC:-0}" \
        TS_DNSNAME="${TS_DNSNAME:-devbox.tailnet-stub.ts.net.}" \
        TS_RUNSSH="${TS_RUNSSH:-true}" \
        bash "$script" 2>&1)" || rc=$?
}

logged() { grep -q "$1" "$log"; }
converged_call="^tailscale up --hostname=devbox --ssh$"

# ── Guards run before anything is mutated ───────────────────────────────────
FAKE_UID=1000 SEED_PKG=0 run
[ "$rc" -eq 0 ] && fail "exited 0 as a non-root user" "$out"
echo "$out" | grep -q "must run as root" || fail "no root diagnostic" "$out"
if [ -s "$log" ]; then fail "non-root run still invoked privileged commands" "$(cat "$log")"; fi

OS_RELEASE="$tmp/os-release-fedora" run
[ "$rc" -eq 0 ] && fail "exited 0 on a non-Ubuntu distro" "$out"
echo "$out" | grep -qi "ubuntu" || fail "no distro diagnostic" "$out"

# ── Already provisioned and already converged: a genuine no-op ──────────────
run
[ "$rc" -eq 0 ] || fail "converged re-run did not succeed" "$out"
if logged "^apt-get"; then fail "converged re-run touched apt" "$(cat "$log")"; fi
if logged "^curl"; then fail "converged re-run re-downloaded the keyring" "$(cat "$log")"; fi
if logged "^tailscale up"; then fail "converged re-run reconfigured the node" "$(cat "$log")"; fi
echo "$out" | grep -q "already joined as devbox.tailnet-stub.ts.net" \
    || fail "converged re-run did not report the MagicDNS name" "$out"

# ── Convergence, not liveness: an authenticated node can still be wrong ─────
# A node that is up and authenticated but has Tailscale SSH off must still be
# converged, or the break-glass path for re-pairing after a T3 Code session
# hits its hard 30-day TTL is silently absent.
TS_RUNSSH=false run
[ "$rc" -eq 0 ] || fail "SSH-off node failed to converge" "$out"
logged "$converged_call" || fail "authenticated node with SSH off was not converged" "$(cat "$log")"

# Likewise an inferred hostname: the HTTPS certificate Tailscale Serve presents
# and every paired device key on the MagicDNS name being exactly `devbox`.
TS_DNSNAME="ubuntu-2404.tailnet-stub.ts.net." run
[ "$rc" -eq 0 ] || fail "misnamed node failed to converge" "$out"
logged "$converged_call" || fail "authenticated node with the wrong hostname was not converged" "$(cat "$log")"

# A control-plane-deduplicated name merely starting with `devbox` is a
# different host and must not read as converged.
TS_DNSNAME="devbox-1.tailnet-stub.ts.net." run
logged "$converged_call" || fail "deduplicated hostname devbox-1 was accepted as converged" "$(cat "$log")"

# ── Never joined ────────────────────────────────────────────────────────────
TS_STATUS_RC=1 run
[ "$rc" -eq 0 ] || fail "unauthenticated run failed" "$out"
logged "$converged_call" || fail "no join attempt on an unauthenticated node" "$(cat "$log")"
echo "$out" | grep -q "auth URL" || fail "no auth-URL notice" "$out"

# ── First run on a bare machine ─────────────────────────────────────────────
SEED_REPO=0 SEED_PKG=0 run
[ "$rc" -eq 0 ] || fail "first run failed" "$out"
[ -s "$keyring" ] || fail "keyring not written" "$out"
[ -s "$sources" ] || fail "sources list not written" "$out"
logged "^apt-get update" || fail "apt index not refreshed" "$(cat "$log")"
logged "^apt-get install" || fail "tailscale not installed" "$(cat "$log")"
logged "^systemctl enable --now tailscaled$" || fail "tailscaled not enabled" "$(cat "$log")"

# ── Regression: a failed download must not poison the idempotency guard ─────
# `curl >dest` truncates dest before the body arrives, so an interrupted
# transfer left partial bytes that still satisfied `[ -s "$KEYRING" ]`. The
# next run then reported "already present" and apt failed GPG verification on
# every run after that. Publishing by atomic rename leaves nothing behind.
SEED_REPO=0 SEED_PKG=0 CURL_MODE=truncated run
[ "$rc" -eq 0 ] && fail "exited 0 after the keyring download failed" "$out"
if [ -s "$keyring" ]; then fail "partial download left a non-empty keyring" "$(cat "$keyring")"; fi
if [ -n "$(find "$tmp" -maxdepth 1 -name 'keyring.gpg.*' -print -quit)" ]; then
    fail "partial download left a temp file beside the keyring"
fi

echo "PASS"
