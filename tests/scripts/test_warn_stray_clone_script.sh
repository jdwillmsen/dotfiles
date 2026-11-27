#!/usr/bin/env bash
# shellcheck disable=SC2016  # the command fixtures are deliberately unexpanded shell syntax
# shellcheck disable=SC2088  # a literal tilde is the fixture: the hook must expand it, not the shell
# The hook is fed the JSON Claude Code sends a PreToolUse Bash hook and judged by its exit code and stdout. HOME points
# at a temp dir; the hook only reads command text, so nothing on disk needs to exist.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$here/home/private_dot_claude/hooks/executable_warn-stray-clone.sh"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$hook" ] || fail "warn-stray-clone.sh missing or not executable"
head -1 "$hook" | grep -qx '#!/usr/bin/env bash' || fail "hook needs the bash env shebang"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"
P="$H/projects"

run() {  # command [cwd]: sets OUT to the hook stdout; any non-zero exit fails the test
    local json rc=0
    json="$(python3 -I -c 'import json,sys; print(json.dumps({"session_id":"s","hook_event_name":"PreToolUse",
        "tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$1" "${2:-$P}")"
    OUT="$(printf '%s' "$json" | HOME="$H" "$hook")" || rc=$?
    [ "$rc" = 0 ] || fail "hook must always exit 0, got $rc for: $1" "$OUT"
}
warns() {  # description command [cwd]
    run "$2" "${3:-$P}"
    [ -n "$OUT" ] || fail "$1 should warn: $2"
    printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"] == "PreToolUse", d
assert "permissionDecision" not in d, "the hook must never decide, only warn"
assert d["additionalContext"].startswith("warn-stray-clone: "), d
assert "~/worktrees/" in d["additionalContext"], d' || fail "$1: bad output" "$OUT"
}
silent() {  # description command [cwd]
    run "$2" "${3:-$P}"
    [ -z "$OUT" ] || fail "$1 should be silent: $2" "$OUT"
}

# Canonical clones into a new top-level <owner>/<repo> stay silent, however the path is spelled.
silent "clone into canonical dir" 'git clone git@github.com:jdwlabs/platform.git ~/projects/jdwlabs/platform'
silent "clone with derived dest" 'git clone https://github.com/jdwlabs/platform' "$P/jdwlabs"
silent "clone after cd" 'cd ~/projects/jdwlabs && git clone --depth 1 -b main https://github.com/jdwlabs/apps.git'
silent "clone via \$HOME" 'git clone https://github.com/jdwlabs/apps "$HOME/projects/jdwlabs/apps"'
silent "clone with -C" 'git -C ~/projects/dotablaze-tech clone https://github.com/dotablaze-tech/site.git'
silent "gh repo clone canonical" 'gh repo clone jdwillmsen/career ~/projects/jdwillmsen/career'
silent "case-insensitive repo name" 'git clone https://github.com/jdwillmsen/GameOps ~/projects/jdwillmsen/gameops'

# Checkouts outside ~/projects are none of this hook's business.
silent "worktree in ~/worktrees" 'git worktree add ~/worktrees/jdwlabs/platform/feat/JDW-1-x -b feat/JDW-1-x origin/main' "$P/jdwlabs/platform"
silent "clone to /tmp" 'git clone https://github.com/jdwlabs/platform /tmp/platform'
silent "clone in scratch dir" 'git clone https://github.com/jdwlabs/platform' "$tmp/scratch"
silent "a projects sibling is not projects" 'git clone https://github.com/a/b ~/projects-old/a/b'

# Not a checkout at all.
silent "plain command" 'ls ~/projects'
silent "worktree list" 'git worktree list' "$P/jdwlabs/platform"
silent "word clone in an echo" 'echo "do not clone into ~/projects/x/y-copy"'
silent "git log mentioning clone" 'git log --grep clone'

# Ad-hoc copies under ~/projects warn.
warns "dated copy" 'git clone https://github.com/jdwillmsen/crew ~/projects/jdwillmsen/crew-a-2026-10-21'
warns "ticket-suffixed copy" 'git clone https://github.com/jdwillmsen/deployments jdw-deployments-map1521' "$P/jdwillmsen"
warns "copy inside a repo" 'git clone https://github.com/jdwlabs/platform tmp/platform' "$P/jdwlabs/platform"
warns "clone into the owner folder itself" 'git clone https://github.com/jdwlabs/platform .' "$P/jdwlabs"
warns "clone straight into projects" 'git clone https://github.com/jdwlabs/platform ~/projects/platform'
warns "gh repo clone copy" 'gh repo clone jdwillmsen/gameops ~/projects/jdwillmsen/gameops-jdw301'
warns "relative dest after cd" 'cd ~/projects/jdwillmsen && git clone git@github.com:jdwillmsen/crew.git crew-2'
warns "rtk-prefixed clone" 'rtk git clone https://github.com/jdwillmsen/crew ~/projects/jdwillmsen/crew-copy'

# Any worktree add under ~/projects warns, wherever it is run from.
warns "worktree inside the repo" 'git worktree add .claude/worktrees/x -b x' "$P/jdwillmsen/gameops"
warns "worktree as sibling" 'git -C ~/projects/jdwlabs/platform worktree add ../platform-fix -b fix/x origin/main'
warns "worktree after options" 'git worktree add -b feat/y --reason "agent" ~/projects/jdwlabs/platform-y origin/main' "$P/jdwlabs/platform"
warns "second command of a chain" 'git fetch origin && git worktree add ~/projects/jdwlabs/x -b x' "$P/jdwlabs/platform"
run 'git worktree add ../p2 -b b' "$P/jdwlabs/platform"
grep -q 'git -C ~/projects/jdwlabs/platform worktree add ~/worktrees/jdwlabs/platform/<branch>' <<<"$OUT" ||
    fail "worktree warning should name the repo it came from" "$OUT"
run 'git clone https://github.com/jdwillmsen/crew ~/projects/jdwillmsen/crew-x'
grep -q '~/worktrees/jdwillmsen/crew/<branch>' <<<"$OUT" || fail "clone warning should name owner and repo" "$OUT"

# Fails open: unparseable shell, garbage and empty input exit 0 silently.
silent "unbalanced quote" 'git clone "https://x/y ~/projects/a/b-c'
for bad in 'not json' '' '{"tool_input":{}}' '{"tool_input":{"command":"git clone"}}'; do
    out="$(printf '%s' "$bad" | HOME="$H" "$hook")" || fail "hook must exit 0 on bad input: $bad"
    [ -z "$out" ] || fail "bad input should print nothing: $bad" "$out"
done

# An escaped quote earlier in the command does not end the scan before the clone.
warns "clone after an escaped quote" 'git commit -m "say \"hi\"" && git clone https://github.com/a/b ~/projects/a/b-copy'

# The fast path tests the command only. A session in a worktree has "worktree" in its cwd and transcript path, and
# that alone must not start Python: a stub python that leaves a marker proves it never ran.
mkdir -p "$tmp/stubpy"
for py in python3 python; do
    printf '#!/usr/bin/env bash\ntouch "%s/python-ran"\nexit 1\n' "$tmp" >"$tmp/stubpy/$py"
    chmod +x "$tmp/stubpy/$py"
done
wt_cwd="$H/worktrees/jdwlabs/platform/feat/JDW-1-clone-fix"
fixture="{\"session_id\":\"s\",\"transcript_path\":\"$H/.claude/projects/-home-worktrees-clone/s.jsonl\",\"cwd\":\"$wt_cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\",\"description\":\"List files\"}}"
printf '%s' "$fixture" | HOME="$H" PATH="$tmp/stubpy:$PATH" "$hook" >/dev/null
[ ! -e "$tmp/python-ran" ] || fail "fast path started python for a command with no clone or worktree"
printf '%s' "${fixture/ls -la/git worktree list}" | HOME="$H" PATH="$tmp/stubpy:$PATH" "$hook" >/dev/null
[ -e "$tmp/python-ran" ] || fail "the stub check is vacuous: a worktree command should reach python"

# And it stays cheap: a hundred such calls in well under the hook budget.
start=$(date +%s%N)
for _ in $(seq 100); do printf '%s' "$fixture" | HOME="$H" "$hook" >/dev/null; done
ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ "$ms" -lt 1500 ] || fail "fast path too slow: ${ms}ms for 100 calls"

shellcheck -s bash "$hook"
echo "PASS"
