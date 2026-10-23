#!/usr/bin/env bash
# shellcheck disable=SC2016  # the command fixtures are deliberately unexpanded shell syntax
# The hook is fed the JSON Claude Code sends a PreToolUse hook, and judged by its exit code and stderr alone. HOME
# points at a temp dir so nothing here touches the real state or policy files.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$here/home/private_dot_claude/hooks/executable_guard-delivery-state.sh"
bash="$(command -v bash)"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$hook" ] || fail "guard-delivery-state.sh missing or not executable"
head -1 "$hook" | grep -qx '#!/usr/bin/env bash' || fail "hook needs the bash env shebang"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"
mkdir -p "$H/.local/state/merge-captain" "$H/.local/state/agent-eval" "$H/.config/agents" "$tmp/work"
ln -s "$H/.local/state/merge-captain" "$tmp/merge-captain-link"
errf="$tmp/err"

payload() {  # tool key value [cwd]: the hook JSON, escaped by a real encoder
    python3 -I - "$@" <<'PY'
import json, sys
tool, key, value = sys.argv[1:4]
cwd = sys.argv[4] if len(sys.argv) > 4 else "/tmp"
print(json.dumps({"session_id": "s", "cwd": cwd, "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": {key: value, "content": "x"} if key == "file_path" else {key: value}}))
PY
}
blocked() {  # description, tool, key, value [cwd]
    local what="$1"
    shift
    payload "$@" >"$tmp/in"
    run_hook_stdin <"$tmp/in"
    [ "$rc" = 2 ] || fail "$what should be blocked, exit $rc" "$(cat "$errf")"
    grep -q '^guard-delivery-state: blocked' "$errf" || fail "$what: no explanation on stderr" "$(cat "$errf")"
    [ ! -s "$tmp/out" ] || fail "$what: a block must not print on stdout"
}
allowed() {
    local what="$1"
    shift
    payload "$@" >"$tmp/in"
    run_hook_stdin <"$tmp/in"
    [ "$rc" = 0 ] || fail "$what should be allowed, exit $rc" "$(cat "$errf")"
    [ ! -s "$errf" ] || fail "$what: allowed calls are silent" "$(cat "$errf")"
}
run_hook_stdin() {
    rc=0
    env -i HOME="$H" PATH="${HOOK_PATH:-/usr/bin:/bin}" "$bash" "$hook" >"$tmp/out" 2>"$errf" || rc=$?
}

S="$H/.local/state"
C="$H/.config/agents"

# ── Write, Edit and MultiEdit on the protected paths ──
for tool in Write Edit MultiEdit; do
    blocked "$tool on the review record" "$tool" file_path "$S/merge-captain/reviews.jsonl"
    blocked "$tool on the outcome ledger" "$tool" file_path "$S/agent-eval/outcomes.jsonl"
    blocked "$tool on the assignment ledger" "$tool" file_path "$S/agent-eval/assignments.jsonl"
    blocked "$tool on the kill switch" "$tool" file_path "$S/merge-captain/PAUSED"
    for f in change-risk lanes merge-captain; do
        blocked "$tool on $f.toml" "$tool" file_path "$C/$f.toml"
    done
done
blocked "a .. path" Write file_path "$S/x/../merge-captain/reviews.jsonl"
blocked "a symlinked path" Write file_path "$tmp/merge-captain-link/reviews.jsonl"
blocked "a not-yet-existing nested path" Write file_path "$S/agent-eval/sub/new.jsonl"
# ── ...and leaves every other path alone ──
allowed "a scratch file" Write file_path "/tmp/notes.txt"
allowed "the repo copy of the policy" Edit file_path "$H/worktrees/dotfiles/home/dot_config/agents/merge-captain.toml"
allowed "the repo copy of the tool" Edit file_path "$H/worktrees/dotfiles/home/dot_local/bin/executable_merge-captain"
allowed "another file in agents/" Write file_path "$C/other.toml"
allowed "another state dir" Write file_path "$S/agent-metrics/quota.jsonl"
allowed "a lookalike dir" Write file_path "$S/merge-captain-notes/x"

# ── Bash: redirects, tee, sed -i, cp, mv ──
blocked "append redirect" Bash command 'echo "{}" >> ~/.local/state/merge-captain/reviews.jsonl'
blocked "truncating redirect" Bash command "echo x > $S/agent-eval/outcomes.jsonl"
blocked "redirect via \$HOME" Bash command 'echo x > $HOME/.local/state/agent-eval/outcomes.jsonl'
blocked "redirect via braces" Bash command 'echo x >> "${HOME}/.config/agents/lanes.toml"'
blocked "redirect without a space" Bash command 'echo x >>~/.config/agents/change-risk.toml'
blocked "stderr redirect" Bash command 'foo 2> ~/.local/state/merge-captain/log.jsonl'
blocked "tee" Bash command 'printf x | tee ~/.config/agents/lanes.toml'
blocked "tee -a" Bash command 'echo x | tee -a ~/.local/state/agent-eval/assignments.jsonl'
blocked "sed -i" Bash command "sed -i 's/a/b/' ~/.config/agents/change-risk.toml"
blocked "sed -i with a suffix" Bash command "sed -i.bak 's/a/b/' ~/.config/agents/merge-captain.toml"
blocked "sed -ni" Bash command "sed -ni 's/a/b/p' ~/.local/state/merge-captain/reviews.jsonl"
blocked "cp onto policy" Bash command 'cp /tmp/x ~/.config/agents/merge-captain.toml'
blocked "cp onto state" Bash command "cp /tmp/x $S/merge-captain/reviews.jsonl"
blocked "cp -t" Bash command "cp -t $S/agent-eval /tmp/x"
blocked "mv onto policy" Bash command 'mv /tmp/x ~/.config/agents/lanes.toml'
blocked "mv away from state" Bash command "mv $S/agent-eval/outcomes.jsonl /tmp/gone"
blocked "rm" Bash command "rm $S/merge-captain/reviews.jsonl"
blocked "after &&" Bash command "ls && echo x >> $S/merge-captain/log.jsonl"
blocked "after a pipe and ;" Bash command "true; cat /tmp/x | tee $S/agent-eval/outcomes.jsonl"
blocked "inside bash -c" Bash command "bash -c 'echo x >> $S/merge-captain/reviews.jsonl'"
blocked "second line of a script" Bash command $'set -e\ncat /tmp/x\necho x >> '"$S/merge-captain/reviews.jsonl"
blocked "dd of=" Bash command "dd if=/tmp/x of=$C/lanes.toml"
blocked "with a leading env var" Bash command "FOO=1 sed -i s/a/b/ $C/lanes.toml"
blocked "sudo tee" Bash command "echo x | sudo tee $C/lanes.toml"
blocked "relative redirect from inside the state dir" Bash command 'echo x >> reviews.jsonl' "$S/merge-captain"
blocked "relative sed -i from inside agents/" Bash command "sed -i s/a/b/ lanes.toml" "$C"
blocked "dot-dot redirect" Bash command "echo x > $S/x/../merge-captain/reviews.jsonl"
blocked "symlink redirect" Bash command "echo x > $tmp/merge-captain-link/reviews.jsonl"
# ── ...reading them, and everything else, is fine ──
allowed "cat the record" Bash command 'cat ~/.local/state/merge-captain/reviews.jsonl'
allowed "grep the policy" Bash command "grep -n tier $C/lanes.toml"
allowed "sed without -i" Bash command "sed -n 1,5p $C/change-risk.toml"
allowed "sed -n -e" Bash command "sed -n -e 's/a/b/p' $C/lanes.toml"
allowed "cp out of state" Bash command "cp $S/agent-eval/outcomes.jsonl /tmp/backup.jsonl"
allowed "cp to a scratch dir" Bash command "cp -r $S/merge-captain /tmp/copy"
allowed "diff" Bash command "diff /tmp/a $C/lanes.toml"
allowed "running the tool" Bash command 'merge-captain run --dry-run && merge-captain status'
allowed "pause through the tool" Bash command 'merge-captain pause --reason "release freeze"'
allowed "agent-eval report" Bash command 'agent-eval report --window 7d > /tmp/report.txt'
allowed "redirect to scratch while naming state" Bash command "ls $S/merge-captain > /tmp/ls.txt"
allowed "stderr dup" Bash command "merge-captain status 2>&1 | head"
allowed "a commit message" Bash command 'git commit -m "fix(merge-captain): tighten > the gate"'
allowed "unrelated" Bash command 'ls -la && echo done > /tmp/done'
allowed "relative redirect from elsewhere" Bash command 'echo x >> reviews.jsonl' "$tmp/work"
allowed "sed -i on a repo file" Bash command "sed -i s/a/b/ $H/worktrees/dotfiles/home/dot_config/agents/lanes.toml"
allowed "cwd in the state dir, harmless command" Bash command 'ls' "$S/merge-captain"

# ── Tools the hook is not about, and malformed input ──
allowed "a Read of the state" Read file_path "$S/merge-captain/reviews.jsonl"
rc=0
printf 'not json at all merge-captain' | env -i HOME="$H" PATH=/usr/bin:/bin bash "$hook" 2>"$errf" || rc=$?
[ "$rc" = 0 ] || fail "malformed input must not block" "$(cat "$errf")"
rc=0
printf '' | env -i HOME="$H" PATH=/usr/bin:/bin bash "$hook" 2>"$errf" || rc=$?
[ "$rc" = 0 ] || fail "empty input must not block"

# ── The hot path starts no process: with an empty PATH only builtins can run ──
HOOK_PATH="$tmp/empty"
mkdir -p "$tmp/empty"
allowed "an ordinary Bash call, builtins only" Bash command 'ls -la /tmp'
allowed "an ordinary Write, builtins only" Write file_path /tmp/x
allowed "an ordinary Edit, builtins only" Edit file_path "$H/projects/app/src/main.ts"
unset HOOK_PATH

# ── A large payload that names a protected word is still judged quickly and correctly ──
big="$tmp/big.json"
python3 -I - "$big" "$S" <<'PY'
import json, sys
body = "merge-captain " * 40000
json.dump({"cwd": "/tmp", "tool_name": "Write", "tool_input": {"file_path": "/tmp/ok.txt", "content": body}}, open(sys.argv[1], "w"))
PY
start=$SECONDS
rc=0
env -i HOME="$H" PATH=/usr/bin:/bin bash "$hook" <"$big" 2>"$errf" || rc=$?
[ "$rc" = 0 ] || fail "a large harmless Write was blocked" "$(cat "$errf")"
[ $((SECONDS - start)) -lt 5 ] || fail "a large payload took $((SECONDS - start))s"
python3 -I - "$big" "$S" <<'PY'
import json, sys
body = "merge-captain " * 40000
json.dump({"cwd": "/tmp", "tool_name": "Write", "tool_input": {"content": body, "file_path": sys.argv[2] + "/merge-captain/reviews.jsonl"}}, open(sys.argv[1], "w"))
PY
rc=0
env -i HOME="$H" PATH=/usr/bin:/bin bash "$hook" <"$big" 2>"$errf" || rc=$?
[ "$rc" = 2 ] || fail "a large Write to the record was not blocked (file_path after content)" "$(cat "$errf")"

# ── XDG overrides move the protected paths with them ──
mkdir -p "$tmp/xdg/state/merge-captain"
payload Write file_path "$tmp/xdg/state/merge-captain/reviews.jsonl" | env -i HOME="$H" XDG_STATE_HOME="$tmp/xdg/state" \
    PATH=/usr/bin:/bin bash "$hook" 2>"$errf" && fail "an XDG_STATE_HOME state dir was not protected"
grep -q 'blocked Write' "$errf" || fail "no explanation for the XDG case" "$(cat "$errf")"

echo "test_guard_delivery_state_script: OK"
