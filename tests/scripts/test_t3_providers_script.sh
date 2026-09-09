#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
trigger="$here/home/run_onchange_52-enable-t3-providers.sh.tmpl"
dropin="$here/home/dot_config/systemd/user/t3code.service.d/10-provider-path.conf"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

for f in "$trigger" "$dropin"; do
    [ -f "$f" ] || fail "missing $(basename "$f")"
done
command -v chezmoi >/dev/null 2>&1 || { echo "SKIP: chezmoi not on this host"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on this host"; exit 0; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
mkdir -p "$tmp/bin"
bash_bin="$(command -v bash)"
call_log="$tmp/calls.log"

# The trigger's only machine effect besides the settings merge is a
# daemon-reload, so systemctl is the one command stubbed. Everything else it
# runs (jq, mktemp, mv) acts inside the sandbox home and is left real.
cat >"$tmp/bin/systemctl" <<'STUB'
#!/bin/sh
if [ "$1" = "--user" ] && [ "$2" = "show-environment" ]; then
    [ "${STUB_NO_MANAGER:-0}" = "1" ] && exit 1
    exit 0
fi
echo "$*" >>"$CALL_LOG"
exit 0
STUB
chmod +x "$tmp/bin/systemctl"

# Rendered with HOME and the destination both pointing at the sandbox, which
# is the shape a real apply has — the trigger refuses to touch a live ~/.t3
# when they disagree, and that refusal is asserted separately below.
render() {  # $1 = sandbox home -> prints the rendered trigger
    HOME="$1" chezmoi execute-template --source "$here/home" --destination "$1" <"$trigger"
}

# Template source is not valid shell until chezmoi renders it, so the repo-wide
# lint pass skips it and this is the only place it gets checked.
render "$(mktemp -d "$tmp/lint.XXXXXX")" >"$tmp/lint.sh"
shellcheck -s bash "$tmp/lint.sh" || fail "the rendered trigger does not pass shellcheck"

new_home() {  # $1 = active T3 version, empty for no runtime at all
    local h; h="$(mktemp -d "$tmp/home.XXXXXX")"
    mkdir -p "$h/.t3/userdata" "$h/.config/systemd/user/t3code.service.d"
    if [ -n "$1" ]; then
        mkdir -p "$h/.t3/runtime"
        printf '{"protocol":2,"activeVersion":"%s"}\n' "$1" >"$h/.t3/runtime/service-state.json"
    fi
    printf '%s\n' "$h"
}

run_trigger() {  # $1 = sandbox home; sets $out and $rc
    local script; script="$tmp/rendered.sh"
    render "$1" >"$script"
    : >"$call_log"
    set +e
    # BASH_ENV is re-sourced by bash on every non-interactive launch; an
    # ambient one from the caller's shell could reopen PATH and let the real
    # systemctl reach the live user manager instead of the stub.
    out="$(PATH="$tmp/bin:$PATH" HOME="$1" XDG_CONFIG_HOME="$1/.config" CALL_LOG="$call_log" BASH_ENV=/dev/null \
        STUB_NO_MANAGER="${STUB_NO_MANAGER:-0}" "$bash_bin" "$script" 2>&1)"
    rc=$?
    set -e
}

settings_of() { cat "$1/.t3/userdata/settings.json"; }

# ── No T3 installed: says so, changes nothing, exits clean ──
# The provider CLIs are installed by script 43 whether or not T3 is present, so
# a box without the harness must not be an apply failure.
h="$(new_home "")"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed on a box with no T3 installed" "$out"
echo "$out" | grep -q "install T3 Code first" || fail "no diagnostic when settings.json is absent" "$out"
[ -s "$call_log" ] && fail "trigger reloaded systemd with no T3 present" "$(cat "$call_log")"

# ── A settings file T3 has never written: every ungated provider switched on ──
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed against an empty settings file" "$out"
for driver in cursor grok opencode; do
    [ "$(settings_of "$h" | jq -r ".providers.$driver.enabled")" = "true" ] \
        || fail "$driver was not enabled" "$(settings_of "$h")"
done
[ "$(settings_of "$h" | jq -r '.providerInstances.cursor.config.binaryPath')" = "cursor-agent" ] \
    || fail "cursor instance did not get its binary name" "$(settings_of "$h")"

# ── A version-gated provider stays out of the file on an older runtime ──
# Writing a driver an older T3 cannot decode risks the whole provider config,
# so the row must be absent rather than present-and-disabled.
[ "$(settings_of "$h" | jq -r '.providers.antigravity // "absent"')" = "absent" ] \
    || fail "antigravity was written on a runtime below its minVersion" "$(settings_of "$h")"
echo "$out" | grep -q "antigravity needs a newer T3" || fail "gated provider was skipped silently" "$out"

# ── Idempotent: a second run against its own output changes nothing ──
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "second run failed" "$out"
echo "$out" | grep -q "already reconciled" || fail "trigger rewrote a file it had already reconciled" "$out"

# ── A newer runtime lets the gated provider through, with no binary path ──
# T3 installs and resolves Antigravity's ACP server itself, and an empty
# binaryPath is what selects that. Seeding one would pin a path T3 manages.
h="$(new_home "0.0.40")"
echo '{}' >"$h/.t3/userdata/settings.json"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed on a runtime above the gate" "$out"
[ "$(settings_of "$h" | jq -r '.providers.antigravity.enabled')" = "true" ] \
    || fail "antigravity stayed off on a runtime that supports it" "$(settings_of "$h")"
[ "$(settings_of "$h" | jq -r '.providerInstances.antigravity.config | length')" = "0" ] \
    || fail "antigravity was given spawn config it has no use for" "$(settings_of "$h")"

# ── A hand-edited instance survives ──
# settings.json is the server's file and the UI writes into it; an apply that
# reset a binary path someone had corrected would be worse than doing nothing.
h="$(new_home "0.0.38")"
jq -n '{providerInstances: {opencode: {driver: "opencode", enabled: false,
        config: {binaryPath: "/opt/custom/opencode", serverUrl: "http://127.0.0.1:4096"}}}}' \
    >"$h/.t3/userdata/settings.json"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed against a hand-edited instance" "$out"
[ "$(settings_of "$h" | jq -r '.providerInstances.opencode.config.binaryPath')" = "/opt/custom/opencode" ] \
    || fail "an existing binary path was overwritten" "$(settings_of "$h")"
[ "$(settings_of "$h" | jq -r '.providerInstances.opencode.config.serverUrl')" = "http://127.0.0.1:4096" ] \
    || fail "an existing server URL was dropped" "$(settings_of "$h")"
[ "$(settings_of "$h" | jq -r '.providerInstances.opencode.enabled')" = "true" ] \
    || fail "a disabled instance was left disabled" "$(settings_of "$h")"

# ── The PATH drop-in is reloaded, and only when it is deployed ──
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
run_trigger "$h"
grep -qx -- "--user daemon-reload" "$call_log" \
    && fail "reloaded systemd for a drop-in that is not deployed" "$(cat "$call_log")"
printf '[Service]\nEnvironment=PATH=/usr/bin\n' \
    >"$h/.config/systemd/user/t3code.service.d/10-provider-path.conf"
run_trigger "$h"
grep -qx -- "--user daemon-reload" "$call_log" \
    || fail "a deployed drop-in was never loaded into systemd" "$(cat "$call_log")"

# ── No user manager: no reload attempted, and the merge still happens ──
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
printf '[Service]\nEnvironment=PATH=/usr/bin\n' \
    >"$h/.config/systemd/user/t3code.service.d/10-provider-path.conf"
STUB_NO_MANAGER=1 run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed with no systemd user manager" "$out"
[ -s "$call_log" ] && fail "called systemctl despite there being no user manager" "$(cat "$call_log")"
[ "$(settings_of "$h" | jq -r '.providers.grok.enabled')" = "true" ] \
    || fail "settings merge was skipped when systemd was unavailable" "$(settings_of "$h")"

# ── An apply aimed somewhere other than the live home never touches ~/.t3 ──
# ~/.t3 is addressed through $HOME, which a --destination apply does not move.
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
elsewhere="$(mktemp -d "$tmp/dest.XXXXXX")"
HOME="$h" chezmoi execute-template --source "$here/home" --destination "$elsewhere" \
    <"$trigger" >"$tmp/scratch-dest.sh"
PATH="$tmp/bin:$PATH" HOME="$h" XDG_CONFIG_HOME="$h/.config" CALL_LOG="$call_log" BASH_ENV=/dev/null \
    "$bash_bin" "$tmp/scratch-dest.sh" >"$tmp/scratch-dest.out" 2>&1
grep -q "not the live home" "$tmp/scratch-dest.out" \
    || fail "a scratch-destination apply did not announce the skip" "$(cat "$tmp/scratch-dest.out")"
[ "$(settings_of "$h" | jq -r '.providers.grok.enabled // "absent"')" = "absent" ] \
    || fail "a scratch-destination apply wrote to the live home's settings" "$(settings_of "$h")"

# ── The re-run hash actually couples to the things that should re-run it ──
# Both are the point of the trigger: an edit to the drop-in must land a
# daemon-reload, and a T3 upgrade must be what lets a gated row switch on.
h="$(new_home "0.0.38")"
base="$(render "$h")"
printf '{"protocol":2,"activeVersion":"0.0.40"}\n' >"$h/.t3/runtime/service-state.json"
[ "$(render "$h")" != "$base" ] || fail "upgrading T3 does not change the trigger's re-run hash"

render_src="$(mktemp -d "$tmp/src.XXXXXX")"
cp -a "$here/home" "$render_src/home"
h="$(new_home "0.0.38")"
base="$(HOME="$h" chezmoi execute-template --source "$render_src/home" --destination "$h" <"$trigger")"
printf '\n# touched-for-test\n' >>"$render_src/home/dot_config/systemd/user/t3code.service.d/10-provider-path.conf"
touched="$(HOME="$h" chezmoi execute-template --source "$render_src/home" --destination "$h" <"$trigger")"
[ "$touched" != "$base" ] || fail "editing the PATH drop-in does not change the trigger's re-run hash"

# ── The drop-in gives the service a PATH that reaches every provider ──
# Its whole reason to exist: a systemd user unit inherits no shell PATH, so a
# provider installed under ~/.local/bin or a version-managed npm prefix cannot
# be spawned by bare name.
h="$(new_home "0.0.38")"
dropin_content="$(cat "$dropin")"
path_line="$(printf '%s\n' "$dropin_content" | sed -n 's/^Environment=PATH=//p')"
[ -n "$path_line" ] || fail "drop-in sets no PATH" "$dropin_content"
case ":$path_line:" in
    *":%h/.local/bin:"*) ;;
    *) fail "drop-in PATH misses ~/.local/bin, where the vendor installers link" "$path_line" ;;
esac
case ":$path_line:" in
    *":%h/.local/npm-bin:"*) ;;
    *) fail "drop-in PATH misses the stable name for the npm prefix" "$path_line" ;;
esac

# The file must be static. Resolving the npm prefix at render time made its
# content depend on the environment rendering it, so an apply and a verify
# disagreed and CI failed on drift that was real.
printf '%s' "$dropin_content" | grep -qF '{{' &&
    fail "the drop-in carries template directives, so its content can vary by environment"
case "$dropin" in
    *.tmpl) fail "the drop-in is a template again; it must be a static file" ;;
esac

# ── The stable name is pointed at the real npm bin, and repointed after a move ──
# That symlink is the whole reason the file above can be static.
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
if command -v npm >/dev/null 2>&1; then
    fake_prefix="$(mktemp -d "$tmp/npmprefix.XXXXXX")"
    mkdir -p "$fake_prefix/bin"
    cat >"$tmp/bin/npm" <<STUB
#!/bin/sh
[ "\$1" = prefix ] && { echo "\${STUB_NPM_PREFIX:-$fake_prefix}"; exit 0; }
exit 0
STUB
    chmod +x "$tmp/bin/npm"

    STUB_NPM_PREFIX="$fake_prefix" run_trigger "$h"
    [ "$rc" -eq 0 ] || fail "trigger failed while pointing the npm-bin link" "$out"
    [ "$(readlink "$h/.local/npm-bin")" = "$fake_prefix/bin" ] \
        || fail "npm-bin was not pointed at the resolved npm bin" "$(readlink "$h/.local/npm-bin" || echo absent)"

    # A node upgrade moves the prefix. The link has to follow, or the service
    # keeps a PATH entry aimed at a directory that no longer exists.
    moved="$(mktemp -d "$tmp/npmmoved.XXXXXX")"
    mkdir -p "$moved/bin"
    STUB_NPM_PREFIX="$moved" run_trigger "$h"
    [ "$rc" -eq 0 ] || fail "trigger failed after the npm prefix moved" "$out"
    [ "$(readlink "$h/.local/npm-bin")" = "$moved/bin" ] \
        || fail "npm-bin was not repointed after the prefix moved" "$(readlink "$h/.local/npm-bin" || echo absent)"

    # An existing link must be replaced, not followed into.
    [ ! -e "$h/.local/npm-bin/npm-bin" ] || fail "the link was nested inside its own old target"
    rm -f "$tmp/bin/npm"
else
    echo "SKIP: npm not on this host — the npm-bin link cases were not exercised"
fi

# ── An npm that answers nothing must not resolve to /bin ──
# "$(npm prefix -g)/bin" on empty output is the string "/bin", which exists —
# so an unguarded version silently pointed the service's first PATH entry at
# the system bin directory.
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
cat >"$tmp/bin/npm" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$tmp/bin/npm"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed against an npm that reports no prefix" "$out"
[ "$(readlink "$h/.local/npm-bin" 2>/dev/null)" != "/bin" ] \
    || fail "an npm reporting nothing linked the stable name at /bin"
[ ! -e "$h/.local/npm-bin" ] || fail "a link was created from an unusable prefix" \
    "$(readlink "$h/.local/npm-bin")"
echo "$out" | grep -q "no usable global bin directory" \
    || fail "an unusable npm prefix was not reported" "$out"
rm -f "$tmp/bin/npm"

# ── No npm at all: says so, and still reconciles the providers ──
# A box can carry T3 without node; the merge must not be collateral damage.
h="$(new_home "0.0.38")"
echo '{}' >"$h/.t3/userdata/settings.json"
cat >"$tmp/bin/npm" <<'STUB'
#!/bin/sh
exit 127
STUB
chmod +x "$tmp/bin/npm"
rm -f "$tmp/bin/npm"
nonpm="$tmp/nonpm"; mkdir -p "$nonpm"
for u in bash sh env cat sed head sort jq mktemp mv rm mkdir ln readlink printf wc grep; do
    up="$(command -v "$u" 2>/dev/null)" || continue
    ln -sf "$up" "$nonpm/$u"
done
render "$h" >"$tmp/nonpm.sh"
set +e
out="$(PATH="$tmp/bin:$nonpm" HOME="$h" CALL_LOG="$call_log" BASH_ENV=/dev/null \
    "$bash_bin" "$tmp/nonpm.sh" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "trigger failed on a box with no npm" "$out"
echo "$out" | grep -q "no npm on PATH" || fail "absent npm was not reported" "$out"
[ ! -e "$h/.local/npm-bin" ] || fail "a link was created with no npm to resolve"
[ "$(settings_of "$h" | jq -r '.providers.grok.enabled')" = "true" ] \
    || fail "absent npm stopped the provider merge" "$(settings_of "$h")"

echo "PASS"
