#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-audit runs unattended from timers and files Jira tickets, so every
# path that can reach the outside world is exercised here against stubs:
# synthetic transcripts for the metrics, a stub gh for PR hygiene, a stub
# claude for insights, and a local HTTP server standing in for Jira.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
audit="$here/home/dot_local/bin/executable_agent-audit"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$audit" ] || fail "agent-audit missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$audit" || fail "agent-audit does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
fx="$tmp/home"
stubs="$tmp/bin"
mkdir -p "$fx" "$stubs"

# ── Fixture home: settings, plugins, instruction files, transcripts ──
python3 - "$fx" <<'PY'
import json, os, sys, time
fx = sys.argv[1]
def w(path, text):
    p = os.path.join(fx, path); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)
cache = os.path.join(fx, ".claude/plugins/cache")
w(".claude/plugins/cache/alpha/skills/do-thing/SKILL.md", "---\nname: do-thing\ndescription: x\n---\n")
w(".claude/plugins/cache/alpha/skills/unused-skill/SKILL.md", "---\nname: unused-skill\n---\n")
w(".claude/plugins/cache/alpha/agents/helper.md", "---\nname: helper\n---\n")
w(".claude/plugins/cache/alpha/hooks/hooks.json", json.dumps({"hooks": {"SessionStart": [
    {"hooks": [{"type": "command", "command": 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/start.sh"'}]}]}}))
w(".claude/plugins/cache/beta/.mcp.json", json.dumps({"srv": {"command": "x"}}))
w(".claude/plugins/cache/gamma/skills/g-skill/SKILL.md", "---\nname: g-skill\n---\n")
w(".claude/plugins/cache/gamma/skills/off-skill/SKILL.md", "---\nname: off-skill\n---\n")
w(".claude/plugins/installed_plugins.json", json.dumps({"plugins": {
    f"{n}@m": [{"installPath": os.path.join(cache, n)}] for n in ("alpha", "beta", "gamma")}}))
w(".claude/settings.json", json.dumps({
    "enabledPlugins": {"alpha@m": True, "beta@m": True, "gamma@m": True},
    "skillOverrides": {"off-skill": "off"}, "cleanupPeriodDays": 90,
    "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "rtk hook claude"}]}]}}))
w(".claude/skills/mine/SKILL.md", "---\nname: mine\n---\n")
w(".claude/CLAUDE.md", "# global\n@RTK.md\n")
w(".claude/RTK.md", "rtk\n")
w("AGENTS.md", "line\n" * 250)
w("projects/jdwlabs/r1/AGENTS.md", "x" * 40000 + "\n")

def asst(mid, model, ts, content, usage):
    return {"type": "assistant", "timestamp": ts, "entrypoint": "cli",
            "message": {"id": mid, "model": model, "content": content, "usage": usage}}
def user(ts, content):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": content}}
def att(ts, a):
    return {"type": "attachment", "timestamp": ts, "attachment": a}

cur = "2026-09-22T10:00:00Z"
u1 = {"input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 1000,
      "cache_creation_input_tokens": 2000,
      "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 2000}}
u2 = {"input_tokens": 5, "output_tokens": 50, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 100}
sess_a = [
    user(cur, "hello there"),
    user(cur, "<command-name>/clear</command-name>"),
    att(cur, {"type": "hook_success", "hookEvent": "SessionStart",
              "command": 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/start.sh"',
              "stdout": json.dumps({"hookSpecificOutput": {"additionalContext": "A" * 1000}})}),
    att(cur, {"type": "hook_additional_context", "hookEvent": "SessionStart", "content": ["A" * 1000, "Z" * 50]}),
    att(cur, {"type": "hook_success", "hookEvent": "PreToolUse", "command": "rtk hook claude", "stdout": ""}),
    att(cur, {"type": "deferred_tools_delta", "addedNames": ["mcp__claude_ai_Gmail__send", "mcp__plugin_beta_srv__q"]}),
    # One API message streamed as two transcript lines, usage repeated on each.
    asst("m1", "claude-opus-5-5", cur, [{"type": "text", "text": "x" * 400}], u1),
    asst("m1", "claude-opus-5-5", cur, [{"type": "tool_use", "name": "Skill", "input": {"skill": "alpha:do-thing"}}], u1),
    asst("m2", "claude-sonnet-5-5", cur, [
        {"type": "tool_use", "name": "mcp__plugin_beta_srv__q", "input": {}},
        {"type": "tool_use", "name": "Agent", "input": {"subagent_type": "alpha:helper"}}], u2),
    asst("s1", "<synthetic>", cur, [{"type": "text", "text": "ignored"}], {"output_tokens": 999}),
]
lines = [json.dumps(x) for x in sess_a] + ['{"type":"assistant", broken']
w(".claude/projects/-proj/sessA.jsonl", "\n".join(lines) + "\n")
sub = [asst("m3", "claude-haiku-4-5", cur, [{"type": "text", "text": "sub"}], {"input_tokens": 1, "output_tokens": 10}),
       asst("m1", "claude-opus-5-5", cur, [{"type": "text", "text": "dup"}], u1)]
w(".claude/projects/-proj/sessA/subagents/agent-1.jsonl", "\n".join(json.dumps(x) for x in sub) + "\n")
prev = "2026-09-15T10:00:00Z"
w(".claude/projects/-proj/sessB.jsonl", "\n".join(json.dumps(x) for x in [
    user(prev, "older prompt"),
    asst("m4", "claude-opus-5-5", prev, [{"type": "text", "text": "y"}], {"input_tokens": 1, "output_tokens": 1000})]) + "\n")
old = "2026-08-01T10:00:00Z"
w(".claude/projects/-proj/sessC.jsonl", json.dumps(asst("m5", "claude-opus-5-5", old, [], {"output_tokens": 5})) + "\n")
t = time.mktime((2026, 8, 1, 12, 0, 0, 0, 0, 0))
os.utime(os.path.join(fx, ".claude/projects/-proj/sessC.jsonl"), (t, t))
PY

# ── Stubs: gh, claude, kubectl ──
cat >"$stubs/gh" <<'STUB'
#!/bin/sh
echo "$*" >>"$STUB_LOG.gh"
[ "${STUB_GH:-ok}" = "fail" ] && { echo "HTTP 403: rate limited" >&2; exit 1; }
case "$2" in
prs) cat <<'JSON'
[{"number":1,"repository":{"nameWithOwner":"jdwlabs/r1"},"author":{"login":"jdwillmsen"},"url":"u1","body":"one two three four five six seven eight nine ten"},
 {"number":2,"repository":{"nameWithOwner":"jdwlabs/r1"},"author":{"login":"jdwlabs-agent-bot[bot]"},"url":"u2","body":"a b c d e f g h i j k l m n o p q r s t"},
 {"number":3,"repository":{"nameWithOwner":"jdwlabs/r1"},"author":{"login":"jdwillmsen"},"url":"u3","body":"Why it changed. Generated with Claude Code"},
 {"number":4,"repository":{"nameWithOwner":"jdwlabs/r1"},"author":{"login":"renovate[bot]"},"url":"u4","body":"bump"}]
JSON
;;
commits) cat <<'JSON'
[{"sha":"aaaaaaa111","repository":{"fullName":"jdwlabs/r1"},"commit":{"message":"feat: x\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nAssisted-by: Claude Code:claude-opus-5-5"}},
 {"sha":"bbbbbbb222","repository":{"fullName":"jdwlabs/r1"},"commit":{"message":"fix: y\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"}},
 {"sha":"ccccccc333","repository":{"fullName":"jdwlabs/r1"},"commit":{"message":"docs: human only"}}]
JSON
;;
esac
STUB
cat >"$stubs/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$STUB_LOG.claude-args"
cat >"$STUB_LOG.claude-stdin"
case "${STUB_CLAUDE:-ok}" in
ok) echo '{"type":"result","is_error":false,"result":"**Trends** stub insight about alpha","total_cost_usd":0.012}' ;;
fail) echo "boom" >&2; exit 1 ;;
slow) sleep 10 ;;
esac
STUB
cat >"$stubs/kubectl" <<'STUB'
#!/bin/sh
touch "$STUB_LOG.kubectl"
exit 1
STUB
chmod +x "$stubs"/*

log="$tmp/stub"
run() {  # args → sets $out, $rc
    set +e
    out="$(env -u CLAUDE_CONFIG_DIR -u XDG_DATA_HOME HOME="$fx" TZ=UTC PATH="$stubs:/usr/bin:/bin" \
        STUB_LOG="$log" STUB_GH="${STUB_GH:-ok}" STUB_CLAUDE="${STUB_CLAUDE:-ok}" \
        AGENT_AUDIT_INSIGHTS_TIMEOUT="${AGENT_AUDIT_INSIGHTS_TIMEOUT:-30}" \
        JIRA_URL="${JIRA_URL:-}" JIRA_USERNAME="${JIRA_USERNAME:-}" JIRA_API_TOKEN="${JIRA_API_TOKEN:-}" \
        python3 "$audit" "$@" 2>"$tmp/stderr")"
    rc=$?
    set -e
}
field() { sed -n "s/^$1: //p" <<<"$out" | head -1; }
jget() {  # $1 = json file, $2 = python expression over j
    python3 -c "import json,sys; j=json.load(open(sys.argv[1])); v=($2); print(v)" "$1"
}

# ── Usage errors are structured and exit 2 before touching anything ──
run --window daily
[ "$rc" -eq 2 ] || fail "bad --window should exit 2" "$out"
grep -q '^error: ' <<<"$out" || fail "bad --window should print a structured error" "$out"
run --window weekly --bogus
[ "$rc" -eq 2 ] && grep -q "unknown argument --bogus" <<<"$out" || fail "unknown flags must be rejected" "$out"
run --version
[ "$rc" -eq 0 ] && [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version should print a bare version" "$out"
run
[ "$rc" -eq 0 ] && grep -q "0 reports yet" <<<"$out" || fail "home view should state an empty history" "$out"

# ── Metrics: weekly window ending before Mon 2026-09-28, nothing filed ──
run --window weekly --end 2026-09-28 --no-jira --no-insights
[ "$rc" -eq 0 ] || fail "weekly run failed" "$out$(cat "$tmp/stderr")"
js="$fx/.local/share/agent-audit/reports/2026-09-27-weekly.json"
md="$fx/.local/share/agent-audit/reports/2026-09-27-weekly.md"
[ -f "$js" ] && [ -f "$md" ] || fail "report and metrics JSON not written under the data dir" "$out"
[ -e "$log.kubectl" ] && fail "--no-jira still reached for Jira credentials"
[ -e "$log.claude-args" ] && fail "--no-insights still called claude"

check() {  # $1 = python expr over j, $2 = expected, $3 = label
    got="$(jget "$js" "$1")"
    [ "$got" = "$2" ] || fail "$3: expected $2, got $got"
}
check 'j["window_range"]["start"], j["window_range"]["end"]' "('2026-09-21', '2026-09-28')" "current window"
check 'j["window_range"]["prev_start"], j["window_range"]["prev_end"]' "('2026-09-14', '2026-09-21')" "previous window"
check 'j["current"]["sessions"], j["current"]["subagent_runs"]' "(1, 1)" "sessions and subagent runs"
check 'j["current"]["calls_main"], j["current"]["calls_subagent"]' "(2, 1)" "main vs subagent calls (dedup, synthetic dropped)"
check 'j["current"]["human_prompts"]' "2" "user prompts incl. slash command"
check 'sorted(j["current"]["tokens"].items())' \
    "[('cache_read', 1000), ('cache_write', 2100), ('cache_write_1h', 2000), ('input', 16), ('output', 160)]" "token totals"
# opus-5-5: 10*4 + 100*20 + 1000*0.2 + 2000*4*2 = 18240; sonnet-5-5: 5*2 + 50*10 + 100*2*1.25 = 760; haiku: 1*1 + 10*5 = 51
check 'round(sum(m["cost_usd"] for m in j["current"]["models"]) * 1e6)' "19051" "API-rate cost from the pricing table"
check '[m["model"] for m in j["current"]["models"]][0]' "claude-opus-5-5" "models ordered by output"
check 'next(m for m in j["current"]["models"] if m["model"]=="claude-opus-5-5")["out_text_est"]' "100" "visible-text estimate"
check 'j["current"]["skills"], j["current"]["agents"], j["current"]["mcp"], j["current"]["commands"]' \
    "({'alpha:do-thing': 1}, {'alpha:helper': 1}, {'plugin_beta_srv': 1}, {'clear': 1})" "usage counts"
check '[(h["plugin"],h["event"],h["fires"],h["bytes"]) for h in j["current"]["hooks"]]' \
    "[('alpha', 'SessionStart', 1, 1000), ('unattributed: ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ', 'SessionStart', 1, 50), ('settings.json', 'PreToolUse', 1, 0)]" \
    "hook attribution and injected bytes"
check '[p["plugin"] for p in j["disable_candidates"]["plugins"]]' "['gamma']" "zero-use plugins"
check 'j["disable_candidates"]["mcp_servers"]' "['claude_ai_Gmail']" "zero-use MCP servers"
check 'j["disable_candidates"]["skills"]' "['alpha:unused-skill', 'gamma:g-skill', 'mine']" "zero-use skills (overrides excluded)"
check 'j["previous"]["sessions"], j["previous"]["tokens"]["output"]' "(1, 1000)" "previous window from transcripts"
check 'j["coverage"]["files_scanned"], j["coverage"]["bad_lines"]' "(3, 1)" "old files skipped by mtime, bad lines counted"
check '[f["path"] for f in j["instructions"]["files"] if f["flag"]]' "['~/AGENTS.md']" "instruction file over 200 lines"
check '[c["flag"] for c in j["instructions"]["combined"]]' "['', 'over_32KiB']" "combined size flag"
check 'j["prs"]["current"]["prs"], j["prs"]["current"]["body_words_median"], j["prs"]["current"]["generated_with_footer"]' \
    "(3, 10, 1)" "PR hygiene excludes dependency bots"
check 'j["prs"]["current"]["ai_coauthored_commits"], j["prs"]["current"]["missing_assisted_by_examples"]' \
    "(2, ['jdwlabs/r1@bbbbbbb'])" "missing Assisted-by among AI commits"
grep -q -- "--created 2026-09-21..2026-09-27" "$log.gh" || fail "PR search not scoped to the window" "$(cat "$log.gh")"
grep -q "Insights unavailable: --no-insights" "$md" || fail "report should say insights were skipped"
grep -q "^| Output tokens | 160 | 1,000 | -84% |" "$md" || fail "headline delta row missing" "$(grep Output "$md")"

# ── Window math ──
win() {  # $1 window, $2 end → "start end prev_start prev_end"
    run --window "$1" --end "$2" --dry-run --no-jira --no-insights
    [ "$rc" -eq 0 ] || fail "$1 --end $2 failed" "$out"
    jget "$(field metrics)" '" ".join(j["window_range"][k] for k in ("start","end","prev_start","prev_end"))'
}
[ "$(win weekly 2026-09-30)" = "2026-09-21 2026-09-28 2026-09-14 2026-09-21" ] || fail "weekly snaps to ISO weeks"
[ "$(win biweekly 2026-09-28)" = "2026-09-14 2026-09-28 2026-08-31 2026-09-14" ] || fail "biweekly window"
[ "$(win monthly 2026-10-01)" = "2026-09-01 2026-10-01 2026-08-01 2026-09-01" ] || fail "monthly window"
[ "$(win monthly 2026-10-15)" = "2026-09-01 2026-10-01 2026-08-01 2026-09-01" ] || fail "monthly mid-month run"
[ "$(win monthly 2026-01-01)" = "2025-12-01 2026-01-01 2025-11-01 2025-12-01" ] || fail "monthly across a year"
[ "$(win quarterly 2026-10-01)" = "2026-07-01 2026-10-01 2026-04-01 2026-07-01" ] || fail "quarterly window"
[ "$(win quarterly 2026-02-10)" = "2025-10-01 2026-01-01 2025-07-01 2025-10-01" ] || fail "quarterly across a year"
run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
dry_dir="$(dirname "$(field metrics)")"
[ -f "$dry_dir/2026-09-27-weekly.md" ] || fail "--dry-run should still write a report to a temp dir" "$out"
case "$dry_dir" in "$fx"/*) fail "--dry-run wrote under the data dir" ;; esac
rm -rf "$dry_dir"

# ── Biweekly parity: scheduled runs only on even ISO weeks ──
run --window biweekly --end 2026-10-05 --scheduled --no-jira --no-insights
[ "$rc" -eq 0 ] && grep -q "week 41 is odd" <<<"$out" || fail "odd ISO week should be a no-op" "$out"
[ -e "$fx/.local/share/agent-audit/reports/2026-10-04-biweekly.json" ] && fail "odd-week run wrote a report"
run --window biweekly --end 2026-09-28 --scheduled --no-jira --no-insights
[ "$rc" -eq 0 ] && [ -f "$fx/.local/share/agent-audit/reports/2026-09-27-biweekly.json" ] \
    || fail "even ISO week should run" "$out"
run --window biweekly --end 2026-10-05 --no-jira --no-insights --dry-run
grep -q "^report: " <<<"$out" || fail "manual biweekly runs ignore parity" "$out"

# ── History: a stored report supplies the previous window and the trend ──
run --window weekly --end 2026-10-05 --no-jira --no-insights
js2="$fx/.local/share/agent-audit/reports/2026-10-04-weekly.json"
[ "$(jget "$js2" 'j["previous_source"]')" = "history (2026-09-27)" ] || fail "previous window should come from history"
[ "$(jget "$js2" '[t["label_date"] for t in j["trend"]]')" = "['2026-09-27']" ] || fail "trend should list earlier runs"

# ── Insights: one capped call; failure or timeout still yields a report ──
run --window weekly --end 2026-09-28 --dry-run --no-jira
grep -q "^insights: included" <<<"$out" || fail "insights not included" "$out"
grep -q "stub insight about alpha" "$(field report)" || fail "insights text missing from report"
args="$(tr '\n' ' ' <"$log.claude-args")"
for want in "-p" "--model sonnet" "--tools  " "--max-turns 1" "--max-budget-usd" "--no-session-persistence" "--strict-mcp-config"; do
    grep -qF -- "$want" <<<"$args" || fail "claude call missing '$want'" "$args"
done
grep -q '"calls_main"' "$log.claude-stdin" || fail "claude was not fed the metrics JSON"
STUB_CLAUDE=fail run --window weekly --end 2026-09-28 --dry-run --no-jira
[ "$rc" -eq 0 ] && grep -q "Insights unavailable: claude exited 1" "$(field report)" || fail "failed insights must not fail the run" "$out"
STUB_CLAUDE=slow AGENT_AUDIT_INSIGHTS_TIMEOUT=1 run --window weekly --end 2026-09-28 --dry-run --no-jira
[ "$rc" -eq 0 ] && grep -q "timed out" "$(field report)" || fail "timed-out insights must not fail the run" "$out"

# ── GitHub unavailable: section degrades, run succeeds ──
STUB_GH=fail run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
[ "$rc" -eq 0 ] && grep -q "Unavailable: GitHub search failed: HTTP 403" "$(field report)" || fail "gh failure should degrade" "$out"

# ── Jira dry run: payload on disk, no credentials touched ──
run --window weekly --end 2026-09-28 --dry-run --no-insights
payload="$(field jira_payload)"
[ -f "$payload" ] || fail "dry run should write the would-be Jira payload" "$out"
[ -e "$log.kubectl" ] && fail "dry run reached for Jira credentials"
[ "$(jget "$payload" 'j["fields"]["summary"]')" = "Agent usage audit — weekly ending 2026-09-27" ] || fail "Jira summary"
[ "$(jget "$payload" 'j["fields"]["labels"], j["fields"]["project"]["key"], j["fields"]["description"]["type"]')" \
    = "(['agent-audit'], 'JDWLABS', 'doc')" ] || fail "Jira payload fields"
[ "$(jget "$payload" '[b["type"] for b in j["fields"]["description"]["content"]][:3]')" = "['heading', 'paragraph', 'heading']" ] \
    || fail "report not converted to ADF"
jget "$payload" '[b for b in j["fields"]["description"]["content"] if b["type"]=="table"][0]["content"][0]["content"][0]["type"]' \
    | grep -qx tableHeader || fail "tables should convert with a header row"

# ── Jira real path against a local mock: epic found-or-created once, task parented ──
port_file="$tmp/port"
python3 - "$port_file" "$tmp/jira.log" <<'PY' &
import http.server, json, sys
port_file, log = sys.argv[1], sys.argv[2]
n = {"issue": 0}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        if self.path.startswith("/rest/api/3/search/jql"):
            resp = {"issues": []}
        else:
            n["issue"] += 1
            resp = {"key": "EPIC-1" if body["fields"]["issuetype"]["name"] == "Epic" else f"TASK-{n['issue']}"}
        data = json.dumps(resp).encode()
        self.send_response(201); self.send_header("Content-Length", str(len(data))); self.end_headers()
        self.wfile.write(data)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
mock_pid=$!
# shellcheck disable=SC2064
trap "kill $mock_pid 2>/dev/null; rm -rf '$tmp'" EXIT
for _ in $(seq 50); do [ -s "$port_file" ] && break; python3 -c 'import time; time.sleep(0.1)'; done
JIRA_URL="http://127.0.0.1:$(cat "$port_file")"
export JIRA_URL JIRA_USERNAME=user JIRA_API_TOKEN=secret-token

run --window monthly --end 2026-10-01 --no-insights
[ "$rc" -eq 0 ] || fail "filing against the mock failed" "$out"
grep -q "^jira: TASK-2 created under EPIC-1 (epic created)" <<<"$out" || fail "epic should be created, task parented" "$out"
[ "$(cat "$fx/.local/share/agent-audit/epic-key")" = "EPIC-1" ] || fail "epic key not stored in the data dir"
task="$(grep '"Task"' "$tmp/jira.log")"
grep -q '"parent": {"key": "EPIC-1"}' <<<"$task" || fail "task not parented under the epic" "$task"
grep -q '"labels": \["agent-audit"\]' <<<"$task" || fail "task missing label" "$task"
grep -qF "secret-token" <<<"$out$(cat "$tmp/stderr")" && fail "credential leaked to output"
grep -rqF "secret-token" "$fx/.local/share/agent-audit" && fail "credential persisted to the data dir"
[ "$(jget "$fx/.local/share/agent-audit/reports/2026-09-30-monthly.json" 'j["jira_key"]')" = "TASK-2" ] \
    || fail "issue key not recorded in the metrics JSON"

run --window monthly --end 2026-10-01 --no-insights
[ "$rc" -eq 0 ] && grep -q "already filed for monthly ending 2026-09-30 (no-op)" <<<"$out" \
    || fail "re-running a filed window should be a no-op" "$out"
calls_before="$(wc -l <"$tmp/jira.log")"
run --window monthly --end 2026-10-01 --no-insights --force
grep -q "^jira: TASK-3 created under EPIC-1$" <<<"$out" || fail "--force should file again with the stored epic" "$out"
[ "$(($(wc -l <"$tmp/jira.log") - calls_before))" -eq 1 ] || fail "stored epic key should skip the epic search"
unset JIRA_URL JIRA_USERNAME JIRA_API_TOKEN

echo "PASS"
