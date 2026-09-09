#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
trigger="$here/home/run_onchange_54-set-no-mistakes-agent.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -f "$trigger" ] || fail "missing $(basename "$trigger")"
command -v chezmoi >/dev/null 2>&1 || { echo "SKIP: chezmoi not on this host"; exit 0; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
bash_bin="$(command -v bash)"

want="$(chezmoi execute-template --source "$here/home" '{{ .noMistakesAgent }}')"
[ -n "$want" ] || fail "noMistakesAgent is not declared in the data"

render() {  # $1 = sandbox home -> prints the rendered trigger
    HOME="$1" chezmoi execute-template --source "$here/home" --destination "$1" <"$trigger"
}

# Template source is not valid shell until chezmoi renders it, so the repo-wide
# lint pass skips it and this is the only place it gets checked.
render "$(mktemp -d "$tmp/lint.XXXXXX")" >"$tmp/lint.sh"
shellcheck -s bash "$tmp/lint.sh" || fail "the rendered trigger does not pass shellcheck"

# The real file as no-mistakes ships it: the key surrounded by the documented
# defaults and commented examples an apply must not disturb — including a
# commented `agent:` example, which an unanchored match would rewrite instead.
seed_config() {  # $1 = sandbox home, $2 = current agent value
    mkdir -p "$1/.no-mistakes"
    cat >"$1/.no-mistakes/config.yaml" <<EOF
# no-mistakes global configuration

# Agent to use for code generation. This may also be an ordered fallback list,
# for example: agent: [codex, claude]
# Options: auto, claude, codex, rovodev, opencode, pi, copilot, cursor
agent: $2

# Optional path to the user-installed acpx binary
# acpx_path: acpx

ci_timeout: "168h"
EOF
}

run_trigger() {  # $1 = sandbox home; sets $out and $rc
    render "$1" >"$tmp/rendered.sh"
    set +e
    # BASH_ENV is re-sourced by bash on every non-interactive launch; pinning it
    # keeps an ambient one from the caller's shell out of this run.
    out="$(HOME="$1" BASH_ENV=/dev/null "$bash_bin" "$tmp/rendered.sh" 2>&1)"
    rc=$?
    set -e
}

agent_of() { sed -n 's/^agent:[[:space:]]*//p' "$1/.no-mistakes/config.yaml" | head -n1; }

# ── No config yet: says what to run, changes nothing ──
# The CLI writes this file at `no-mistakes init`, so a box that has the binary
# but has gated no repo yet must not be an apply failure.
h="$(mktemp -d "$tmp/home.XXXXXX")"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed with no config present" "$out"
echo "$out" | grep -q "no-mistakes init" || fail "no diagnostic pointing at init" "$out"

# ── The declared value replaces whatever is there ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h" auto
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed against a stock config" "$out"
[ "$(agent_of "$h")" = "$want" ] || fail "the agent key was not set to the declared value" "$(agent_of "$h")"

# ── Everything else in the file survives byte for byte ──
# The file is the tool's, not the repo's: its defaults and comments are what a
# future upgrade extends, and an apply that rewrote them would freeze it.
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h" auto
grep -v '^agent:' "$h/.no-mistakes/config.yaml" >"$tmp/before-others"
run_trigger "$h"
grep -v '^agent:' "$h/.no-mistakes/config.yaml" >"$tmp/after-others"
diff -u "$tmp/before-others" "$tmp/after-others" >"$tmp/others.diff" ||
    fail "lines other than the agent key changed" "$(cat "$tmp/others.diff")"
grep -q '^# for example: agent: \[codex, claude\]$' "$h/.no-mistakes/config.yaml" ||
    fail "the commented agent example was rewritten"
grep -c '^agent:' "$h/.no-mistakes/config.yaml" | grep -qx 1 ||
    fail "the rewrite left more than one agent key"

# ── Idempotent: a second run reports the no-op and rewrites nothing ──
before="$(cat "$h/.no-mistakes/config.yaml")"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "second run failed" "$out"
echo "$out" | grep -qF "already $want" || fail "converged run did not report a no-op" "$out"
[ "$before" = "$(cat "$h/.no-mistakes/config.yaml")" ] || fail "converged run rewrote the file"

# ── A config with no top-level key is left alone rather than guessed at ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
mkdir -p "$h/.no-mistakes"
printf '# only a commented example here\n# agent: auto\nci_timeout: "168h"\n' \
    >"$h/.no-mistakes/config.yaml"
before="$(cat "$h/.no-mistakes/config.yaml")"
run_trigger "$h"
[ "$rc" -eq 0 ] || fail "trigger failed on a config with no agent key" "$out"
echo "$out" | grep -q "declares no top-level agent key" || fail "no diagnostic for a keyless config" "$out"
[ "$before" = "$(cat "$h/.no-mistakes/config.yaml")" ] || fail "a keyless config was rewritten anyway"

# ── An apply aimed elsewhere never touches the live home ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h" auto
elsewhere="$(mktemp -d "$tmp/dest.XXXXXX")"
HOME="$h" chezmoi execute-template --source "$here/home" --destination "$elsewhere" \
    <"$trigger" >"$tmp/scratch.sh"
HOME="$h" BASH_ENV=/dev/null "$bash_bin" "$tmp/scratch.sh" >"$tmp/scratch.out" 2>&1
grep -q "not the live home" "$tmp/scratch.out" ||
    fail "a scratch-destination apply did not announce the skip" "$(cat "$tmp/scratch.out")"
[ "$(agent_of "$h")" = auto ] || fail "a scratch-destination apply rewrote the live config"

# ── The re-run hash follows the declared value ──
# Without that coupling, changing the fallback list in the data would leave
# every already-applied machine on the old agent.
h="$(mktemp -d "$tmp/home.XXXXXX")"
base="$(render "$h")"
render_src="$(mktemp -d "$tmp/src.XXXXXX")"
cp -a "$here/home" "$render_src/home"
# Replaced, not appended: a duplicate mapping key is a hard YAML error, which
# would fail the render for a reason unrelated to what this asserts.
sed -i 's/^noMistakesAgent: .*/noMistakesAgent: "[codex]"/' "$render_src/home/.chezmoidata.yaml"
touched="$(HOME="$h" chezmoi execute-template --source "$render_src/home" --destination "$h" <"$trigger")"
[ "$touched" != "$base" ] || fail "changing the declared agent does not change the re-run hash"

echo "PASS"
