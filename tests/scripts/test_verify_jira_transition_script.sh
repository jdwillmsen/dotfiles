#!/usr/bin/env bash
# The hook is fed the JSON Claude Code sends a PostToolUse hook and judged by its exit code and stdout alone.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$here/home/private_dot_claude/hooks/executable_verify-jira-transition.sh"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$hook" ] || fail "verify-jira-transition.sh missing or not executable"
head -1 "$hook" | grep -qx '#!/usr/bin/env bash' || fail "hook needs the bash env shebang"

# context <stdin text>: prints the injected additionalContext, failing unless the output is the PostToolUse shape.
context() {
    local out rc=0
    out="$(printf '%s' "$1" | "$hook")" || rc=$?
    [ "$rc" = 0 ] || fail "hook must exit 0, got $rc" "$out"
    printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"] == "PostToolUse", d
print(d["additionalContext"])'
}

payload='{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{"cloudId":"c","issueIdOrKey":"JDW-372","transition":{"id":"31"}},"tool_response":{"success":true}}'
ctx="$(context "$payload")"
grep -q 'getJiraIssue' <<<"$ctx" || fail "context must name getJiraIssue" "$ctx"
grep -q 'JDW-372' <<<"$ctx" || fail "context must name the issue" "$ctx"
grep -q 'retry transitionJiraIssue once' <<<"$ctx" || fail "context must allow one retry" "$ctx"

# Spacing that json.dumps produces still yields the key.
ctx="$(context '{"tool_input": {"issueIdOrKey": "DOTA-7"}}')"
grep -q 'DOTA-7' <<<"$ctx" || fail "key not read from spaced JSON" "$ctx"

# Fails open: no key, garbage or empty input still exit 0 with valid output.
ctx="$(context '{"tool_input":{}}')"
grep -q 'the issue' <<<"$ctx" || fail "missing key should fall back to generic wording" "$ctx"
context 'not json' >/dev/null
context '' >/dev/null

# A key carrying JSON-breaking characters is not echoed back.
ctx="$(context '{"tool_input":{"issueIdOrKey":"X\"}"}}')"
grep -q 'the issue' <<<"$ctx" || fail "unsafe key echoed" "$ctx"

shellcheck -s bash "$hook"
echo "PASS"
