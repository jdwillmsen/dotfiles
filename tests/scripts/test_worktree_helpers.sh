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

echo "PASS"
