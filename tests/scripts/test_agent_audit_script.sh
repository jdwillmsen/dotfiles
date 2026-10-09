#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-audit runs unattended from timers and files Jira tickets, so every
# path that can reach the outside world is exercised here against stubs:
# synthetic transcripts for the metrics, a stub gh for PR hygiene, a stub
# claude for insights, and a local HTTP server standing in for Jira.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
audit="$here/home/dot_local/bin/executable_agent-audit"
units="$here/home/dot_config/systemd/user"
trigger="$here/home/run_onchange_52-enable-agent-audit.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$audit" ] || fail "agent-audit missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$audit" || fail "agent-audit does not parse"
shellcheck -s bash "$trigger"

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
w(".config/streams.json", json.dumps({"streams": {
    "jdwillmsen": {"jira": "JDW"}, "jdwlabs": {"jira": "JDWLABS"}, "dotablaze-tech": {"jira": "DOTA"}}}))
w("projects/jdwlabs/r1/AGENTS.md", "x" * 40000 + "\n")
w("projects/jdwillmsen/r2/AGENTS.md", "y\n")
w("projects/dotablaze-tech/r1/AGENTS.md", "z\n")

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
#!/usr/bin/env python3
# Modes: ok (fixture rows), fail, split (over the cap for multi-day ranges,
# small for single days), cap (over the cap even for single days),
# ratelimit-once (first search request 403s), ratelimit (always 403).
import datetime as dt, json, os, re, sys, time
log = os.environ["STUB_LOG"]
args = sys.argv[1:]
open(log + ".gh", "a").write(" ".join(args) + "\n")
open(log + ".gh-env", "w").write("\n".join(os.environ))
mode = os.environ.get("STUB_GH", "ok")
if args[:2] == ["api", "rate_limit"]:
    print(int(time.time()) + 1); sys.exit(0)
if mode == "fail":
    sys.stderr.write("HTTP 404: Not Found\n"); sys.exit(1)
flag = log + ".gh-limited"
if mode == "ratelimit" or (mode == "ratelimit-once" and not os.path.exists(flag)):
    open(flag, "w").close()
    sys.stderr.write("HTTP 403: API rate limit exceeded for user\n"); sys.exit(1)
ai = "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
FIXTURE = {
    "prs": [
        {"number": 1, "author": {"login": "jdwillmsen"}, "url": "u1", "body": "one two three four five six seven eight nine ten"},
        {"number": 2, "author": {"login": "jdwlabs-agent-bot[bot]"}, "url": "u2", "body": "a b c d e f g h i j k l m n o p q r s t"},
        {"number": 3, "author": {"login": "jdwillmsen"}, "url": "u3", "body": "Why it changed. Generated with Claude Code"},
        {"number": 4, "author": {"login": "renovate[bot]"}, "url": "u4", "body": "bump"}],
    "commits": [
        {"sha": "aaaaaaa111", "repository": {"fullName": "jdwlabs/r1"},
         "commit": {"message": f"feat: x\n\n{ai}\nAssisted-by: Claude Code:claude-opus-5-5"}},
        {"sha": "bbbbbbb222", "repository": {"fullName": "jdwlabs/r1"}, "commit": {"message": f"fix: y\n\n{ai}"}},
        {"sha": "ccccccc333", "repository": {"fullName": "jdwlabs/r1"}, "commit": {"message": "docs: human only"}}],
}
def total(kind, a, b):
    if mode == "cap" or (mode == "split" and b > a):
        return 1500
    return 3 if mode == "split" else len(FIXTURE[kind])
if args[0] == "api":
    q = args[args.index("-f") + 1]
    kind = "prs" if "search/issues" in args else "commits"
    a, b = (dt.date.fromisoformat(x) for x in re.search(r":(\S+)$", q).group(1).split(".."))
    print(total(kind, a, b)); sys.exit(0)
kind = args[1]
limit = int(args[args.index("--limit") + 1])
if mode in ("split", "cap"):
    if kind == "prs":
        rows = [{"number": i, "author": {"login": "jdwillmsen"}, "url": f"u{i}", "body": "w w w"} for i in range(limit)]
    else:
        rows = [{"sha": f"{i:07d}", "repository": {"fullName": "o/r"}, "commit": {"message": "m"}} for i in range(limit)]
    print(json.dumps(rows))
else:
    print(json.dumps(FIXTURE[kind][:limit]))
STUB
cat >"$stubs/claude" <<'STUB'
#!/bin/sh
printf '%s\n' "$@" >"$STUB_LOG.claude-args"
env >"$STUB_LOG.claude-env"
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
        AGENT_AUDIT_JIRA_TIMEOUT="${AGENT_AUDIT_JIRA_TIMEOUT:-30}" AGENT_AUDIT_LOCK_WAIT="${AGENT_AUDIT_LOCK_WAIT:-30}" \
        AGENT_AUDIT_JIRA_POLL="${AGENT_AUDIT_JIRA_POLL:-0.1,0.1}" AGENT_AUDIT_GH_GAP="${AGENT_AUDIT_GH_GAP:-0}" AGENT_AUDIT_GH_MAX_WAIT="${AGENT_AUDIT_GH_MAX_WAIT:-30}" \
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
check '[c["flag"] for c in j["instructions"]["combined"]]' "['', '', '', 'over_32KiB']" "combined size flag"
check '[c["set"].split(" (")[0] for c in j["instructions"]["combined"][1:]]' \
    "['codex in dotablaze-tech/r1', 'codex in jdwillmsen/r2', 'codex in jdwlabs/r1']" \
    "same-named repos under two owners get distinct combined-set labels"
check 'j["prs"]["current"]["prs"], j["prs"]["current"]["body_words_median"], j["prs"]["current"]["generated_with_footer"]' \
    "(3, 10, 1)" "PR hygiene excludes dependency bots"
check 'j["prs"]["current"]["ai_coauthored_commits"], j["prs"]["current"]["missing_assisted_by_examples"]' \
    "(2, ['jdwlabs/r1@bbbbbbb'])" "missing Assisted-by among AI commits"
grep -q -- "--created 2026-09-21..2026-09-27" "$log.gh" || fail "PR search not scoped to the window" "$(cat "$log.gh")"
check '"~/projects/jdwillmsen/r2/AGENTS.md" in [f["path"] for f in j["instructions"]["files"]]' "True" \
    "instruction files found under every owner folder"
grep -q -- "--owner jdwillmsen --owner jdwlabs --owner dotablaze-tech --created" "$log.gh" \
    || fail "PR hygiene must cover every stream in the map" "$(cat "$log.gh")"
grep -q "user:jdwillmsen user:jdwlabs user:dotablaze-tech" "$log.gh" || fail "count query must cover every stream" "$(cat "$log.gh")"
grep -q "^## PR hygiene (jdwillmsen, jdwlabs, dotablaze-tech)" "$md" || fail "report heading should name the streams measured"
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
# Fixed fortnight grid across 2026's 53-week year: consecutive fortnights
# abut and ISO weeks 52 and 53 both land in one, where ISO parity skipped 52.
[ "$(win biweekly 2026-12-28)" = "2026-12-07 2026-12-21 2026-11-23 2026-12-07" ] || fail "biweekly before the year end"
[ "$(win biweekly 2027-01-04)" = "2026-12-21 2027-01-04 2026-12-07 2026-12-21" ] || fail "biweekly over weeks 52-53"
[ "$(win biweekly 2027-01-18)" = "2027-01-04 2027-01-18 2026-12-21 2027-01-04" ] || fail "biweekly after the year end"
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

# ── Biweekly: an off-week (catch-up) run audits the missed fortnight ──
run --window biweekly --end 2026-10-05 --no-jira --no-insights
[ "$rc" -eq 0 ] && [ -f "$fx/.local/share/agent-audit/reports/2026-09-27-biweekly.json" ] \
    || fail "off-week run should audit the fortnight ending 2026-09-27" "$out"
[ -e "$fx/.local/share/agent-audit/reports/2026-10-04-biweekly.json" ] && fail "off-week run audited a half fortnight"

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
# Credentials in this process's environment never reach a child.
JIRA_API_TOKEN=secret-token JIRA_URL=http://x JIRA_USERNAME=u run --window weekly --end 2026-09-28 --dry-run --no-jira
grep -q '^JIRA_' "$log.claude-env" && fail "JIRA_* leaked into the claude call env"
grep -q '^JIRA_' "$log.gh-env" && fail "JIRA_* leaked into the gh env"
grep -q '^STUB_LOG' "$log.gh-env" || fail "child env check is vacuous: the stub saw no environment"
# A --no-insights retry keeps commentary the first attempt already paid for.
run --window weekly --end 2026-09-28 --no-jira
run --window weekly --end 2026-09-28 --no-jira --no-insights
grep -q "stub insight about alpha" "$md" || fail "--no-insights retry dropped existing insights"
STUB_CLAUDE=fail run --window weekly --end 2026-09-28 --dry-run --no-jira
[ "$rc" -eq 0 ] && grep -q "Insights unavailable: claude exited 1" "$(field report)" || fail "failed insights must not fail the run" "$out"
STUB_CLAUDE=slow AGENT_AUDIT_INSIGHTS_TIMEOUT=1 run --window weekly --end 2026-09-28 --dry-run --no-jira
[ "$rc" -eq 0 ] && grep -q "timed out" "$(field report)" || fail "timed-out insights must not fail the run" "$out"

# ── GitHub unavailable: section degrades, run succeeds ──
STUB_GH=fail run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
[ "$rc" -eq 0 ] && grep -q "Errored.*GitHub search failed: HTTP 404" "$(field report)" || fail "gh failure should degrade" "$out"
grep -q "^pr_hygiene: \"errored: " <<<"$out" || fail "errored PR hygiene must show in the summary" "$out"

# ── Stream map missing or broken: errored, never a guessed owner list ──
mv "$fx/.config/streams.json" "$tmp/streams.json"
for broken in missing "not json" '{"streams": {}}' '{"streams": {"jdwlabs": {}, "bad owner": {}}}'; do
    [ "$broken" = missing ] || echo "$broken" >"$fx/.config/streams.json"
    : >"$log.gh"
    run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
    [ "$rc" -eq 0 ] && grep -q "^pr_hygiene: \"errored: stream map " <<<"$out" \
        || fail "stream map $broken: PR hygiene must report errored" "$out"
    grep -q "^## PR hygiene$" "$(field report)" || fail "stream map $broken: heading claims owners it did not measure" "$(grep '^## PR' "$(field report)")"
    grep -q "Errored.*stream map" "$(field report)" || fail "stream map $broken: report must say why PR hygiene is errored"
    grep -q -e "--owner" -e "user:" "$log.gh" && fail "stream map $broken: no owner may be searched" "$(cat "$log.gh")"
done
mv "$tmp/streams.json" "$fx/.config/streams.json"

# ── GitHub rate limit: wait for the reset and retry; errored if it persists ──
rm -f "$log.gh-limited"
STUB_GH=ratelimit-once run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
grep -q "^pr_hygiene: 3 PRs" <<<"$out" || fail "a rate-limited search should be retried after the reset" "$out"
grep -q -- "--created 2026-09-21..2026-09-27 --limit 4 " "$log.gh" || fail "fetch should request only the counted rows"
grep -q "rate limited; waiting" "$tmp/stderr" || fail "rate-limit wait not logged"
grep -q "api rate_limit" "$log.gh" || fail "reset time should come from the rate_limit endpoint"
STUB_GH=ratelimit AGENT_AUDIT_GH_MAX_WAIT=2 run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
[ "$rc" -eq 0 ] && grep -q "still rate limited" "$(field report)" || fail "persistent rate limit should mark the section errored" "$out"

# ── GitHub search cap: full slices are split until under 1000 ──
STUB_GH="split" run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
[ "$(jget "$(field metrics)" 'j["prs"]["current"]["prs"], j["prs"]["current"]["truncated"]')" = "(21, False)" ] \
    || fail "a capped week should split into 7 complete days"
grep -q "Truncated" "$(field report)" && fail "complete split results must not be marked truncated"
STUB_GH=cap run --window weekly --end 2026-09-28 --dry-run --no-jira --no-insights
[ "$(jget "$(field metrics)" 'j["prs"]["current"]["truncated"]')" = "True" ] || fail "a full single day must mark truncated"
grep -q "^\*\*Truncated:\*\*" "$(field report)" || fail "truncation should be called out in the report"

# ── Jira dry run: payload on disk, no credentials touched ──
run --window weekly --end 2026-09-28 --dry-run --no-insights
payload="$(field jira_payload)"
[ -f "$payload" ] || fail "dry run should write the would-be Jira payload" "$out"
[ -e "$log.kubectl" ] && fail "dry run reached for Jira credentials"
[ "$(jget "$payload" 'j["fields"]["summary"]')" = "Agent usage audit — weekly ending 2026-09-27" ] || fail "Jira summary"
[ "$(jget "$payload" 'j["fields"]["labels"], j["fields"]["project"]["key"], j["fields"]["description"]["type"]')" \
    = "(['agent-audit'], 'JDW', 'doc')" ] || fail "Jira payload fields"
[ "$(jget "$payload" '[b["type"] for b in j["fields"]["description"]["content"]][:3]')" = "['heading', 'paragraph', 'heading']" ] \
    || fail "report not converted to ADF"
jget "$payload" '[b for b in j["fields"]["description"]["content"] if b["type"]=="table"][0]["content"][0]["content"][0]["type"]' \
    | grep -qx tableHeader || fail "tables should convert with a header row"

# ── Jira real path against a local mock: epic found-or-created once, task parented ──
port_file="$tmp/port"
python3 - "$port_file" "$tmp/jira.log" <<'PY' &
import http.server, json, sys
port_file, log = sys.argv[1], sys.argv[2]
import os, time
n = {"issue": 0}
issues = []
mode_file = os.path.join(os.path.dirname(log), "jira.mode")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "body": body}) + "\n")
        if self.path.startswith("/rest/api/3/search/jql") and \
                os.path.exists(os.path.join(os.path.dirname(log), "jira.search-fail")):
            self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers()
            return
        if self.path.startswith("/rest/api/3/search/jql"):
            want = "Epic" if "issuetype = Epic" in body["jql"] else "Task"
            # jira.hide simulates search lagging behind a create.
            hidden = want == "Task" and os.path.exists(os.path.join(os.path.dirname(log), "jira.hide"))
            resp = {"issues": [] if hidden else
                    [{"key": k, "fields": {"summary": sm}} for k, t, sm in issues if t == want]}
        else:
            n["issue"] += 1
            kind = body["fields"]["issuetype"]["name"]
            key = f"{body['fields']['project']['key']}-1" if kind == "Epic" else f"TASK-{n['issue']}"
            issues.append((key, kind, body["fields"]["summary"]))
            resp = {"key": key}
            mode = open(mode_file).read().strip() if os.path.exists(mode_file) else ""
            if kind == "Task" and mode == "nonjson":
                os.remove(mode_file)
                self.send_response(201); self.send_header("Content-Length", "6"); self.end_headers()
                self.wfile.write(b"<html>"); return
            if kind == "Task" and mode == "slow-once":
                os.remove(mode_file)
                time.sleep(3)  # created server-side, but the client gives up first
        data = json.dumps(resp).encode()
        try:
            self.send_response(201); self.send_header("Content-Length", str(len(data))); self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
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
grep -q "^jira: TASK-2 created under JDW-1 (epic created)" <<<"$out" || fail "epic should be created, task parented" "$out"
[ "$(cat "$fx/.local/share/agent-audit/epic-key")" = "JDW-1" ] || fail "epic key not stored in the data dir"
task="$(grep '"Task"' "$tmp/jira.log")"
grep -q '"parent": {"key": "JDW-1"}' <<<"$task" || fail "task not parented under the epic" "$task"
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
grep -q "^jira: TASK-3 created under JDW-1$" <<<"$out" || fail "--force should file again with the stored epic" "$out"
[ "$(($(wc -l <"$tmp/jira.log") - calls_before))" -eq 1 ] || fail "stored epic key should skip the epic search"

# A create that times out but landed is found by summary, not filed twice.
echo slow-once >"$tmp/jira.mode"
AGENT_AUDIT_JIRA_TIMEOUT=1 run --window monthly --end 2026-09-01 --no-insights
grep -q "^jira: TASK-4 created under JDW-1$" <<<"$out" || fail "timed-out create should resolve to the landed issue" "$out"
[ "$(grep '"path": "/rest/api/3/issue"' "$tmp/jira.log" | grep -c 'monthly ending 2026-08-31"')" -eq 1 ] \
    || fail "timed-out create was retried into a duplicate"
grep -q 'created >= -15m' "$tmp/jira.log" || fail "dedup search should be limited to recent issues"

# A timed-out create that search cannot see yet is not re-POSTed; the run
# stops with the report saved, and the re-run finds the issue first.
echo slow-once >"$tmp/jira.mode"
touch "$tmp/jira.hide"
AGENT_AUDIT_JIRA_TIMEOUT=1 run --window monthly --end 2026-07-01 --no-insights
[ "$rc" -eq 1 ] && grep -q "^jira: create timed out and .* re-run to file" <<<"$out" || fail "invisible timed-out create should stop" "$out"
june="$fx/.local/share/agent-audit/reports/2026-06-30-monthly.json"
[ "$(jget "$june" 'j.get("jira_pending"), j.get("jira_key")')" = "(True, None)" ] || fail "pending create not recorded"
creates() { grep '"path": "/rest/api/3/issue"' "$tmp/jira.log" | grep -c 'monthly ending 2026-06-30"'; }
[ "$(creates)" -eq 1 ] || fail "timed-out create was re-POSTed"
[ "$(grep -c 'created >= -15m' "$tmp/jira.log")" -ge 3 ] || fail "search should be polled with backoff"
# While a create is pending, a re-run whose searches all fail stays pending.
touch "$tmp/jira.search-fail"
run --window monthly --end 2026-07-01 --no-insights
[ "$rc" -eq 1 ] && grep -q "Jira search unavailable while resolving a pending create" <<<"$out" \
    || fail "pending create with failing search should stay pending" "$out"
[ "$(creates)" -eq 1 ] || fail "pending create was re-filed while search was down"
[ "$(jget "$june" 'j.get("jira_pending")')" = "True" ] || fail "pending marker lost"
rm "$tmp/jira.search-fail" "$tmp/jira.hide"
run --window monthly --end 2026-07-01 --no-insights
[ "$rc" -eq 0 ] || fail "re-run after a pending create failed" "$out"
[ "$(creates)" -eq 1 ] || fail "re-run filed a duplicate instead of finding the landed issue"
[ "$(jget "$june" 'j.get("jira_pending"), j["jira_key"]')" = "(None, 'TASK-5')" ] || fail "re-run should adopt the landed issue"

# Recovery searches that fail outright after a timed-out create still save
# the pending marker instead of escaping through the generic error path.
echo slow-once >"$tmp/jira.mode"
touch "$tmp/jira.search-fail"
AGENT_AUDIT_JIRA_TIMEOUT=1 run --window monthly --end 2026-06-01 --no-insights
rm "$tmp/jira.search-fail"
[ "$rc" -eq 1 ] && grep -q "^jira: create timed out and" <<<"$out" || fail "failed recovery search should report a timed-out create" "$out"
[ "$(jget "$fx/.local/share/agent-audit/reports/2026-05-31-monthly.json" 'j.get("jira_pending")')" = "True" ] \
    || fail "failed recovery search must still save the pending marker"

# A non-JSON reply is a structured failure, not a traceback.
echo nonjson >"$tmp/jira.mode"
run --window monthly --end 2026-08-01 --no-insights
[ "$rc" -eq 1 ] && grep -q "^jira: \"failed: Jira POST /rest/api/3/issue returned a non-JSON body" <<<"$out" \
    || fail "non-JSON Jira reply should fail cleanly" "$out"
grep -q Traceback "$tmp/stderr" && fail "non-JSON Jira reply produced a traceback" "$(cat "$tmp/stderr")"

# A stored epic key from another project is not trusted: the epic is looked
# up again in the filing project and the stored key replaced.
epic_file="$fx/.local/share/agent-audit/epic-key"
echo "JDWLABS-697" >"$epic_file"
run
grep -q "JDWLABS-697" <<<"$out" && fail "home view should not show an epic key from another project" "$out"
run --window weekly --end 2026-09-28 --dry-run --no-insights
grep -q "JDWLABS-697" <<<"$out" && fail "dry run should not parent under an epic key from another project" "$out"
[ "$(cat "$epic_file")" = "JDWLABS-697" ] || fail "dry run and home view must not rewrite the stored epic key"
calls_before="$(wc -l <"$tmp/jira.log")"
run --window monthly --end 2026-10-01 --no-insights --force
[ "$rc" -eq 0 ] || fail "filing with a stale stored epic key failed" "$out"
grep -Eq "^jira: TASK-[0-9]+ created under JDW-1$" <<<"$out" || fail "stale stored epic key should resolve to the epic in JDW" "$out"
[ "$(cat "$epic_file")" = "JDW-1" ] || fail "stale stored epic key was not replaced"
stale_calls="$(tail -n +"$((calls_before + 1))" "$tmp/jira.log")"
grep -q 'project = JDW AND issuetype = Epic' <<<"$stale_calls" || fail "epic should be searched for in JDW" "$stale_calls"
grep -q '"issuetype": {"name": "Epic"}' <<<"$stale_calls" && fail "existing epic was duplicated" "$stale_calls"
grep '"issuetype": {"name": "Task"}' <<<"$stale_calls" | grep -q '"parent": {"key": "JDW-1"}' \
    || fail "task not parented under the epic found in JDW" "$stale_calls"

# Lock: a run waiting on a concurrent one re-checks and no-ops once that one filed.
js3="$fx/.local/share/agent-audit/reports/2026-09-27-weekly.json"
python3 - "$fx/.local/share/agent-audit/.weekly.lock" "$js3" <<'PY' &
import fcntl, json, sys, time
lock = open(sys.argv[1], "w"); fcntl.flock(lock, fcntl.LOCK_EX)
time.sleep(2)
j = json.load(open(sys.argv[2])); j["jira_key"] = "TASK-99"; json.dump(j, open(sys.argv[2], "w"))
PY
holder=$!
python3 -c 'import time; time.sleep(0.5)'
run --window weekly --end 2026-09-28 --no-insights
wait "$holder"
grep -q "TASK-99 already filed" <<<"$out" || fail "lock waiter should re-check and no-op" "$out"
unset JIRA_URL JIRA_USERNAME JIRA_API_TOKEN

# ── Units: template service + four calendar timers ──
svc="$units/agent-audit@.service"
grep -qx 'ExecStart=%h/.local/bin/agent-audit --window %i' "$svc" || fail "service ExecStart"
grep -qx 'NoNewPrivileges=yes' "$svc" && grep -qx 'PrivateTmp=yes' "$svc" || fail "service hardening missing"
grep -q '^TimeoutStartSec=' "$svc" || fail "service needs a hard timeout"
declare -A cal=([weekly]="Mon *-*-* 08:00:00" [biweekly]="Mon *-*-* 08:15:00"
    [monthly]="*-*-01 08:30:00" [quarterly]="*-01,04,07,10-01 09:00:00")
for w in "${!cal[@]}"; do
    t="$units/agent-audit-$w.timer"
    [ -f "$t" ] || fail "missing $(basename "$t")"
    grep -qxF "OnCalendar=${cal[$w]}" "$t" || fail "$w timer calendar"
    grep -qx "Unit=agent-audit@$w.service" "$t" || fail "$w timer target"
    grep -qx "Persistent=true" "$t" || fail "$w timer must catch up after downtime"
    grep -qx "WantedBy=timers.target" "$t" || fail "$w timer install target"
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze calendar "${cal[$w]}" >/dev/null || fail "$w calendar rejected by systemd"
    fi
done

# ── Trigger: stubbed systemctl/loginctl ──
trig="$tmp/trig"
mkdir -p "$trig/bin" "$trig/home/.config/systemd/user"
cp "$svc" "$trig/home/.config/systemd/user/"
cat >"$trig/bin/systemctl" <<'STUB'
#!/bin/sh
if [ "$2" = "show-environment" ]; then echo "HOME=$STUB_MANAGER_HOME"; exit 0; fi
echo "$*" >>"$CALL_LOG"
STUB
cat >"$trig/bin/loginctl" <<'STUB'
#!/bin/sh
echo "${STUB_LINGER:-no}"
STUB
chmod +x "$trig/bin"/*
run_trigger() {  # $1 manager home, $2 linger
    : >"$trig/calls"
    trig_out="$(PATH="$trig/bin:/usr/bin:/bin" HOME="$trig/home" USER=tester BASH_ENV=/dev/null \
        XDG_CONFIG_HOME="$trig/home/.config" CALL_LOG="$trig/calls" STUB_MANAGER_HOME="$1" \
        STUB_LINGER="$2" bash "$trigger" 2>&1)"
}
run_trigger /elsewhere no
grep -q "skipping enable" <<<"$trig_out" && [ ! -s "$trig/calls" ] || fail "trigger must skip a scratch-dest apply" "$trig_out"
run_trigger "$trig/home" no
grep -qx -- "--user daemon-reload" "$trig/calls" || fail "trigger never reloads systemd"
grep -qx -- "--user enable --now agent-audit-weekly.timer agent-audit-biweekly.timer agent-audit-monthly.timer agent-audit-quarterly.timer" \
    "$trig/calls" || fail "trigger does not enable all four timers" "$(cat "$trig/calls")"
grep -q "start" "$trig/calls" && fail "trigger must not start an audit (each run files a ticket)"
grep -q "linger is off" <<<"$trig_out" || fail "trigger should warn when linger is off"
run_trigger "$trig/home" yes
grep -q "linger is off" <<<"$trig_out" && fail "no linger warning expected when linger is on"

echo "PASS"
