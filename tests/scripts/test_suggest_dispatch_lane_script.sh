#!/usr/bin/env bash
# The hook is fed the JSON Claude Code sends a PreToolUse hook, with a stub agent-pace first on PATH that records its
# arguments, and judged by its exit code, its stdout and what it asked agent-pace. HOME is a temp dir holding a
# streams.json, so ticket keys come from the fixture and not the real map.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$here/home/private_dot_claude/hooks/executable_suggest-dispatch-lane.sh"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$hook" ] || fail "suggest-dispatch-lane.sh missing or not executable"
head -1 "$hook" | grep -qx '#!/usr/bin/env bash' || fail "hook needs the bash env shebang"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
H="$tmp/home"
mkdir -p "$H/.config" "$tmp/bin" "$tmp/nobin"
cat >"$H/.config/streams.json" <<'JSON'
{"streams": {"jdwillmsen": {"jira": "JDW", "repoOverrides": {"career": "CAREER"}}, "jdwlabs": {"jira": "JDWLABS"}}}
JSON
# The stub's behaviour is chosen per case through STUB_MODE; its arguments land in $tmp/args.
cat >"$tmp/bin/agent-pace" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$STUB_ARGS"
case "${STUB_MODE:-assigned}" in
    assigned) echo '{"assignment":"a-1","lane":"claude-sonnet","provider":"claudeAgent","model":"claude-sonnet-5-5","result":"assigned","reason":"r","review_lane":"claude-opus","fallback":["claude-opus"],"logged":false}' ;;
    free) echo '{"assignment":"a-2","lane":"opencode-glm-flash-free","model":"opencode/glm","result":"assigned","reason":"r","fallback":["claude-sonnet"],"logged":false}' ;;
    defer) echo '{"assignment":"a-3","lane":null,"result":"defer","reason":"opus out of quota until Mon","logged":false}'; exit 3 ;;
    slow) sleep 3; echo '{}' ;;
    garbage) echo 'error: "boom"'; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/agent-pace"
base_path="$tmp/bin:$PATH"

run() {  # tool tool_input-JSON [mode]: sets OUT (hook stdout) and ARGS (what agent-pace was asked, empty if never)
    local rc=0
    rm -f "$tmp/args"
    OUT="$(printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s}' "$1" "$2" |
        HOME="$H" PATH="$base_path" STUB_ARGS="$tmp/args" STUB_MODE="${3:-assigned}" CLAUDE_CODE_SUBAGENT_MODEL='' \
        "$hook")" || rc=$?
    [ "$rc" = 0 ] || fail "hook must always exit 0, got $rc" "$OUT"
    ARGS="$(cat "$tmp/args" 2>/dev/null || true)"
}
ctx() {  # prints additionalContext, failing unless the output is advisory PreToolUse context
    printf '%s' "$OUT" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
assert d["hookEventName"] == "PreToolUse", d
assert "permissionDecision" not in d, "the hook must never decide, only advise"
print(d["additionalContext"])' || fail "bad hook output" "$OUT"
}
asked() {  # description expected-args
    [ "$ARGS" = "$2" ] || fail "$1: agent-pace asked '$ARGS', want '$2'"
}

# Class from the agent type, the T3 role, or the brief; risk and ticket from the brief; never logged.
run Agent '{"subagent_type":"Explore","description":"find the config","prompt":"where is X"}'
asked "Explore" "assign --class research --risk R1 --no-log --json"
run Agent '{"subagent_type":"Plan","prompt":"design the rollout, risk R3, JDWLABS-88"}'
asked "Plan with risk and ticket" "assign --class plan --risk R3 --no-log --json --ticket JDWLABS-88"
run mcp__t3-code__delegate_task '{"role":"test","task":"cover the parser. Tier: R0"}'
asked "delegate role" "assign --class test --risk R0 --no-log --json"
run mcp__t3-code__delegate_task '{"role":"general","task":"Address the review findings on CAREER-4"}'
asked "review-fix from text" "assign --class review-fix --risk R1 --no-log --json --ticket CAREER-4"
run Task '{"description":"Review PR","prompt":"Opus review of the diff, R2 risk"}'
asked "review from text" "assign --class review --risk R2 --no-log --json"
run Agent '{"description":"Implement the hook","prompt":"build it; mentions R2D2 and UTF-8 and ABC-12"}'
asked "defaults; no false risk or ticket" "assign --class impl --risk R1 --no-log --json"
run Agent '{"prompt":"summarize the CI logs"}'
asked "summarize" "assign --class summarize --risk R1 --no-log --json"

# The context names the lane and says whether this call matches it.
run Agent '{"description":"Implement","prompt":"do it for JDW-9","model":"sonnet"}'
c="$(ctx)"
grep -q 'lane claude-sonnet' <<<"$c" || fail "context should name the lane" "$c"
grep -q 'runs on sonnet, which matches' <<<"$c" || fail "matching model should say so" "$c"
grep -q 'risk R1 (default; pass the real tier)' <<<"$c" || fail "defaulted risk should be flagged" "$c"
grep -q 'agent-pace assign --class impl --risk R1 --ticket JDW-9, then agent-eval record' <<<"$c" ||
    fail "context should give the logged command" "$c"
run Agent '{"prompt":"do it","model":"opus"}' free
c="$(ctx)"
grep -q 'lane opencode-glm-flash-free' <<<"$c" || fail "free lane not named" "$c"
grep -q 'runs on opus, not that lane' <<<"$c" || fail "mismatch should be called out" "$c"
run mcp__t3-code__delegate_task '{"task":"do it"}'
grep -q 'inherited model' <<<"$(ctx)" || fail "no model should say inherited" "$OUT"
run Agent '{"prompt":"review"}' defer
c="$(ctx)"
grep -q 'result defer, opus out of quota' <<<"$c" || fail "defer should be reported" "$c"
grep -q 'Queue the work' <<<"$c" || fail "defer should say to queue" "$c"

# Fails open: missing, slow or broken agent-pace, and garbage input, all exit 0 with no output.
rm -f "$tmp/args"
OUT="$(printf '%s' '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' | HOME="$H" PATH="$tmp/nobin:/usr/bin:/bin" "$hook")" ||
    fail "missing agent-pace must exit 0"
[ -z "$OUT" ] || fail "missing agent-pace should print nothing" "$OUT"
start=$(date +%s%N)
run Agent '{"prompt":"x"}' slow
ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ -z "$OUT" ] || fail "timed-out agent-pace should print nothing" "$OUT"
[ "$ms" -lt 2500 ] || fail "timeout not enforced: ${ms}ms"
run Agent '{"prompt":"x"}' garbage
[ -z "$OUT" ] || fail "unparseable agent-pace output should print nothing" "$OUT"
for bad in 'not json' '' '{}'; do
    printf '%s' "$bad" | HOME="$H" PATH="$base_path" STUB_ARGS="$tmp/args" "$hook" >/dev/null ||
        fail "hook must exit 0 on bad input: $bad"
done

shellcheck -s bash "$hook"
echo "PASS"
