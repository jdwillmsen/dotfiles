#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
trigger="$here/home/run_onchange_55-set-no-mistakes-commit-trailers.sh.tmpl"

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

render() {  # $1 = sandbox home -> prints the rendered trigger
    HOME="$1" chezmoi execute-template --source "$here/home" --destination "$1" <"$trigger"
}

# Template source is not valid shell until chezmoi renders it, so the repo-wide
# lint pass skips it and this is the only place it gets checked.
render "$(mktemp -d "$tmp/lint.XXXXXX")" >"$tmp/lint.sh"
shellcheck -s bash "$tmp/lint.sh" || fail "the rendered trigger does not pass shellcheck"

seed_config() {  # $1 = sandbox home
    mkdir -p "$1/.no-mistakes"
    cat >"$1/.no-mistakes/config.yaml" <<'EOF'
# no-mistakes global configuration
agent: [claude, codex, grok]

# Auto-fix commit subject template.
# commit:
#   fix_message: "no-mistakes({{.Step}}): {{.Summary}}"

ci_timeout: "168h"
EOF
}

# A stand-in binary on PATH answers --version the way the real CLI does, so the
# version gate is exercised without installing anything.
fake_cli() {  # $1 = version -> prints a PATH entry holding the fake binary
    local dir
    dir="$(mktemp -d "$tmp/bin.XXXXXX")"
    printf '#!/bin/sh\necho "no-mistakes version v%s (0000000) 2026-10-05T00:00:00Z"\n' "$1" >"$dir/no-mistakes"
    chmod +x "$dir/no-mistakes"
    printf '%s' "$dir"
}

run_trigger() {  # $1 = sandbox home, $2 = PATH prefix; sets $out and $rc
    render "$1" >"$tmp/rendered.sh"
    set +e
    # BASH_ENV is re-sourced by bash on every non-interactive launch; pinning it
    # keeps an ambient one from the caller's shell out of this run.
    out="$(HOME="$1" PATH="$2:$PATH" BASH_ENV=/dev/null "$bash_bin" "$tmp/rendered.sh" 2>&1)"
    rc=$?
    set -e
}

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq not on this host"; exit 0; }
# Re-encoded through yq because Go's JSON escapes < and > while yq does not;
# both decode to the same strings, which is the comparison that matters.
want_json="$(chezmoi execute-template --source "$here/home" '{{ .noMistakesCommitTrailers | toJson }}' |
    yq -p=json -o=json -I=0 '.')"
[ "$want_json" != "null" ] || fail "noMistakesCommitTrailers is not declared in the data"

# Parsed, not grepped: what matters is what the tool's YAML loader will read.
trailers_of() {  # $1 = sandbox home -> commit.trailers as compact JSON
    yq -o=json -I=0 '.commit.trailers' "$1/.no-mistakes/config.yaml"
}

new="$(fake_cli 1.88.0)"

# ── No config yet: says what to run, changes nothing ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
run_trigger "$h" "$new"
[ "$rc" -eq 0 ] || fail "trigger failed with no config present" "$out"
echo "$out" | grep -q "no-mistakes init" || fail "no diagnostic pointing at init" "$out"

# ── A binary older than the key leaves the config alone ──
# Writing the key for a binary that predates it would fail every pipeline run.
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h"
before="$(cat "$h/.no-mistakes/config.yaml")"
run_trigger "$h" "$(fake_cli 1.60.2)"
[ "$rc" -eq 0 ] || fail "trigger failed against an old binary" "$out"
echo "$out" | grep -q "predates 1.88.0" || fail "no diagnostic for an old binary" "$out"
[ "$before" = "$(cat "$h/.no-mistakes/config.yaml")" ] || fail "an old binary's config was rewritten"

# ── A new enough binary gets exactly the declared trailers ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h"
cp "$h/.no-mistakes/config.yaml" "$tmp/seed"
run_trigger "$h" "$new"
[ "$rc" -eq 0 ] || fail "trigger failed against a new binary" "$out"
[ "$(trailers_of "$h")" = "$want_json" ] ||
    fail "commit.trailers does not match the declared list" "$(trailers_of "$h")"
[ "$(yq '.agent | length' "$h/.no-mistakes/config.yaml")" = 3 ] || fail "the agent key was disturbed"

# ── Everything the tool wrote survives byte for byte ──
head -n "$(wc -l <"$tmp/seed")" "$h/.no-mistakes/config.yaml" >"$tmp/kept"
diff -u "$tmp/seed" "$tmp/kept" >"$tmp/kept.diff" || fail "lines outside the managed block changed" "$(cat "$tmp/kept.diff")"

# ── Idempotent: a second run reports the no-op and rewrites nothing ──
before="$(cat "$h/.no-mistakes/config.yaml")"
run_trigger "$h" "$new"
[ "$rc" -eq 0 ] || fail "second run failed" "$out"
echo "$out" | grep -q "already set" || fail "converged run did not report a no-op" "$out"
[ "$before" = "$(cat "$h/.no-mistakes/config.yaml")" ] || fail "converged run rewrote the file"

# ── A changed declaration replaces the block rather than adding a second ──
sed -i 's/no-mistakes:{{\.Agent}}/stale:{{.Agent}}/' "$h/.no-mistakes/config.yaml"
run_trigger "$h" "$new"
[ "$(trailers_of "$h")" = "$want_json" ] || fail "a stale managed block was not replaced" "$(trailers_of "$h")"
grep -c '^commit:' "$h/.no-mistakes/config.yaml" | grep -qx 1 || fail "the rewrite left more than one commit key"

# ── A hand-written commit section is left for a human ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h"
printf 'commit:\n  fix_message: "{{.Summary}}"\n' >>"$h/.no-mistakes/config.yaml"
before="$(cat "$h/.no-mistakes/config.yaml")"
run_trigger "$h" "$new"
[ "$rc" -eq 0 ] || fail "trigger failed on a config with its own commit section" "$out"
echo "$out" | grep -q "add the trailers there by hand" || fail "no diagnostic for an existing commit section" "$out"
[ "$before" = "$(cat "$h/.no-mistakes/config.yaml")" ] || fail "an existing commit section was rewritten"

# ── An apply aimed elsewhere never touches the live home ──
h="$(mktemp -d "$tmp/home.XXXXXX")"
seed_config "$h"
before="$(cat "$h/.no-mistakes/config.yaml")"
elsewhere="$(mktemp -d "$tmp/dest.XXXXXX")"
HOME="$h" chezmoi execute-template --source "$here/home" --destination "$elsewhere" \
    <"$trigger" >"$tmp/scratch.sh"
HOME="$h" PATH="$new:$PATH" BASH_ENV=/dev/null "$bash_bin" "$tmp/scratch.sh" >"$tmp/scratch.out" 2>&1
grep -q "not the live home" "$tmp/scratch.out" ||
    fail "a scratch-destination apply did not announce the skip" "$(cat "$tmp/scratch.out")"
[ "$before" = "$(cat "$h/.no-mistakes/config.yaml")" ] || fail "a scratch-destination apply rewrote the live config"

# ── The re-run hash follows both the trailers and the declared version ──
# A version bump must re-run the script, or a machine skipped as too old stays
# without trailers after it upgrades.
h="$(mktemp -d "$tmp/home.XXXXXX")"
base="$(render "$h")"
for edit in 's/stale-never-matches//' 's/^    version: "v1\.88\.0"/    version: "v1.88.1"/' 's/no-mistakes:{{\.Agent}}/x:{{.Agent}}/'; do
    src="$(mktemp -d "$tmp/src.XXXXXX")"
    cp -a "$here/home" "$src/home"
    sed -i "$edit" "$src/home/.chezmoidata.yaml"
    touched="$(HOME="$h" chezmoi execute-template --source "$src/home" --destination "$h" <"$trigger")"
    case "$edit" in
        *stale-never-matches*) [ "$touched" = "$base" ] || fail "an unrelated render changed the re-run hash" ;;
        *) [ "$touched" != "$base" ] || fail "edit '$edit' does not change the re-run hash" ;;
    esac
done

echo "PASS"
