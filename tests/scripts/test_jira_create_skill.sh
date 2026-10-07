#!/usr/bin/env bash
# The skill is instructions, not code, so what can be pinned is that it no
# longer steers every ticket into one project regardless of the repo.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
skill="$here/home/private_dot_claude/skills/jira-create/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }

grep -q 'stream key' "$skill" || fail "skill must resolve the project with 'stream key'"
grep -qF "Default \`JDWLABS\`" "$skill" && fail "skill still defaults every ticket to JDWLABS"
grep -q 'project = JDWLABS' "$skill" && fail "skill still hardcodes JDWLABS in JQL"
grep -q 'project = <PROJECT>' "$skill" || fail "JQL should use the resolved <PROJECT>"
grep -qE 'JDWLABS-[0-9X]+' "$skill" && fail "examples should use <PROJECT>-NN, not a JDWLABS key"
# Cross-stream work is linked, never re-parented across projects.
grep -qi 'another stream' "$skill" || fail "skill must say how to reference another stream's ticket"
echo "PASS"
