#!/usr/bin/env bash
# shellcheck disable=SC2016  # patterns here match literal shell text in the scripts under test
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
cfg="$(chez_init personal)"
render() { chez_render "$cfg" "$here/$1"; }

skills="$(render home/run_onchange_33-install-agent-skills.sh.tmpl)"
echo "$skills" | shellcheck -s bash -
for want in kunchenguid/axi kunchenguid/lavish-axi vercel-labs/skills; do
    echo "$skills" | grep -qF "$want" || { echo "FAIL: $want missing from skills script"; exit 1; }
done

# no-mistakes ships its own skill via `no-mistakes init`. Installing it from the
# skills CLI as well is what puts a duplicate on disk, so it must not be listed
# as a source — but it must still be treated as declared, or every reconcile
# reports it as drift.
echo "$skills" | grep -q 'skills add.*no-mistakes' && { echo "FAIL: no-mistakes must not install via the skills CLI"; exit 1; }
echo "$skills" | grep -q 'no-mistakes' || { echo "FAIL: no-mistakes missing from the declared allowlist"; exit 1; }

# Same trap in the other direction: mattpocock arrives via its own plugin
# marketplace (claudePlugins), and listing it here too is what made every one
# of its skills load twice.
echo "$skills" | grep -q 'skills add.*mattpocock' && { echo "FAIL: mattpocock must not be in agentSkills"; exit 1; }

# The CLI resolves global-vs-project from the working directory, so a missing
# cd silently installs into whatever repo the apply ran from.
echo "$skills" | grep -q 'cd "$HOME"' || { echo "FAIL: skills script must cd to \$HOME before installing"; exit 1; }

clis="$(render home/run_onchange_43-install-agent-clis.sh.tmpl)"
echo "$clis" | shellcheck -s bash -

# Both scripts run under `set -e`, where a trailing `cond && echo` aborts the
# script whenever the condition is false — silently skipping everything after it.
for s in "$skills" "$clis"; do
    printf '%s\n' "$s" | grep -qE '^[[:space:]]*(command -v|\[ -n).*&&$' &&
        { echo "FAIL: trailing '&&' continuation aborts under set -e"; exit 1; }
done

# ── Agent CLI reconcile, executed rather than read ──────────────────────────
# The bug this covers was invisible to source-reading: the script's first
# branch was `command -v <tool>`, so any installed version read as done and no
# tool ever advanced again. Only running it against tools that report a
# *version* shows the difference, so the whole table is driven through stubs.
# No local EXIT trap: bash keeps one handler per signal, so installing one here
# would replace the harness teardown and leave the run root unswept. Allocating
# under it instead lets that teardown reap this too, on signals as well as exit.
tmp="$(mktemp -d "$CHEZ_TMP_ROOT/agentcli.XXXXXXXX")"
printf '%s\n' "$clis" >"$tmp/clis.sh"

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "--- $2"; exit 1; }

# Declared versions come from the same data the script renders from, so a
# routine version bump does not turn into a test edit.
declared() { chez_tmpl "$cfg" "{{ range .agentClis }}{{ if eq .name \"$1\" }}{{ .version }}{{ end }}{{ end }}"; }
nm_want="$(declared no-mistakes)"
gnhf_want="$(declared gnhf)"
# A row with no version renders an empty pin, which never matches what is
# installed — the tool would then be reinstalled on every run rather than
# converging.
unpinned="$(chez_tmpl "$cfg" '{{ range .agentClis }}{{ if not .version }} {{ .name }}{{ end }}{{ end }}')"
[ -z "$unpinned" ] || fail "agentClis rows with no declared version:$unpinned"
if [ -z "$nm_want" ] || [ -z "$gnhf_want" ]; then fail "the stubbed rows left agentClis"; fi

stub="$tmp/stub"; mkdir -p "$stub"

# Stands in for the vendor's install.sh. The point it models is the whole
# design tension: it resolves its own version and takes no version input, so a
# declared pin can only be checked after it runs.
cat >"$tmp/vendor-installer" <<'SH'
#!/usr/bin/env bash
echo "vendor-installer $VENDOR_VERSION" >>"$STUB_LOG"
cat >"$STUB_DIR/no-mistakes" <<EOF
#!/usr/bin/env bash
echo "no-mistakes version $VENDOR_VERSION (deadbee) 2026-01-01T00:00:00Z"
EOF
chmod 755 "$STUB_DIR/no-mistakes"
SH

cat >"$stub/curl" <<'SH'
#!/usr/bin/env bash
echo "curl ${!#}" >>"$STUB_LOG"
[ "${CURL_MODE:-ok}" = ok ] || exit 22
printf 'exec "$VENDOR_INSTALLER"\n'
SH

# npm honours an exact `pkg@version`, so this stub installs whatever version
# the spec names — a script that dropped the pin would install "gnhf" and the
# resulting version assertion would catch it.
cat >"$stub/npm" <<'SH'
#!/usr/bin/env bash
echo "npm $*" >>"$STUB_LOG"
[ "$1" = install ] || exit 0
[ "${NPM_MODE:-ok}" = ok ] || exit 1
spec="${!#}"
cat >"$STUB_DIR/gnhf" <<EOF
#!/usr/bin/env bash
echo "${spec##*@}"
EOF
chmod 755 "$STUB_DIR/gnhf"
SH
chmod +x "$stub"/* "$tmp/vendor-installer"

# A sealed PATH: inheriting the caller's would let the real no-mistakes, gnhf
# and npm on this machine answer for the stubs, and every case below would
# assert nothing.
sysbin="$tmp/sysbin"; mkdir -p "$sysbin"
for u in bash sh env head grep cat chmod rm printf; do
    up="$(type -P "$u")"
    [ -n "$up" ] || fail "cannot sandbox $u: no external binary"
    ln -sf "$up" "$sysbin/$u" || fail "cannot sandbox $u"
done

# Seal self-test. Every case below asserts what the script does about a tool at
# a given version, which means nothing if a real binary on this machine can
# answer for its stub. Prove the hole is shut rather than trusting `env -i` to
# have shut it — a leak here would make the whole file pass vacuously.
seal_resolves() { env -i PATH="$1" bash -c "command -v $2 || true"; }
for b in npm curl no-mistakes gnhf node; do
    got="$(seal_resolves "$stub:$sysbin" "$b")"
    case "$got" in
        "$stub"/*|"") ;;
        *) fail "sealed PATH leaks: $b resolves to $got, not a stub" ;;
    esac
done
[ -z "$(seal_resolves "$sysbin" npm)" ] || fail "the no-npm PATH still resolves an npm"

# Belt and braces behind the seal: `npm install -g` takes its prefix from the
# node installation, not from PATH or HOME, so a stub that ever fell through to
# the real npm would install into the machine's real global node_modules. The
# runs below pin the prefix into the sandbox; this records the real one so the
# end of the file can prove nothing reached it.
real_global=""
if command -v npm &>/dev/null; then real_global="$(npm root -g 2>/dev/null || true)"; fi
global_stamp() {
    if [ -n "$real_global" ] && [ -d "$real_global" ]; then
        stat -c %Y "$real_global" 2>/dev/null || echo unavailable
    else
        echo none
    fi
}
global_before="$(global_stamp)"

log="$tmp/log"

seed() {
    printf '#!/usr/bin/env bash\necho %s\n' "$2" >"$stub/$1"
    chmod 755 "$stub/$1"
}

# SEED_NM / SEED_GNHF are the versions already on the box ("" for absent);
# VENDOR_VERSION is what the vendor's latest-only installer would land.
run() {
    : >"$log"
    rm -f "$stub/no-mistakes" "$stub/gnhf"
    [ -z "${SEED_NM:-}" ] || seed no-mistakes "\"no-mistakes version $SEED_NM (cafe123) 2026-01-01T00:00:00Z\""
    [ -z "${SEED_GNHF:-}" ] || seed gnhf "$SEED_GNHF"
    local path="$stub:$sysbin"
    [ "${WITH_NPM:-1}" = 1 ] || path="$sysbin"
    rc=0
    out="$(env -i PATH="$path" HOME="$tmp/home" \
        STUB_LOG="$log" STUB_DIR="$stub" VENDOR_INSTALLER="$tmp/vendor-installer" \
        npm_config_prefix="$tmp/npm-global" \
        VENDOR_VERSION="${VENDOR_VERSION:-$nm_want}" \
        CURL_MODE="${CURL_MODE:-ok}" NPM_MODE="${NPM_MODE:-ok}" \
        bash "$tmp/clis.sh" 2>&1)" || rc=$?
}

logged() { grep -q "$1" "$log"; }

# ── Absent tools install, at the declared version ───────────────────────────
SEED_NM='' SEED_GNHF='' run
[ "$rc" -eq 0 ] || fail "bare-machine run failed" "$out"
logged '^curl ' || fail "absent no-mistakes did not fetch the installer" "$out"
logged "^npm install -g gnhf@$gnhf_want\$" ||
    fail "absent gnhf was not installed at the declared version" "$(cat "$log")"
echo "$out" | grep -q "no-mistakes: now at $nm_want" || fail "no-mistakes not converged" "$out"
echo "$out" | grep -q "gnhf: now at $gnhf_want" || fail "gnhf not converged" "$out"

# ── Already at the declared version: a genuine no-op ────────────────────────
SEED_NM="$nm_want" SEED_GNHF="$gnhf_want" run
[ "$rc" -eq 0 ] || fail "converged re-run failed" "$out"
if [ -s "$log" ]; then fail "converged re-run still invoked an installer" "$(cat "$log")"; fi
echo "$out" | grep -q "no-mistakes is at the declared version" || fail "no no-op report" "$out"
echo "$out" | grep -q "gnhf is at the declared version" || fail "no no-op report" "$out"

# ── Out of date: the regression. An older tool must advance, not be skipped ──
SEED_NM="v0.0.1" SEED_GNHF="0.0.1" run
[ "$rc" -eq 0 ] || fail "upgrade run failed" "$out"
logged '^curl ' || fail "stale no-mistakes was skipped instead of upgraded" "$out"
logged "^npm install -g gnhf@$gnhf_want\$" || fail "stale gnhf was skipped" "$(cat "$log")"
echo "$out" | grep -q "no-mistakes: installed 0.0.1, declared $nm_want" ||
    fail "installed-versus-declared state was not reported" "$out"
echo "$out" | grep -q "no-mistakes: now at $nm_want" || fail "no-mistakes did not advance" "$out"
echo "$out" | grep -q "gnhf: now at $gnhf_want" || fail "gnhf did not advance" "$out"

# ── The pin cannot be handed to a vendor installer, so it must be checked ────
# A curl-pipe installer resolves its own version. When that overshoots what the
# repo declares, the run has to say so — a silent overshoot is exactly how the
# declared value becomes fiction.
SEED_NM="v0.0.1" SEED_GNHF="$gnhf_want" VENDOR_VERSION="v9.9.9" run
[ "$rc" -eq 0 ] || fail "vendor overshoot aborted the run" "$out"
echo "$out" | grep -q "no-mistakes: now at 9.9.9, but $nm_want is declared" ||
    fail "vendor installing past the declared version was not reported" "$out"

# ── Unattended safety: no installer or package manager still exits clean ────
SEED_NM='' SEED_GNHF='' WITH_NPM=0 run
[ "$rc" -eq 0 ] || fail "missing package managers must not fail the apply" "$out"
echo "$out" | grep -q "gnhf requires npm" || fail "no npm diagnostic" "$out"
echo "$out" | grep -q "no-mistakes requires curl" || fail "no curl diagnostic" "$out"

# A failing installer must not abort the rest of the table under `set -e`.
SEED_NM='' SEED_GNHF='' CURL_MODE=fail NPM_MODE=fail run
[ "$rc" -eq 0 ] || fail "installer failures aborted the apply" "$out"
echo "$out" | grep -q "no-mistakes install failed" || fail "no install-failure report" "$out"
echo "$out" | grep -q "gnhf npm install failed" || fail "no npm-failure report" "$out"
echo "$out" | grep -q "agent CLIs reconciled" || fail "run aborted before completing" "$out"

# The seal held for every case above, not just at the moment it was checked.
[ "$(global_stamp)" = "$global_before" ] ||
    fail "a run reached the real global npm prefix at $real_global"

echo "PASS"
