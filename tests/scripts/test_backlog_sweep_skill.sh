#!/usr/bin/env bash
# The skill is instructions, not code, so what can be pinned is the guard rails
# the owner set for it: Done only for work this session shipped and verified,
# everything else bundled into one decision, OPS left untouched, and every
# transition re-read.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
skill="$here/home/private_dot_claude/skills/backlog-sweep/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$skill" ] || fail "SKILL.md missing"
head -4 "$skill" | grep -q '^name: backlog-sweep$' || fail "frontmatter name missing"
grep -q '^description: .*where are we' "$skill" || fail "description must carry the rundown trigger"
[ "$(wc -l <"$skill")" -le 150 ] || fail "SKILL.md over 150 lines"

grep -q 'stream key' "$skill" || fail "skill must resolve the project with 'stream key'"
grep -q 'by this session' "$skill" || fail "Done must be limited to work this session shipped"
grep -qi 'owner decision' "$skill" || fail "unshipped closes must go to one owner decision"
grep -q 'getJiraIssue' "$skill" || fail "every transition must be re-read"
grep -qF "Report only. No comments, no links, no transitions on \`OPS\`" "$skill" ||
    fail "OPS triage must be report-only"
grep -q 't3_thread_list' "$skill" || fail "rundown must include open T3 threads"
echo "PASS"
