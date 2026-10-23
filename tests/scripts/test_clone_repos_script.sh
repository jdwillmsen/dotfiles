#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_local/bin/executable_clone-repos"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$script" ] || fail "clone-repos not tracked in source state"
shellcheck -s bash "$script"
bash -n "$script"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# HOME is the sandbox so a default path that slipped through could only ever
# resolve inside it, never to the real ~/projects.
export HOME="$tmp/home"
mkdir -p "$HOME"

# Local bare repos stand in for GitHub, so the git fallback runs a real clone.
remotes="$tmp/remotes"
mkrepo() {
    git init -q "$tmp/seed"
    git -C "$tmp/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    mkdir -p "$remotes/${1%/*}"
    git clone -q --bare "$tmp/seed" "$remotes/$1.git"
    rm -rf "$tmp/seed"
}
mkrepo acme/one
mkrepo acme/two
mkrepo Other/three
export CLONE_REPOS_URL_BASE="$remotes"

# gh is stubbed to be logged out by default, which selects the git fallback.
stub="$tmp/stub"
mkdir -p "$stub"
cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [ "$1 $2" = "auth status" ]; then exit "${GH_AUTH_RC:-1}"; fi
if [ "$1 $2" = "repo clone" ]; then git clone -q "$CLONE_REPOS_URL_BASE/$3.git" "$4"; exit; fi
exit 1
EOF
chmod 755 "$stub/gh"
export PATH="$stub:$PATH" GH_LOG="$tmp/gh.log"

list="$tmp/repos.tsv"
printf '%s\n' \
    '# comment' \
    '' \
    $'default-group\tcore' \
    $'acme/one\tacme/one\tcore,acme' \
    $'acme/two\tacme/two\tacme' \
    $'Other/three\tacme/three\tother' >"$list"
root="$tmp/root"
run() { bash "$script" --list "$list" --root "$root" "$@"; }

# Dry run clones nothing and reports what would be cloned for the default group.
out="$(run --dry-run)" || fail "dry run must exit 0: $out"
grep -qx '  acme/one,acme/one,would-clone' <<<"$out" || fail "dry run row missing: $out"
grep -q 'acme/two' <<<"$out" && fail "default group must be core only: $out"
grep -qx 'summary: would_clone=1 exists=0 failed=0 conflict=0 total=1' <<<"$out" || fail "dry summary: $out"
[ ! -e "$root" ] || fail "dry run created $root"

# A real run clones via git when gh is logged out.
out="$(run)" || fail "clone must exit 0: $out"
grep -qx 'via: git' <<<"$out" || fail "logged-out gh must fall back to git: $out"
grep -qx '  acme/one,acme/one,cloned' <<<"$out" || fail "clone row: $out"
[ "$(git -C "$root/acme/one" rev-parse --is-inside-work-tree)" = true ] || fail "acme/one not cloned"

# Re-running is a no-op that reports the clone, and leaves its contents alone.
echo dirty >"$root/acme/one/local-work"
head_before="$(git -C "$root/acme/one" rev-parse HEAD)"
out="$(run)" || fail "rerun must exit 0: $out"
grep -qx '  acme/one,acme/one,exists' <<<"$out" || fail "rerun row: $out"
grep -qx 'summary: cloned=0 exists=1 failed=0 conflict=0 total=1' <<<"$out" || fail "rerun summary: $out"
[ -f "$root/acme/one/local-work" ] || fail "rerun touched an existing clone"
[ "$(git -C "$root/acme/one" rev-parse HEAD)" = "$head_before" ] || fail "rerun moved HEAD"

# all selects every row; the slug's case need not match its path.
out="$(run --group all)" || fail "all must exit 0: $out"
grep -qx '  Other/three,acme/three,cloned' <<<"$out" || fail "mixed-case slug: $out"
grep -qx 'summary: cloned=2 exists=1 failed=0 conflict=0 total=3' <<<"$out" || fail "all summary: $out"

# gh is used once it reports a login.
rm -rf "$root/acme/two"
out="$(GH_AUTH_RC=0 run --group acme)" || fail "gh clone must exit 0: $out"
grep -qx 'via: gh' <<<"$out" || fail "logged-in gh must be used: $out"
grep -qx 'repo clone acme/two .*' "$GH_LOG" || fail "gh repo clone not called: $(cat "$GH_LOG")"

# A path held by something else is a conflict: reported, untouched, exit 1.
rm -rf "$root/acme/two"
mkdir -p "$root/acme/two" && echo keep >"$root/acme/two/notes.txt"
git -C "$root/acme/three" remote set-url origin https://github.com/someone/else.git
rc=0; out="$(run --group acme,other)" || rc=$?
[ "$rc" = 1 ] || fail "conflict must exit 1, got $rc: $out"
grep -qx '  acme/two,acme/two,conflict' <<<"$out" || fail "non-repo conflict row: $out"
grep -qx '  Other/three,acme/three,conflict' <<<"$out" || fail "wrong-origin conflict row: $out"
grep -q '^errors\[2\]{slug,error}:' <<<"$out" || fail "conflicts must be listed: $out"
[ "$(cat "$root/acme/two/notes.txt")" = keep ] || fail "conflict path was modified"

# A failed clone still processes the rest and exits 1 with the git error.
printf '%s\n' $'acme/missing\tacme/missing\tbad' $'acme/one\tacme/one2\tbad' >"$tmp/bad.tsv"
rc=0; out="$(bash "$script" --list "$tmp/bad.tsv" --root "$root" --group bad)" || rc=$?
[ "$rc" = 1 ] || fail "failed clone must exit 1, got $rc: $out"
grep -qx '  acme/missing,acme/missing,failed' <<<"$out" || fail "failed row: $out"
grep -qx '  acme/one,acme/one2,cloned' <<<"$out" || fail "a failure must not stop later clones: $out"
[ ! -e "$root/acme/missing" ] || fail "failed clone left a directory"

# A value with a TOON delimiter must be quoted or the line misparses.
printf '%s\n' $'acme/one\tacme/one\todd:tag' >"$tmp/odd.tsv"
out="$(bash "$script" --list "$tmp/odd.tsv" --root "$root" --group 'odd:tag' --dry-run)" || fail "odd tag dry run: $out"
grep -qx 'groups: "odd:tag"' <<<"$out" || fail "value with ':' must be quoted: $out"

# Usage errors exit 2 and name the known groups.
rc=0; out="$(run --group nope)" || rc=$?
[ "$rc" = 2 ] || fail "unknown group must exit 2, got $rc"
grep -q '^error: .*known: all core acme other' <<<"$out" || fail "unknown group message: $out"
rc=0; out="$(run --bogus)" || rc=$?
[ "$rc" = 2 ] || fail "unknown flag must exit 2, got $rc"

# Rows that would escape the root, or collide, are rejected before any clone.
for bad in $'acme/x\t../escape\tcore' $'acme/x\t/abs\tcore' $'not-a-slug\tx\tcore' \
    $'acme/x\tacme/ONE\tcore'; do
    printf '%s\n' $'acme/one\tacme/one\tcore' "$bad" >"$tmp/invalid.tsv"
    rc=0; out="$(bash "$script" --list "$tmp/invalid.tsv" --root "$tmp/never" --group all)" || rc=$?
    [ "$rc" = 1 ] || fail "invalid row '$bad' must exit 1, got $rc: $out"
    [ ! -e "$tmp/never" ] || fail "invalid row '$bad' still cloned something"
done

# A missing list is a structured error, and defaults resolve under HOME.
rc=0; out="$(bash "$script")" || rc=$?
[ "$rc" = 1 ] || fail "missing list must exit 1, got $rc"
grep -qx 'error: no repo list at ~/.config/clone-repos/repos.tsv' <<<"$out" || fail "missing list: $out"
mkdir -p "$HOME/.config/clone-repos" && cp "$list" "$HOME/.config/clone-repos/repos.tsv"
out="$(bash "$script" --dry-run)" || fail "default list dry run: $out"
grep -qx 'root: ~/projects' <<<"$out" || fail "default root must be ~/projects: $out"

echo "PASS"
