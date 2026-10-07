#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# stream decides which Jira project and worktree namespace every other helper
# uses, so its resolution rules are pinned here against real git repos, and its
# GitHub view against a stub gh.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
stream="$here/home/dot_local/bin/executable_stream"
map="$here/home/dot_config/streams.json"
trigger="$here/home/run_onchange_after_56-generate-claude-jira.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$stream" ] || fail "stream missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$stream" || fail "stream does not parse"
python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$map" || fail "streams.json is not JSON"

# The harness owns teardown: its EXIT trap sweeps CHEZ_TMP_ROOT, and a second
# trap here would replace it and leak the rendered-config sandbox.
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
tmp="$(mktemp -d "$CHEZ_TMP_ROOT/stream.XXXXXXXX")"
fx="$tmp/home"
stubs="$tmp/bin"
mkdir -p "$fx/.config" "$stubs" "$tmp/repos"
cp "$map" "$fx/.config/streams.json"

mkrepo() {  # $1 name, $2 optional origin url
    git init -q "$tmp/repos/$1"
    git -C "$tmp/repos/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    [ -z "${2:-}" ] || git -C "$tmp/repos/$1" remote add origin "$2"
}
run() {  # args → sets $out, $rc; runs in $cwd
    set +e
    out="$(cd "${cwd:-$tmp}" && HOME="$fx" PATH="$stubs:/usr/bin:/bin" STUB_LOG="$tmp/log" \
        STUB_GH="${STUB_GH:-ok}" python3 "$stream" "$@" 2>"$tmp/stderr")"
    rc=$?
    set -e
}
expect() {  # $1 expected stdout, $2 label
    [ "$rc" -eq 0 ] && [ "$out" = "$1" ] || fail "$2: expected '$1', got rc=$rc '$out'" "$(cat "$tmp/stderr")"
}

# ── slug: every remote URL shape yields owner/repo ──
mkrepo platform git@github.com:jdwlabs/platform.git
mkrepo gameops https://github.com/jdwillmsen/gameops
mkrepo career https://github.com/jdwillmsen/career.git/
mkrepo dota ssh://git@github.com:22/dotablaze-tech/platform.git
mkrepo fork git@github.com:kunchenguid/no-mistakes.git
mkrepo orphan

cwd="$tmp/repos/platform" run slug;  expect "jdwlabs/platform" "ssh shorthand remote"
cwd="$tmp/repos/gameops" run slug;   expect "jdwillmsen/gameops" "https remote without .git"
cwd="$tmp/repos/career" run slug;    expect "jdwillmsen/career" "https remote with .git and trailing slash"
cwd="$tmp/repos/dota" run slug;      expect "dotablaze-tech/platform" "ssh:// remote with a port"
cwd="$tmp/repos/orphan" run slug;    expect "orphan" "no remote falls back to the basename"
run slug "$tmp/repos/platform";      expect "jdwlabs/platform" "slug takes a path argument"

# A linked worktree's own folder name must not leak into the slug.
git -C "$tmp/repos/platform" worktree add -q -b feat/x "$tmp/elsewhere" >/dev/null 2>&1
cwd="$tmp/elsewhere" run slug;       expect "jdwlabs/platform" "slug from inside a linked worktree"

# stream.owner is the explicit exception for a fork whose origin is upstream.
git -C "$tmp/repos/fork" config stream.owner jdwillmsen
cwd="$tmp/repos/fork" run slug;      expect "jdwillmsen/no-mistakes" "stream.owner overrides the remote owner"
git -C "$tmp/repos/orphan" config stream.owner jdwillmsen
cwd="$tmp/repos/orphan" run slug;    expect "jdwillmsen/orphan" "stream.owner applies with no remote"
git -C "$tmp/repos/orphan" config --unset stream.owner

cwd="$tmp" run slug
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "slug outside a repo must be a structured error" "$out"

# ── key: owner picks the project, repoOverrides wins ──
cwd="$tmp/repos/platform" run key;   expect "JDWLABS" "jdwlabs key"
cwd="$tmp/repos/gameops" run key;    expect "JDW" "jdwillmsen key"
cwd="$tmp/repos/career" run key;     expect "CAREER" "career override"
cwd="$tmp/repos/dota" run key;       expect "DOTA" "dotablaze-tech key"
cwd="$tmp/repos/fork" run key;       expect "JDW" "overridden owner picks its stream"
cwd="$tmp/repos/orphan" run key
[ "$rc" -eq 1 ] && grep -q '^error: .*not a known stream' <<<"$out" || fail "an ownerless repo must not guess a project" "$out"
grep -q '^help\[' <<<"$out" || fail "unknown-stream error should say what to do next" "$out"

# ── no args: live content, not help text ──
run
[ "$rc" -eq 0 ] || fail "bare stream should exit 0" "$out"
grep -q '^streams\[3\]{stream,jira,overrides}:' <<<"$out" || fail "bare stream should list the three streams" "$out"
grep -q 'jdwillmsen,JDW,career=CAREER' <<<"$out" || fail "bare stream should show overrides" "$out"
grep -q '^help\[' <<<"$out" || fail "bare stream should offer next steps" "$out"
cwd="$tmp/repos/gameops" run
grep -q '^here: jdwillmsen/gameops' <<<"$out" && grep -q '^here_jira: JDW' <<<"$out" \
    || fail "bare stream inside a repo should say where it is" "$out"

for sub in "" slug key jira-config status; do
    # shellcheck disable=SC2086  # an empty $sub must vanish, not become an empty argument
    run $sub --help
    [ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out" || fail "'stream $sub --help' should print usage" "$out"
done
run --version
[ "$rc" -eq 0 ] && [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version should print a bare version" "$out"
run bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown command' <<<"$out" || fail "unknown command must be a usage error" "$out"
run key --bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown flag --bogus' <<<"$out" || fail "unknown flags must be rejected, not treated as a path" "$out"
run jira-config --bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown flag --bogus' <<<"$out" || fail "jira-config must reject unknown flags" "$out"

# ── a missing or broken map is an error, never an empty answer ──
mv "$fx/.config/streams.json" "$tmp/streams.bak"
cwd="$tmp/repos/platform" run key
[ "$rc" -eq 1 ] && grep -q '^error: .*streams.json' <<<"$out" || fail "missing map must be a structured error" "$out"
echo '{"streams": {"x": {"jira": "lower"}}}' >"$fx/.config/streams.json"
run
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "an invalid key in the map must be rejected" "$out"
cp "$tmp/streams.bak" "$fx/.config/streams.json"

# ── jira-config: generated allowlist for cj and the statusline ──
cfg="$fx/.config/claude-jira.json"
run jira-config
[ "$rc" -eq 0 ] || fail "jira-config should exit 0" "$out"
python3 - "$out" <<'PY' || fail "jira-config printed the wrong document" "$out"
import json, sys
j = json.loads(sys.argv[1])
assert j["siteBase"] == "https://jdwillmsen.atlassian.net", j
assert j["projects"] == ["CAREER", "DOTA", "JDW", "JDWLABS"], j
assert j["generatedFrom"] == "streams.json", j
PY
[ ! -e "$cfg" ] || fail "jira-config without --write must not create the file"
run jira-config --write
[ "$rc" -eq 0 ] && grep -q '^status: written' <<<"$out" && [ -f "$cfg" ] || fail "--write should create the file" "$out"
run jira-config --write
grep -q '^status: unchanged' <<<"$out" || fail "a second --write should be a no-op" "$out"

# A config someone wrote by hand names an employer's site; it is not ours to replace.
echo '{"siteBase": "https://work.example.net", "projects": ["ABC"]}' >"$cfg"
run jira-config --write
[ "$rc" -eq 0 ] && grep -q '^status: kept' <<<"$out" || fail "a hand-written config must be kept" "$out"
grep -q 'work.example.net' "$cfg" || fail "a hand-written config was overwritten"
rm -f "$cfg"

# ── the chezmoi trigger regenerates the allowlist only on a personal machine ──
grep -q 'include "dot_config/streams.json" | sha256sum' "$trigger" \
    || fail "trigger must re-run when the stream map changes"
chez_render "$(chez_init personal)" "$trigger" >"$tmp/trigger-personal.sh"
chez_render "$(chez_init work)" "$trigger" >"$tmp/trigger-work.sh"
shellcheck -s bash "$tmp/trigger-personal.sh" "$tmp/trigger-work.sh"
mkdir -p "$fx/.local/bin"
cp "$stream" "$fx/.local/bin/stream"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-work.sh" >/dev/null
[ ! -e "$cfg" ] || fail "a work machine must not get the personal Jira allowlist"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null
[ -f "$cfg" ] || fail "trigger did not generate claude-jira.json on a personal machine"
rm -rf "$fx/.local"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null \
    || fail "trigger must exit 0 when stream is not installed yet"

echo "PASS"
