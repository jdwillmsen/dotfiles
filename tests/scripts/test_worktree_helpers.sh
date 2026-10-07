#!/usr/bin/env bash
# shellcheck disable=SC2016  # the `$` in these patterns are literal text being
# matched inside the target script, not expansions this file wants evaluated
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/private_dot_claude/scripts/worktree-helpers.sh"

[ -f "$script" ] || { echo "FAIL: helper script not tracked in source state"; exit 1; }
shellcheck -s bash "$script"
bash -n "$script"

# The rc file is the only thing that turns this file into working commands; the
# suite that shipped before it was wired had every function silently undefined.
grep -q 'worktree-helpers.sh' "$here/home/dot_bashrc" \
    || { echo "FAIL: .bashrc does not source the helpers"; exit 1; }
if grep -q 'worktree-helpers.sh' "$here/home/dot_zshrc"; then
    echo "FAIL: .zshrc sources a bash-only script"; exit 1
fi

grep -q 'BASH_VERSION' "$script" || { echo "FAIL: no non-bash guard"; exit 1; }

# Ancestry alone cannot see a squash merge, so wtclean must consult the forge.
grep -q '__wt_branch_merged' "$script" || { echo "FAIL: no merge-detection helper"; exit 1; }
grep -qF 'gh pr list --head "$branch" --state merged' "$script" \
    || { echo "FAIL: merge check must ask the forge for merged PRs"; exit 1; }

# A silent no-op on closed stdin reads as success to any non-interactive caller.
grep -q '! -t 0' "$script" || { echo "FAIL: wtclean must detect a non-tty"; exit 1; }

# Porcelain emits `worktree <path>` before `branch <ref>`. Carrying the path
# forward is what keeps wtd from force-removing the *next* worktree.
grep -q '/\^worktree / { path=\$2 }' "$script" \
    || { echo "FAIL: wtd path lookup must carry path forward from the worktree line"; exit 1; }

# Behavioural check: resolve a branch to its worktree path through the same awk
# wtd uses, against real porcelain output with two worktrees present.
tmp="$(mktemp -d)"
git init -q "$tmp/repo"
git -C "$tmp/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$tmp/repo" worktree add -q -b wt-one "$tmp/one" >/dev/null 2>&1
git -C "$tmp/repo" worktree add -q -b wt-two "$tmp/two" >/dev/null 2>&1
resolved=$(git -C "$tmp/repo" worktree list --porcelain | awk -v b="wt-one" '
    /^worktree / { path=$2 }
    /^branch / && $2 == "refs/heads/"b { print path; exit }
')
case "$resolved" in
    *one) ;;
    *) echo "FAIL: wt-one resolved to '$resolved', expected the 'one' worktree"; exit 1 ;;
esac
rm -rf "$tmp"

# Behavioural check: the project namespace is <owner>/<repo> from the origin
# remote, so two owners' same-named repos cannot share a worktree folder.
tmp="$(mktemp -d)"
slug_in() { (cd "$1" && bash -c '. "$0"; __wt_project' "$script"); }
mkrepo() {
    git init -q "$tmp/$1"
    git -C "$tmp/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    [ -z "${2:-}" ] || git -C "$tmp/$1" remote add origin "$2"
}
mkrepo a git@github.com:jdwlabs/platform.git
mkrepo b https://github.com/dotablaze-tech/platform
mkrepo c https://github.com/jdwillmsen/career.git/
mkrepo d ssh://git@github.com:22/jdwillmsen/gameops.git
mkrepo e
mkrepo f git@github.com:kunchenguid/no-mistakes.git
git -C "$tmp/f" config stream.owner jdwillmsen
git -C "$tmp/a" worktree add -q -b wt-inside "$tmp/inside" >/dev/null 2>&1

stream_bin="$here/home/dot_local/bin/executable_stream"
for case in "a:jdwlabs/platform" "b:dotablaze-tech/platform" "c:jdwillmsen/career" \
    "d:jdwillmsen/gameops" "e:e" "f:jdwillmsen/no-mistakes" "inside:jdwlabs/platform"; do
    dir="${case%%:*}" want="${case#*:}"
    got="$(slug_in "$tmp/$dir")"
    [ "$got" = "$want" ] || { echo "FAIL: __wt_project in $dir gave '$got', expected '$want'"; exit 1; }
    # Two implementations of one rule: any disagreement sends a worktree and its
    # ticket key to different streams.
    py="$(cd "$tmp/$dir" && python3 "$stream_bin" slug)"
    [ "$py" = "$got" ] || { echo "FAIL: stream slug '$py' disagrees with __wt_project '$got' in $dir"; exit 1; }
done

(cd "$tmp/a" && WT_BASE="$tmp/wt" bash -c '. "$0"; gwta fix/thing' "$script" >/dev/null 2>&1)
[ -d "$tmp/wt/jdwlabs/platform/fix/thing" ] \
    || { echo "FAIL: gwta did not create the worktree under <owner>/<repo>"; exit 1; }
# From inside a linked worktree the namespace must still be the repo's.
(cd "$tmp/inside" && WT_BASE="$tmp/wt" bash -c '. "$0"; gwta fix/nested' "$script" >/dev/null 2>&1)
[ -d "$tmp/wt/jdwlabs/platform/fix/nested" ] \
    || { echo "FAIL: gwta from a linked worktree used the wrong namespace"; exit 1; }
rm -rf "$tmp"

echo "PASS"
