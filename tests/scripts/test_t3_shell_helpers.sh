#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
functions="$here/home/dot_config/shell/functions.sh"
bashrc="$here/home/dot_bashrc"
zshrc="$here/home/dot_zshrc"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Each call runs in a fresh shell with a sandbox HOME, so the real machine's
# marker and PATH never decide the result.
run_fn() {  # $1 = state dir, rest = function and args -> sets out, err, rc
    local state="$1"
    shift
    rc=0
    out="$(HOME="$tmp/home" XDG_STATE_HOME="$state" PATH="$tmp/bin:$PATH" \
        bash -c 'source "$1"; shift; "$@"' _ "$functions" "$@" 2>"$tmp/err")" || rc=$?
    err="$(cat "$tmp/err")"
}

# ── t3_expiry_notice ──
mkdir -p "$tmp/home" "$tmp/bin" "$tmp/quiet" "$tmp/empty" "$tmp/due"

run_fn "$tmp/quiet" t3_expiry_notice
[ "$rc" -eq 0 ] || fail "notice failed with no marker present" "$err"
[ -z "$out$err" ] || fail "notice printed with no marker present" "$out$err"

# A zero-byte marker carries no session to act on; printing the re-pair hint
# under a bare warning sign would be a prompt to do nothing in particular.
: >"$tmp/empty/t3-session-expiry.warn"
run_fn "$tmp/empty" t3_expiry_notice
[ -z "$out$err" ] || fail "notice printed for an empty marker" "$out$err"

printf '%s\n' 'T3 Code session(s) expiring within 7d:' \
    '  expires in 1d (2026-10-01T05:42:18Z) — abc-123 [iphone | mobile | iOS]' \
    >"$tmp/due/t3-session-expiry.warn"
run_fn "$tmp/due" t3_expiry_notice
[ "$rc" -eq 0 ] || fail "notice returned non-zero with a marker present" "$err"
[ -z "$out" ] || fail "notice wrote to stdout, which a command substitution would capture" "$out"
echo "$err" | grep -q 'abc-123 \[iphone' || fail "notice dropped the marker's session line" "$err"
echo "$err" | grep -q 't3pair <label>' || fail "notice does not say how to re-pair" "$err"
echo "$err" | grep -q 'auth session revoke' || fail "notice does not say how to clear itself" "$err"

# The default state dir is the one the expiry check writes to.
mkdir -p "$tmp/home/.local/state"
cp "$tmp/due/t3-session-expiry.warn" "$tmp/home/.local/state/"
rc=0
err="$(HOME="$tmp/home" bash -c 'unset XDG_STATE_HOME; source "$1"; t3_expiry_notice' _ "$functions" 2>&1)" || rc=$?
echo "$err" | grep -q 'abc-123' || fail "notice ignored the marker under ~/.local/state" "$err"

# ── t3pair ──
cat >"$tmp/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$tmp/bin/npx"

run_fn "$tmp/quiet" t3pair iphone
[ "$rc" -eq 0 ] || fail "t3pair failed" "$err"
want="$(printf '%s\n' t3@latest pair --tailscale --label iphone --ttl 15m)"
[ "$out" = "$want" ] || fail "t3pair passed the wrong arguments" "$out"

run_fn "$tmp/quiet" t3pair "work laptop" 5m
want="$(printf '%s\n' t3@latest pair --tailscale --label "work laptop" --ttl 5m)"
[ "$out" = "$want" ] || fail "t3pair mangled a spaced label or a custom ttl" "$out"

run_fn "$tmp/quiet" t3pair
[ "$rc" -ne 0 ] || fail "t3pair minted a token with no label"
[ -z "$out" ] || fail "t3pair reached npx with no label" "$out"
echo "$err" | grep -q 'Usage: t3pair' || fail "t3pair gave no usage on a missing label" "$err"

# ── rc wiring ──
# Sourced end to end rather than grepped, so a call placed before the function
# is defined, or behind the non-interactive early return, fails here.
mkdir -p "$tmp/home/.config/shell"
cp "$functions" "$tmp/home/.config/shell/functions.sh"
rc=0
err="$(HOME="$tmp/home" bash --norc -ic 'unset XDG_STATE_HOME; source "$1"' _ "$bashrc" 2>&1 >/dev/null)" || rc=$?
echo "$err" | grep -q 'abc-123' || fail "an interactive bash did not show the notice" "$err"

# zsh is not on every box this runs on: where it is, start a real interactive
# zsh against the sandbox; elsewhere fall back to checking an uncommented call
# sits after the loop that defines it.
if command -v zsh >/dev/null 2>&1; then
    cp "$zshrc" "$tmp/home/.zshrc"
    err="$(env -u XDG_STATE_HOME HOME="$tmp/home" ZDOTDIR="$tmp/home" zsh -ic 'exit' </dev/null 2>&1 >/dev/null)" || true
    echo "$err" | grep -q 'abc-123' || fail "an interactive zsh did not show the notice" "$err"
else
    loop_line="$(grep -n '^[^#]*shell/functions\.sh' "$zshrc" | head -n 1 | cut -d: -f1 || true)"
    call_line="$(grep -n '^[^#]*&& t3_expiry_notice[[:space:]]*$' "$zshrc" | head -n 1 | cut -d: -f1 || true)"
    [ -n "$call_line" ] || fail "zshrc never calls t3_expiry_notice"
    [ -n "$loop_line" ] || fail "zshrc no longer sources functions.sh"
    [ "$call_line" -gt "$loop_line" ] || fail "zshrc calls t3_expiry_notice before sourcing functions.sh"
fi

echo "PASS"
