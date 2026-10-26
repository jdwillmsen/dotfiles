#!/usr/bin/env bash
# shellcheck disable=SC2016  # the command fixtures are deliberately unexpanded shell syntax
# shellcheck disable=SC2088  # a literal tilde is the fixture: the hook must expand it, not the shell
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
mkdir -p "$H/.config/merge-captain/tokens"
ln -s "$H/.local/state/merge-captain" "$tmp/merge-captain-link"
ln -s "$H/.config/merge-captain/tokens" "$tmp/merge-captain-tokens-link"
HOOK_ENVV=()
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
payload_json() {  # tool cwd tool_input-as-JSON: for a call that needs more than one key
    python3 -I - "$@" <<'PY'
import json, sys
tool, cwd, tool_input = sys.argv[1:4]
print(json.dumps({"session_id": "s", "cwd": cwd, "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": json.loads(tool_input)}))
PY
}
expect_blocked() {  # description; the call is in $tmp/in
    run_hook_stdin <"$tmp/in"
    [ "$rc" = 2 ] || fail "$1 should be blocked, exit $rc" "$(cat "$errf")"
    grep -q '^guard-delivery-state: blocked' "$errf" || fail "$1: no explanation on stderr" "$(cat "$errf")"
    [ ! -s "$tmp/out" ] || fail "$1: a block must not print on stdout"
}
expect_allowed() {
    run_hook_stdin <"$tmp/in"
    [ "$rc" = 0 ] || fail "$1 should be allowed, exit $rc" "$(cat "$errf")"
    [ ! -s "$errf" ] || fail "$1: allowed calls are silent" "$(cat "$errf")"
}
blocked() {  # description, tool, key, value [cwd]
    local what="$1"
    shift
    payload "$@" >"$tmp/in"
    expect_blocked "$what"
}
allowed() {
    local what="$1"
    shift
    payload "$@" >"$tmp/in"
    expect_allowed "$what"
}
blockedj() {  # description, tool, cwd, tool_input JSON
    local what="$1"
    shift
    payload_json "$@" >"$tmp/in"
    expect_blocked "$what"
}
allowedj() {
    local what="$1"
    shift
    payload_json "$@" >"$tmp/in"
    expect_allowed "$what"
}
run_hook_stdin() {
    rc=0
    env -i HOME="$H" PATH="${HOOK_PATH:-/usr/bin:/bin}" ${HOOK_ENVV[@]+"${HOOK_ENVV[@]}"} "$bash" "$hook" >"$tmp/out" 2>"$errf" ||
        rc=$?
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
blocked "ampersand redirect to a file" Bash command "echo x >& $S/merge-captain/reviews.jsonl"
blocked "ampersand redirect glued to the path" Bash command "echo x >&$H/.config/agents/lanes.toml"
blocked "noclobber override redirect" Bash command "echo x >| $S/agent-eval/outcomes.jsonl"
blocked "both-streams redirect" Bash command "echo x &> $S/merge-captain/reviews.jsonl"
allowed "stderr to stdout" Bash command "ls /tmp 2>&1"
allowed "closing a descriptor" Bash command "ls /tmp >&-"
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

# ── The token directory: no read, write, search or shell mention, except through the tool itself ──
T="$H/.config/merge-captain/tokens"
for tool in Read Write Edit MultiEdit; do
    blocked "$tool on a token" "$tool" file_path "$T/jdwlabs"
    blocked "$tool on token metadata" "$tool" file_path "$T/jdwlabs.meta"
    blocked "$tool on a token not yet saved" "$tool" file_path "$T/dotablaze-tech"
    blocked "$tool on the token directory" "$tool" file_path "$T"
    blocked "$tool on the config directory" "$tool" file_path "$H/.config/merge-captain/notes"
    blocked "$tool via a tilde path" "$tool" file_path "~/.config/merge-captain/tokens/jdwlabs"
    blocked "$tool via \$HOME" "$tool" file_path '$HOME/.config/merge-captain/tokens/jdwlabs'
    blocked "$tool via a .. path" "$tool" file_path "$H/.config/agents/../merge-captain/tokens/jdwlabs"
    blocked "$tool via a symlink" "$tool" file_path "$tmp/merge-captain-tokens-link/jdwlabs"
    blocked "$tool by a relative name from inside" "$tool" file_path "jdwlabs" "$T"
done
grep -q 'token directory' "$errf" || fail "the block does not say what it protects" "$(cat "$errf")"
blocked "Grep over the tokens" Grep path "$T"
blocked "Grep over the config directory" Grep path "$H/.config/merge-captain"
blocked "Grep over ~/.config, which contains them" Grep path "$H/.config"
blocked "Grep with a glob into them" Grep glob "merge-captain/tokens/**"
blocked "Grep from inside the directory" Grep pattern "github" "$T"
blocked "Glob in the tokens" Glob path "$T"
blocked "Glob over ~/.config" Glob path "$H/.config"
blocked "Glob with an absolute pattern" Glob pattern "$T/*"
blocked "Glob with a ~ pattern" Glob pattern "~/.config/merge-captain/tokens/*"
blocked "Glob with a relative pattern" Glob pattern "**/merge-captain/tokens/*"
blocked "Glob from inside the directory" Glob pattern "*" "$T"
# Bash: any mention of the directory, however the command uses it.
blocked "cat a token" Bash command "cat $T/jdwlabs"
blocked "cat via tilde" Bash command 'cat ~/.config/merge-captain/tokens/jdwlabs'
blocked "cat via \$HOME" Bash command 'cat $HOME/.config/merge-captain/tokens/jdwlabs'
blocked "cat via braces" Bash command 'cat "${HOME}/.config/merge-captain/tokens/jdwlabs"'
blocked "cat via XDG_CONFIG_HOME" Bash command 'cat "$XDG_CONFIG_HOME/merge-captain/tokens/jdwlabs"'
blocked "cat via braced XDG_CONFIG_HOME" Bash command 'cat ${XDG_CONFIG_HOME}/merge-captain/tokens/jdwlabs'
blocked "ls the directory" Bash command "ls -la $H/.config/merge-captain"
blocked "ls the tokens" Bash command 'ls ~/.config/merge-captain/tokens'
blocked "cp a token out" Bash command "cp $T/jdwlabs /tmp/x"
blocked "cp a token in" Bash command "cp /tmp/x $T/jdwlabs"
blocked "grep in the tokens" Bash command "grep -r github $T"
blocked "echo into a token" Bash command "echo x > $T/jdwlabs"
blocked "tar the config" Bash command "tar czf /tmp/c.tgz ~/.config/merge-captain"
blocked "tar the tokens path" Bash command "tar czf /tmp/c.tgz $T"
blocked "find in the directory" Bash command "find $H/.config/merge-captain -type f"
blocked "base64 a token" Bash command "base64 $T/jdwlabs"
blocked "head a token" Bash command "head -c 20 $T/jdwlabs"
blocked "cd then read" Bash command "cd $T && cat jdwlabs"
blocked "cd the parent then read" Bash command "cd ~/.config && cat merge-captain/tokens/jdwlabs"
blocked "relative read from inside" Bash command 'cat jdwlabs' "$T"
blocked "ls from inside" Bash command 'ls' "$T"
blocked "inside bash -c" Bash command "bash -c 'cat $T/jdwlabs'"
blocked "after &&" Bash command "ls && cat $T/jdwlabs"
blocked "after a pipe" Bash command "true | cat $T/jdwlabs"
blocked "on a later line" Bash command $'set -e\ncat '"$T/jdwlabs"
blocked "a status that smuggles a read in" Bash command "merge-captain status \$(cat $T/jdwlabs)"
blocked "a status with a backtick read" Bash command "merge-captain status \`cat $T/jdwlabs\`"
blocked "a status followed by a read" Bash command "merge-captain status; cat $T/jdwlabs"
blocked "an auth that redirects the token out" Bash command "merge-captain auth jdwlabs > $T/jdwlabs"
blocked "a remove spelled with a redirect" Bash command "merge-captain auth jdwlabs --remove < $T/jdwlabs"
blocked "env var pointing at it for another tool" Bash command "MERGE_CAPTAIN_TOKENS=$T cat $T/jdwlabs"
# The approver App's key and ids live in the same directory and get the same protection.
for tool in Read Write Edit MultiEdit; do
    blocked "$tool on the approver key" "$tool" file_path "$T/approver.key"
    blocked "$tool on the approver ids" "$tool" file_path "$T/approver.json"
    blocked "$tool on the approver key through a link" "$tool" file_path "$tmp/merge-captain-tokens-link/approver.key"
done
blocked "cat the approver key" Bash command "cat $T/approver.key"
blocked "cat the approver key via tilde" Bash command 'cat ~/.config/merge-captain/tokens/approver.key'
blocked "cat the approver key from inside" Bash command 'cat approver.key' "$T"
blocked "copy the approver key out" Bash command "cp $T/approver.key /tmp/k.pem"
blocked "openssl on the approver key" Bash command "openssl rsa -in $T/approver.key -noout -text"
blocked "grep the approver ids" Bash command "grep app_id $T/approver.json"
blocked "an auth-app that redirects the key out" Bash command "merge-captain auth-app --remove > $T/approver.key"
blocked "an auth-app followed by a read" Bash command "merge-captain auth-app --key-file /tmp/k.pem; cat $T/approver.key"
allowed "saving the approver" Bash command 'merge-captain auth-app --key-file ~/Downloads/app.pem'
allowed "removing the approver" Bash command 'merge-captain auth-app --remove'
# The tool and path overrides are for tests: an agent may not assign one, however it spells the assignment.
blocked "inline override for status" Bash command "MERGE_CAPTAIN_TOKENS=$T merge-captain status"
blocked "inline gh override" Bash command 'MERGE_CAPTAIN_GH=/tmp/evil merge-captain run'
blocked "inline openssl override" Bash command 'MERGE_CAPTAIN_OPENSSL=/tmp/evil merge-captain run'
blocked "inline state override" Bash command 'MERGE_CAPTAIN_STATE=/tmp/s merge-captain status'
blocked "inline class override" Bash command 'MERGE_CAPTAIN_CLASS=/tmp/c merge-captain run'
blocked "export override" Bash command 'export MERGE_CAPTAIN_GH=/tmp/evil; merge-captain run'
blocked "export without a value" Bash command 'export MERGE_CAPTAIN_GH'
blocked "env override" Bash command 'env MERGE_CAPTAIN_TOKENS=/tmp/t merge-captain status'
blocked "env override, quoted name" Bash command 'env "MERGE_CAPTAIN_TOKENS=/tmp/t" merge-captain status'
blocked "declare -x override" Bash command 'declare -x MERGE_CAPTAIN_STATE=/tmp/s'
blocked "override with spaces around =" Bash command 'MERGE_CAPTAIN_GH =/tmp/evil true'
blocked "appended override" Bash command 'MERGE_CAPTAIN_GH+=x true'
blocked "override on a later line" Bash command $'true\nMERGE_CAPTAIN_GH=/tmp/evil merge-captain run'
blocked "the test switch" Bash command 'MERGE_CAPTAIN_TEST_HARNESS=1 merge-captain run'
blocked "the API override" Bash command 'MERGE_CAPTAIN_API_URL=http://127.0.0.1:1 merge-captain run'
allowed "reading an override name" Bash command 'grep MERGE_CAPTAIN_GH docs/merge-captain.md'
allowed "echoing one" Bash command 'echo "$MERGE_CAPTAIN_STATE"'
# ...and these never touch a token.
allowed "saving a token" Bash command 'merge-captain auth jdwlabs'
allowed "saving with an expiry" Bash command 'merge-captain auth dotablaze-tech --expires 2027-01-01'
allowed "removing a token" Bash command 'merge-captain auth jdwillmsen --remove'
allowed "status" Bash command 'merge-captain status'
allowed "status with stderr joined" Bash command 'merge-captain status 2>&1 | head -20'
allowed "status after a cd elsewhere" Bash command 'cd ~/projects && merge-captain status'
allowed "status with an absolute tool path" Bash command "$H/.local/bin/merge-captain status"
allowed "Read of another config file" Read file_path "$H/.config/agents/lanes.toml"
allowed "Read of a lookalike directory" Read file_path "$H/.config/merge-captain-notes/x"
allowed "Grep in a project" Grep path "$H/projects"
allowed "Grep for the words" Grep pattern "merge-captain/tokens" "$tmp/work"
allowed "Grep with an unrelated glob" Grep glob "*.sh" "$tmp/work"
allowed "Glob in a project" Glob pattern "**/*.sh" "$tmp/work"
allowed "Glob with a path elsewhere" Glob path "$H/.config/agents"
allowed "a doc that mentions the tool" Bash command 'cat docs/merge-captain.md'
allowed "searching for the tool's name" Bash command 'grep -rn merge-captain ~/projects'
allowed "state, which is not the token directory" Bash command "ls $H/.local/state/merge-captain"
allowed "a commit about the tool" Bash command 'git commit -m "feat(merge-captain): one token per owner"'

# ── A line is split at every operator that starts a new command, including a lone & ──
S2="$H/.local/state/merge-captain"
blocked "auth then a backgrounded read" Bash command "merge-captain auth acme & cat $T/acme"
blocked "status then a backgrounded read" Bash command "merge-captain status & cat ~/.config/merge-captain/tokens/acme"
blocked "a backgrounded command then a state write" Bash command "true & rm ~/.local/state/merge-captain/log.jsonl"
blocked "no spaces around &" Bash command "true&rm $S2/log.jsonl"
blocked "a backgrounded command then a redirect" Bash command "sleep 1 & echo x >> $S2/reviews.jsonl"
blocked "a read after |&" Bash command "true |& cat $T/acme"
blocked "a write after |&" Bash command "echo x |& tee $S2/log.jsonl"
blocked "status then a read on the next line" Bash command $'merge-captain status\ncat '"$T/acme"
blocked "auth then a write on the next line" Bash command $'merge-captain auth acme\nrm '"$S2/log.jsonl"
blocked "status & then a read on a later line" Bash command $'merge-captain status &\ncat '"$T/acme"
blocked "a read after &> on the same line" Bash command "merge-captain status &> /tmp/o & cat $T/acme"
allowed "a backgrounded sleep" Bash command 'sleep 1 & echo ok'
allowed "status in the background" Bash command 'merge-captain status &'
allowed "status with both streams to a file" Bash command 'merge-captain status &> /tmp/status.out'
allowed "both streams appended" Bash command 'merge-captain status &>> /tmp/status.out'
allowed "stderr to the null device" Bash command 'ls /tmp >& /dev/null'
allowed "stderr joined, backgrounded" Bash command 'merge-captain status 2>&1 &'
allowed "a pipe with stderr" Bash command 'echo hi |& cat'
allowed "status then another harmless line" Bash command $'merge-captain status\necho done'

# ── Paths that reach a protected location through a symlink ──
mkdir -p "$tmp/via"
ln -s "$H/.config/merge-captain" "$tmp/via/mc"
ln -s "$H/.config/merge-captain/tokens" "$tmp/via/tk"
ln -s "$H/.local/state/merge-captain" "$tmp/via/st"
ln -s "$H/.config" "$tmp/via/cfg"
ln -s "$H" "$tmp/via/home"
ln -s "$H/.config/agents" "$tmp/via/agents"
for tool in Read Write Edit MultiEdit; do
    blocked "$tool through a link to the config directory" "$tool" file_path "$tmp/via/mc/tokens/jdwlabs"
    blocked "$tool through a link to the tokens" "$tool" file_path "$tmp/via/tk/jdwlabs"
    blocked "$tool by a relative path through a link" "$tool" file_path "via/mc/tokens/jdwlabs" "$tmp"
    blocked "$tool through a link and .." "$tool" file_path "$tmp/via/tk/../tokens/jdwlabs"
    blocked "$tool through a link to the config root" "$tool" file_path "$tmp/via/cfg/merge-captain/tokens/jdwlabs"
done
for tool in Write Edit MultiEdit; do
    blocked "$tool through a link to the state directory" "$tool" file_path "$tmp/via/st/reviews.jsonl"
done
allowed "Read through a link to something harmless" Read file_path "$tmp/via/agents/other.toml"
allowed "Read of a plain path" Read file_path "$tmp/work/notes.txt"
allowed "Write through a link to the home directory" Write file_path "$tmp/via/home/projects/x.txt"
blocked "Grep through a link to the config root" Grep path "$tmp/via/cfg"
blocked "Glob through a link to the home directory" Glob path "$tmp/via/home"

# ── A recursive search from the config directory or above reaches the tokens ──
for cmd in \
    'grep -r foo ~/.config' 'grep -rn foo ~/.config/' 'grep -R secret "$HOME/.config"' 'grep --recursive foo ~' \
    'grep -r foo ~' 'grep -r foo $HOME' 'grep -ri foo ${HOME}' "grep -r foo $tmp" 'grep -r foo /' \
    "grep -r -e foo $H/.config" 'egrep -r foo ~' 'rg foo ~' 'rg -l secret ~/.config' 'ag foo ~' 'fd token ~' \
    'find ~ -name x' 'find ~/.config -exec cat {} +' "find $H/.config -print" "find $H -name '*.toml'" \
    'find -L ~ -type f' 'find / -name x' \
    'tar czf /tmp/x.tgz ~/.config' 'tar -czf /tmp/x.tgz ~' "tar cf - $H/.config" 'tar --create -f /tmp/x ~' \
    'rsync -a ~/.config/ /tmp/backup' 'rsync --recursive ~ /tmp/b' 'cp -r ~/.config /tmp/x' 'cp -a ~ /tmp/x' \
    'cp --recursive -t /tmp/x ~/.config' 'ls -R ~' "ls -laR $H/.config" 'du -sh ~' 'du ~/.config' 'tree ~' \
    'zip -r /tmp/x.zip ~/.config' 'grep -r foo ~/.config/*' 'grep -r foo ~/.c*' "grep -r foo $H/.[a-z]*" \
    "grep -r foo $tmp/*" "bash -c 'grep -r foo ~/.config'" 'sudo grep -r foo ~' 'time find ~ -name x' \
    'true && grep -r foo ~' 'true & grep -r foo ~'; do
    blocked "recursive: $cmd" Bash command "$cmd" "$tmp/work"
done
grep -q 'aim it at the project directory' "$errf" || fail "the block does not say how to search instead" "$(cat "$errf")"
for cmd in 'rg foo' 'rg foo .' 'grep -r foo' 'grep -r foo .' 'find . -name x' 'find' 'du -sh' 'tree' 'ls -R' \
    'cd ~ && grep -r foo .' 'cd && rg foo' 'cd ~/.config; find . -type f' 'cd $HOME/.config && grep -r pw *' \
    'cd .. && tree'; do
    blocked "no path from the home directory: $cmd" Bash command "$cmd" "$H"
done
blocked "after cd into the config directory" Bash command 'cd .config && rg foo' "$H"
blocked "after cd .. to the home directory" Bash command 'cd .. && grep -r foo' "$H/projects"
blocked "no path from a directory above the home directory" Bash command 'grep -r foo' "$tmp"
allowed "no path from a project" Bash command 'rg foo' "$H/projects/app"
allowed "a project path from the home directory" Bash command 'grep -r foo ./src' "$H"
allowed "a find in a project from the home directory" Bash command "find ./src -name '*.ts'" "$H"
allowed "grep -r in a project" Bash command 'grep -r foo ./src' "$tmp/work"
allowed "grep -rn in a project by absolute path" Bash command "grep -rn foo $H/projects/app/src"
allowed "rg in a project" Bash command 'rg foo ./src' "$tmp/work"
allowed "rg with a project directory" Bash command "rg -l foo $H/projects"
allowed "find in a project" Bash command "find $H/projects -name '*.ts' -exec ls {} +" "$tmp/work"
allowed "find with no path in a project" Bash command "find . -name '*.ts'" "$tmp/work"
allowed "du in a project" Bash command 'du -sh ./build' "$tmp/work"
allowed "tree in a project" Bash command 'tree ./src' "$tmp/work"
allowed "ls -R in a project" Bash command 'ls -R' "$tmp/work"
allowed "cp -r a project directory" Bash command 'cp -r ./src /tmp/copy' "$tmp/work"
allowed "cp -r into the home directory" Bash command 'cp -r ./src ~' "$tmp/work"
allowed "rsync a project into the home directory" Bash command 'rsync -a ./src/ ~/backup/' "$tmp/work"
allowed "tar a project" Bash command 'tar czf /tmp/out.tgz ./src' "$tmp/work"
allowed "tar extracted into the home directory" Bash command 'tar xzf /tmp/in.tgz -C ~' "$tmp/work"
allowed "a flat listing of the home directory" Bash command 'ls -la ~' "$tmp/work"
allowed "a flat listing of ~/.config" Bash command 'ls ~/.config' "$tmp/work"
allowed "grep of one file under ~/.config" Bash command 'grep foo ~/.config/agents/lanes.toml' "$tmp/work"
allowed "a recursive search of the non-hidden entries of ~" Bash command 'grep -r foo ~/*' "$tmp/work"
allowed "git grep" Bash command 'git grep foo' "$H"
allowed "a commit message that names the tools" Bash command 'git commit -m "fix: grep -r ~ was slow"' "$H"

# ── Grep and Glob rooted at or above the token directory, with no scope, reach it ──
blocked "Grep with no path from the home directory" Grep pattern foo "$H"
blocked "Grep with no path from above the home directory" Grep pattern foo "$tmp"
blocked "Grep with no path from the config directory" Grep pattern foo "$H/.config"
blocked "Grep of the home directory" Grep path "$H" "$tmp/work"
blocked "Grep of ~" Grep path "~" "$tmp/work"
blocked "Grep of \$HOME" Grep path '$HOME' "$tmp/work"
blocked "Grep of the root" Grep path "/" "$tmp/work"
blocked "Glob with no path from the home directory" Glob pattern "**/*.sh" "$H"
blocked "Glob of the home directory" Glob path "$H" "$tmp/work"
blockedj "Grep of ~ with a glob that is everywhere" Grep "$tmp/work" "{\"path\":\"$H\",\"glob\":\"*.sh\",\"pattern\":\"x\"}"
blockedj "Grep of ~ with a glob into the config" Grep "$tmp/work" "{\"path\":\"$H\",\"glob\":\".config/**\"}"
blockedj "Grep with no path and an unscoped glob" Grep "$H" '{"glob":"**/*.toml","pattern":"x"}'
blockedj "Glob of ~ with a recursive pattern" Glob "$tmp/work" "{\"path\":\"$H\",\"pattern\":\"**/*\"}"
blockedj "Glob of ~ into the config" Glob "$tmp/work" "{\"path\":\"$H\",\"pattern\":\".config/**/*\"}"
blockedj "Glob with an absolute pattern over ~" Glob "$H" "{\"pattern\":\"$H/*\"}"
allowed "Grep with no path from a project" Grep pattern foo "$H/projects/app"
allowedj "Grep of ~ scoped to projects" Grep "$tmp/work" "{\"path\":\"$H\",\"glob\":\"projects/**/*.ts\",\"pattern\":\"x\"}"
allowedj "Grep of ~ scoped to one file" Grep "$tmp/work" "{\"path\":\"$H\",\"glob\":\"src/a.ts\",\"pattern\":\"x\"}"
allowedj "Glob of ~ scoped to projects" Glob "$tmp/work" "{\"path\":\"$H\",\"pattern\":\"projects/**/*.sh\"}"
allowedj "Glob with an absolute pattern in projects" Glob "$H" "{\"pattern\":\"$H/projects/**/*.sh\"}"
allowed "Grep of a project" Grep path "$H/projects" "$tmp/work"
allowed "Glob of a project" Glob path "$H/projects/app" "$H"

# XDG_CONFIG_HOME moves the config directory, and with it the tokens.
mkdir -p "$tmp/xdgc/merge-captain/tokens"
HOOK_ENVV=(XDG_CONFIG_HOME="$tmp/xdgc")
blocked "Read under XDG_CONFIG_HOME" Read file_path "$tmp/xdgc/merge-captain/tokens/jdwlabs"
blocked "Bash under XDG_CONFIG_HOME" Bash command "cat $tmp/xdgc/merge-captain/tokens/jdwlabs"
blocked "Grep over XDG_CONFIG_HOME" Grep path "$tmp/xdgc"
allowed "Read elsewhere under XDG_CONFIG_HOME" Read file_path "$tmp/xdgc/agents/lanes.toml"
HOOK_ENVV=()

# A tokens directory moved by MERGE_CAPTAIN_TOKENS is protected wherever it is, with or without the tool's name.
mkdir -p "$tmp/vault"
HOOK_ENVV=(MERGE_CAPTAIN_TOKENS="$tmp/vault")
blocked "Read in a moved token directory" Read file_path "$tmp/vault/jdwlabs"
blocked "Write in a moved token directory" Write file_path "$tmp/vault/jdwlabs"
blocked "Bash in a moved token directory" Bash command "cat $tmp/vault/jdwlabs"
blocked "Bash from inside a moved token directory" Bash command "cat jdwlabs" "$tmp/vault"
blocked "the default directory still" Read file_path "$T/jdwlabs"
allowed "a path beside the moved directory" Read file_path "$tmp/vault-notes/x"
allowed "an ordinary call with the variable set" Bash command 'ls -la /tmp'
HOOK_ENVV=()

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

# ── ...and a file tool resolves links only when it has to ──
mkdir -p "$tmp/stubbin"
cat >"$tmp/stubbin/realpath" <<STUB
#!/bin/sh
echo call >>"$tmp/realpath.calls"
exec /usr/bin/realpath "\$@"
STUB
chmod +x "$tmp/stubbin/realpath"
HOOK_PATH="$tmp/stubbin:/usr/bin:/bin"
forks() { if [ -f "$tmp/realpath.calls" ]; then wc -l <"$tmp/realpath.calls"; else echo 0; fi; }
rm -f "$tmp/realpath.calls"
allowed "an ordinary Bash call" Bash command 'ls -la ./src && git status' "$tmp/work"
allowed "a Bash call that names a project path" Bash command "cat $H/projects/app/src/main.ts" "$tmp/work"
allowed "a Bash call that searches a project" Bash command 'grep -rn foo ./src' "$tmp/work"
allowed "an ordinary Read" Read file_path "$tmp/work/notes.txt"
allowed "an ordinary relative Edit" Edit file_path "src/main.ts" "$tmp/work"
[ "$(forks)" = 0 ] || fail "an ordinary call started realpath $(forks) time(s)"
blocked "a Read through a link" Read file_path "$tmp/via/mc/tokens/jdwlabs"
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
