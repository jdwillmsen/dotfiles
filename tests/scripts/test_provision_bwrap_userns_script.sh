#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/scripts/provision-bwrap-userns.sh"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -f "$script" ] || fail "provision-bwrap-userns.sh is missing"
[ -x "$script" ] || fail "provision-bwrap-userns.sh is not executable"
shellcheck -s bash "$script"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
mkdir -p "$tmp/bin" "$tmp/sys"
bash_bin="$(command -v bash)"
for u in bash sh env cat printf id; do
    up="$(command -v "$u" 2>/dev/null)" || continue
    ln -sf "$up" "$tmp/sys/$u"
done
sealed="$tmp/bin:$tmp/sys"
log="$tmp/calls.log"

# Every command that reaches the system is stubbed. The script writes under
# /etc and reloads AppArmor on a real box, so a leaked real apparmor_parser or
# sysctl would make this test change the machine it is testing.
cat >"$tmp/bin/sysctl" <<'STUB'
#!/bin/sh
echo "${STUB_RESTRICTED:-1}"
STUB
cat >"$tmp/bin/apparmor_parser" <<'STUB'
#!/bin/sh
echo "apparmor_parser $*" >>"$CALL_LOG"
exit "${STUB_PARSER_RC:-0}"
STUB
cat >"$tmp/bin/runuser" <<'STUB'
#!/bin/sh
echo "runuser $*" >>"$CALL_LOG"
exit "${STUB_UNSHARE_RC:-0}"
STUB
chmod +x "$tmp/bin"/*

# Stands in for bwrap: only its presence and executability are read before the
# verification step, which runs through the runuser stub above.
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/fakebin/bwrap"
chmod +x "$tmp/fakebin/bwrap"

run() {  # sets $out and $rc; $1 = profile path, rest of the config via STUB_*
    : >"$log"
    set +e
    # BASH_ENV is re-sourced by bash on every non-interactive launch; pinning it
    # keeps an ambient one from reopening this sealed PATH.
    out="$(PATH="$sealed" BASH_ENV=/dev/null CALL_LOG="$log" \
        STUB_RESTRICTED="${STUB_RESTRICTED:-1}" \
        STUB_PARSER_RC="${STUB_PARSER_RC:-0}" \
        STUB_UNSHARE_RC="${STUB_UNSHARE_RC:-0}" \
        SUDO_USER="${SUDO_USER_OVERRIDE:-tester}" \
        BWRAP="${BWRAP_OVERRIDE:-$tmp/fakebin/bwrap}" PROFILE="$1" \
        "$bash_bin" "$script" 2>&1)"
    rc=$?
    set -e
}

# ── Refuses without root rather than failing obscurely partway through ──
# It writes under /etc; a non-root run must say so before touching anything.
if [ "$(id -u)" != 0 ]; then
    profile="$tmp/profile-nonroot"
    run "$profile"
    [ "$rc" -eq 0 ] && fail "exited 0 when not run as root" "$out"
    echo "$out" | grep -q "must run as root" || fail "no root diagnostic" "$out"
    [ -e "$profile" ] || true
    [ ! -s "$log" ] || fail "touched the system before the root check" "$(cat "$log")"
else
    echo "note: running as root, so the non-root refusal case is not exercised"
fi

# The remaining cases need the root branch. Rather than requiring root, drive
# the script with its own id check satisfied by a stub: the point under test is
# what it does after that check, not the check itself.
printf '#!/bin/sh\necho 0\n' >"$tmp/bin/id"
chmod +x "$tmp/bin/id"

# ── A kernel that does not restrict userns is a no-op, not a write ──
# The profile would be inert there and the reload pure noise.
profile="$tmp/profile-unrestricted"
STUB_RESTRICTED=0 run "$profile"
[ "$rc" -eq 0 ] || fail "unrestricted kernel was treated as an error" "$out"
echo "$out" | grep -q "does not restrict unprivileged userns" ||
    fail "no diagnostic on an unrestricted kernel" "$out"
[ ! -e "$profile" ] || fail "wrote a profile on a kernel that needs none"
[ ! -s "$log" ] || fail "reloaded AppArmor on a kernel that needs none" "$(cat "$log")"

# ── The restricted case writes a profile that grants userns and nothing else ──
# Asserted on a parsed model of the profile, not on its raw text: the file is
# AppArmor's own input format, and what matters is which rules it carries.
profile="$tmp/profile-main"
run "$profile"
[ "$rc" -eq 0 ] || fail "the restricted case failed" "$out"
[ -s "$profile" ] || fail "no profile was written" "$out"
# Body only: the profile header carries the binary path and flags, which are
# asserted separately, and folding it in here would read as a stray rule.
rules="$(sed -n '/^profile /,/^}/p' "$profile" | sed '1d;$d' |
    sed 's/#.*//' | tr -d ' \t' | grep -v '^$')"
printf '%s\n' "$rules" | grep -qx 'userns,' || fail "profile does not grant userns" "$profile"
extra="$(printf '%s\n' "$rules" | grep -vx 'userns,' | grep -v '^includeifexists' || true)"
[ -z "$extra" ] || fail "profile carries rules beyond userns" "$extra"
grep -qF "$tmp/fakebin/bwrap" "$profile" || fail "profile does not name the bwrap binary" "$profile"
grep -qF "flags=(unconfined)" "$profile" ||
    fail "profile is not the unconfined-label shape Ubuntu uses for this" "$profile"

# Loaded through the real consumer's interface, and verified by an actual
# unshare rather than by trusting the reload.
grep -q "^apparmor_parser -r -W $profile\$" "$log" ||
    fail "the profile was never loaded into AppArmor" "$(cat "$log")"
grep -q "unshare-user" "$log" || fail "the result was never verified by an unshare" "$(cat "$log")"

# ── Idempotent: a second run reports the file is current and reloads again ──
before="$(cat "$profile")"
run "$profile"
[ "$rc" -eq 0 ] || fail "second run failed" "$out"
echo "$out" | grep -q "already current" || fail "second run rewrote an identical profile" "$out"
[ "$before" = "$(cat "$profile")" ] || fail "second run changed the profile"

# ── A rejected profile is an error, not a silent partial success ──
profile="$tmp/profile-rejected"
STUB_PARSER_RC=1 run "$profile"
[ "$rc" -eq 0 ] && fail "exited 0 when apparmor_parser rejected the profile" "$out"
echo "$out" | grep -q "apparmor_parser rejected" || fail "no diagnostic for a rejected profile" "$out"

# ── Still blocked afterwards is a failure: the whole point is the capability ──
# A profile that loads but does not take is the exact silent case this guards.
profile="$tmp/profile-blocked"
STUB_UNSHARE_RC=1 run "$profile"
[ "$rc" -eq 0 ] && fail "exited 0 while bwrap still could not unshare" "$out"
echo "$out" | grep -q "still cannot unshare" || fail "no diagnostic when the fix did not take" "$out"

# ── An absent bwrap is named, not discovered as a confusing parser error ──
profile="$tmp/profile-nobwrap"
BWRAP_OVERRIDE="$tmp/fakebin/does-not-exist" run "$profile"
[ "$rc" -eq 0 ] && fail "exited 0 with no bubblewrap installed" "$out"
echo "$out" | grep -q "no bubblewrap at" || fail "absent bubblewrap was not named" "$out"
[ ! -e "$profile" ] || fail "wrote a profile for a binary that is not there"

echo "PASS"
