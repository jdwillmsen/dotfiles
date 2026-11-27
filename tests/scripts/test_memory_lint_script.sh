#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# memory-lint reads a projects tree and must never change it, so every case
# runs against a fixture tree whose contents are hashed before and after.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
lint="$here/home/dot_local/bin/executable_memory-lint"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$lint" ] || fail "memory-lint missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$lint" || fail "memory-lint does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
# The fixture itself lives under the system temp dir, so /tmp must not count
# as a throwaway prefix here; a made-up prefix stands in for it.
export MEMORY_LINT_TMP_PREFIXES=/fixture-tmp
root="$tmp/projects"
mkdir -p "$root"

enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# project <cwd> [transcript-cwd]: a project dir named after <cwd>, with a
# transcript recording that cwd unless "none" is given.
project() {
    local dir
    dir="$root/$(enc "$1")"
    mkdir -p "$dir/memory"
    if [ "${2:-}" != none ]; then
        printf '{"type":"user","cwd":"%s"}\n' "$1" >"$dir/s1.jsonl"
    fi
    printf '%s\n' "$dir/memory"
}

long_note() {
    printf -- '---\nname: %s\n---\n' "$1"
    printf 'The world restart window is Sunday morning and players must be warned ten minutes ahead in chat. '
    printf 'Never run cheats on the survival world because achievements get disabled for every player there. '
    printf 'Coordinates on the seed copy match the live world so locations can be checked offline first. %s\n' "$2"
}

mkdir -p "$tmp/live" "$tmp/resolved"
live="$(project "$tmp/live")"
resolved="$(project "$tmp/resolved" none)"
scratch="$(project "/home/u/.t3/scratch/2026-11-01-chat-abc123" none)"
tmpdir="$(project "/fixture-tmp/run1")"
gone="$(project "$tmp/deleted-worktree")"
gone_unseen="$(project "$tmp/never-seen" none)"
mkdir -p "$root/$(enc "$tmp/empty")/memory"

long_note same-a "alpha" >"$live/shared-name.md"
printf 'Different text entirely about another topic.\n' >"$resolved/shared-name.md"
long_note copy-1 "alpha" >"$live/near-copy.md"
long_note copy-2 "beta" >"$resolved/renamed-copy.md"
long_note same-dir "gamma" >"$live/same-dir-copy.md"
printf 'Short note.\n' >"$tmpdir/short.md"
printf 'Short note.\n' >"$gone/short-too.md"
printf 'scratch note\n' >"$scratch/orphan.md"
printf 'unseen note\n' >"$gone_unseen/unseen.md"
for i in $(seq 51); do echo "- line $i"; done >"$live/MEMORY.md"
for i in $(seq 50); do echo "- line $i"; done >"$resolved/MEMORY.md"

snapshot() { (cd "$root" && find . -print0 | sort -z | xargs -0 ls -ld --time-style=+%s 2>/dev/null; find . -type f -print0 | sort -z | xargs -0 sha256sum); }
before="$(snapshot)"

out="$tmp/out"
run() {
    local want="$1" got=0
    shift
    "$lint" "$@" >"$out" 2>&1 || got=$?
    [ "$got" = "$want" ] || fail "memory-lint $* exited $got, want $want" "$(cat "$out")"
}

run 0 --help
grep -q -- "--index-lines" "$out" || fail "--help does not list --index-lines" "$(cat "$out")"
run 2 --frobnicate
grep -q "^error:" "$out" && grep -q "^code: 2" "$out" || fail "a bad flag is not a structured usage error" "$(cat "$out")"
run 2 --root "$root" --similarity 0
grep -q "^error:" "$out" || fail "--similarity 0 is accepted" "$(cat "$out")"
run 1 --root "$tmp/nope"
grep -q "^error: .*not found" "$out" || fail "a missing root is not a structured error" "$(cat "$out")"

run 0 --root "$root" --json
python3 - "$out" "$(enc "$tmp")" <<'PY' || fail "the JSON report is wrong" "$(cat "$out")"
import json, sys
r = json.load(open(sys.argv[1]))
pre = sys.argv[2]
orph = {o["dir"]: o["reason"] for o in r["orphans"]}
want = {
    "-home-u--t3-scratch-2026-11-01-chat-abc123": "scratch",
    "-fixture-tmp-run1": "tmp",
    pre + "-deleted-worktree": "missing",
    pre + "-never-seen": "missing",
}
assert orph == want, orph
assert r["empty_dirs"] == 1, r["empty_dirs"]
assert r["dirs"] == 6, r["dirs"]

pairs = {(d["kind"], frozenset((d["a"].split("/")[-1], d["b"].split("/")[-1]))) for d in r["duplicates"]}
assert ("name", frozenset({"shared-name.md"})) in pairs, pairs
assert ("content", frozenset({"near-copy.md", "renamed-copy.md"})) in pairs, pairs
# Same-dir copies and short notes are not duplicates across dirs.
assert ("content", frozenset({"near-copy.md", "same-dir-copy.md"})) not in pairs, pairs
assert not any("short.md" in p[1] for p in pairs), pairs
name_row = next(d for d in r["duplicates"] if d["kind"] == "name")
assert name_row["similarity"] == "n/a", name_row  # one side is too short to compare

longs = {x["dir"]: x["lines"] for x in r["long_indexes"]}
assert longs == {pre + "-live": 51}, longs
assert r["issues"] == len(r["orphans"]) + len(r["duplicates"]) + len(r["long_indexes"])
PY

run 0 --root "$root"
grep -q "^orphans\[4\]{dir,reason,notes,path}:" "$out" || fail "TOON orphans header is wrong" "$(cat "$out")"
grep -q "^long_indexes\[1\]" "$out" || fail "TOON long_indexes missing" "$(cat "$out")"
grep -q "memory-lint --full" "$out" || fail "no hint to list orphaned notes" "$(cat "$out")"
grep -q "orphan_notes" "$out" && fail "orphan_notes listed without --full" "$(cat "$out")" || true

run 0 --root "$root" --full
grep -q "^orphan_notes\[4\]{dir,note}:" "$out" || fail "--full does not list orphaned notes" "$(cat "$out")"

run 0 --root "$root" --index-lines 60
grep -q "^long_indexes\[0\]: none" "$out" || fail "--index-lines is ignored" "$(cat "$out")"

[ "$(snapshot)" = "$before" ] || fail "memory-lint changed the projects tree"

# A clean tree reports definitive empty states and no hints.
clean="$tmp/clean"
mkdir -p "$clean"
run 0 --root "$clean"
for k in orphans duplicates long_indexes; do
    grep -q "^$k\[0\]: none" "$out" || fail "clean tree: $k has no empty state" "$(cat "$out")"
done
grep -q "^issues: 0" "$out" || fail "clean tree reports issues" "$(cat "$out")"
grep -q "^help" "$out" && fail "clean tree prints hints" "$(cat "$out")" || true

if command -v shellcheck >/dev/null; then
    shellcheck "$0" || fail "shellcheck"
fi
echo "ok memory-lint"
