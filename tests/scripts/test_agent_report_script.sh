#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-report reads a store, shells out to gh and claude, and pushes to a git
# remote, so everything it touches is redirected here: a fixture store with a
# local bare remote, stub gh and claude executables, a fixture no-mistakes
# database and a fixed clock.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
report="$here/home/dot_local/bin/executable_agent-report"
metrics="$here/home/dot_local/bin/executable_agent-metrics"
cfgsrc="$here/home/dot_config/agent-metrics"
units="$here/home/dot_config/systemd/user"
trigger="$here/home/run_onchange_54-enable-agent-report.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$report" ] || fail "agent-report missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$report" || fail "agent-report does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
fx="$tmp/home"
remote="$tmp/remote.git"
store="$tmp/store"
mkdir -p "$fx/.config" "$tmp/config" "$tmp/bin" "$tmp/state"
cp "$cfgsrc"/*.json "$tmp/config/"
python3 - "$tmp/config/config.json" "$remote" <<'PY'
import json, sys
json.dump({"store_remote": sys.argv[2]}, open(sys.argv[1], "w"))
PY
echo '{"streams": {"acme": {}, "acme-labs": {}}}' >"$fx/.config/streams.json"

export HOME="$fx"
export CLAUDE_CONFIG_DIR="$fx/.claude"
export AGENT_METRICS_STORE="$store"
export AGENT_METRICS_STATE="$tmp/state"
export AGENT_METRICS_CONFIG="$tmp/config"
export AGENT_METRICS_NOW="2026-10-09T12:00:00+00:00"
export AGENT_REPORT_AUDIT_DIR="$tmp/audit-reports"
export AGENT_REPORT_NM_DB="$tmp/no-mistakes.sqlite"
export AGENT_REPORT_GH_GAP=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export PATH="$tmp/bin:$PATH"

out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$report" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-report $* exited $got, want $want" "$(cat "$out" "$err")"
}
field() { sed -n "s/^$1: //p" "$out" | head -1; }

# The store does not exist yet: the home view says so and a run names the fix.
run 0
grep -q "store not cloned" "$out" || fail "home view does not say the store is missing" "$(cat "$out")"
run 2 --window daily
grep -q "agent-metrics init" "$out" || fail "a missing store does not name agent-metrics init" "$(cat "$out")"

gs() { git -C "$store" "$@"; }

# reset_store: a fresh bare remote and clone holding the fixture below, so each
# scenario starts from the same history and a run's commits never leak across.
reset_store() {
    rm -rf "$store" "$remote" "$tmp/state"/* "$fx/.local"
    git init -q --bare -b main "$remote"
    git clone -q "$remote" "$store" 2>/dev/null
    python3 "$tmp/fixture.py" "$store"
    gs add -A
    gs commit -q -m "fixture"
    gs push -q -u origin HEAD
}

cat >"$tmp/fixture.py" <<'PY'
import json, os, sys
store = sys.argv[1]

def row(sid, started, pop, cost, pipeline=None, repo=None, main=None, sub=None, **kw):
    r = {"schema": 1, "session_id": sid, "started_at": started, "ended_at": started, "population": pop,
         "pipeline": pipeline, "repo": repo, "cost_usd": cost, "unpriced_models": [],
         "models": {"main": main or {}, "subagent": sub or {}},
         "active_s": 0, "idle_s": 0, "wait_human_s": 0, "interrupts": 0, "tool_errors": 0, "denials": 0,
         "rate_limits": 0, "api_errors": 0, "compactions": 0, "commits": 0, "pushes": 0, "prs_created": 0,
         "pr_links": [], "skills": {}, "tools": {}, "mcp": {}, "subagent_types": {}, "cache_read_share": None}
    r.update(kw)
    return r

def model(calls, cost, inp=0, out=0, cr=0, w5=0, w1=0):
    return {"calls": calls, "cost_usd": cost, "input": inp, "output": out, "cache_read": cr,
            "cache_write_5m": w5, "cache_write_1h": w1}

OPUS, SONNET, HAIKU = "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5-20251001"
sessions = [
    row("s-b0", "2026-09-12T00:00:00Z", "scripted", 1000.0),
    row("s-p1", "2026-09-22T09:00:00Z", "interactive", 1.0, main={OPUS: model(2, 1.0, 10, 5, 90)}),
    row("s-p2", "2026-09-27T23:59:59Z", "scripted", 4.0, pipeline="no-mistakes"),
    row("s-w1", "2026-09-29T10:00:00Z", "interactive", 2.0, repo="acme/app",
        main={OPUS: model(10, 1.5, 100, 500, 800, 100)}, sub={HAIKU: model(4, 0.5)},
        active_s=600, idle_s=400, wait_human_s=300, tool_errors=2, denials=1, interrupts=1,
        commits=2, pushes=1, prs_created=1, pr_links=[{"repo": "acme/app", "number": 7}],
        skills={"brainstorm": 2}, tools={"Bash": 5, "Read": 3}, mcp={"jira": 1}, subagent_types={"Explore": 2}),
    row("s-w3", "2026-09-30T23:59:59Z", "scripted", 5.0, pipeline="no-mistakes",
        main={OPUS: model(20, 5.0, 200, 0, 1800)}, active_s=50, api_errors=3),
]
sessions_oct = [
    row("s-w2", "2026-10-01T08:00:00Z", "interactive", 3.0, repo="acme/app",
        main={SONNET: model(5, 3.0, 50, 10, 150)}, active_s=100, rate_limits=1, compactions=1, commits=1,
        pr_links=[{"repo": "acme/app", "number": 7}, {"repo": "acme/app", "number": 8}],
        skills={"brainstorm": 1, "tdd": 1}, tools={"Bash": 2}),
    row("s-w4", "2026-10-04T23:59:59Z", "scripted", 1.0, main={HAIKU: model(1, 1.0)}),
    row("s-x1", "2026-10-05T00:00:00Z", "scripted", 7.0),
    row("s-d0", "2026-10-07T09:00:00Z", "interactive", 5.0),
    row("s-d1", "2026-10-08T10:00:00Z", "interactive", 30.0),
    row("s-d2", "2026-10-08T11:00:00Z", "scripted", 60.0, pipeline="no-mistakes", repo="acme/app"),
    row("s-d3", "2026-10-08T12:00:00Z", "scripted", 1.0, main={OPUS: model(600, 1.0)}),
]
past = 1780000000  # long before the fixture clock, so no quota hold applies
quota_sep = [{"hour": "2026-09-30T10:00:00Z", "readings": 3, "five_hour_pct": 90, "seven_day_pct": 70,
              "seven_day_resets_at": past}]
quota_oct = [
    {"hour": "2026-10-01T05:00:00Z", "readings": 1, "five_hour_pct": 40, "seven_day_pct": 60, "seven_day_resets_at": past},
    {"hour": "2026-10-03T05:00:00Z", "readings": 1, "five_hour_pct": 75, "seven_day_pct": 88, "seven_day_resets_at": past},
    {"hour": "2026-10-05T00:00:00Z", "readings": 1, "five_hour_pct": 99, "seven_day_pct": 10, "seven_day_resets_at": past},
    {"hour": "2026-10-08T09:00:00Z", "readings": 1, "five_hour_pct": 20, "seven_day_pct": 91, "seven_day_resets_at": past},
]
ledger_sep = [{"at": "2026-09-30T12:00:00Z", "run": "weekly", "usd": 0.1, "critical": False}]
ledger_oct = [{"at": "2026-10-02T12:00:00Z", "run": "weekly", "usd": 0.2, "critical": False},
              {"at": "2026-10-06T12:00:00Z", "run": "weekly", "usd": 0.3, "critical": False}]

def write(rel, objs):
    p = os.path.join(store, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        for o in objs:
            f.write(json.dumps(o, sort_keys=True) + "\n")

write("sessions/2026-09.jsonl", sessions)
write("sessions/2026-10.jsonl", sessions_oct)
write("quota/2026-09.jsonl", quota_sep)
write("quota/2026-10.jsonl", quota_oct)
write("ledger/2026-09.jsonl", ledger_sep)
write("ledger/2026-10.jsonl", ledger_oct)

def stored(label, window, inter, script):
    pop = lambda n, c: {"sessions": n, "cost_usd": c}
    return {"schema": 1, "window": window, "label_date": label,
            "current": {"populations": {"interactive": pop(*inter), "scripted": pop(*script)}}, "flags": []}

def daily(label, flags, state):
    d = stored(label, "daily", (0, 0), (0, 0))
    d["flags"] = flags
    d["current"]["budget"] = {"state": state}
    return d

flag = lambda i, sev, metric: {"id": i, "severity": sev, "metric": metric, "message": "m", "value": 1, "baseline": 1}
for name, obj in [
    ("2026-09-13-weekly", stored("2026-09-13", "weekly", (4, 8.0), (30, 40.0))),
    ("2026-09-20-weekly", stored("2026-09-20", "weekly", (5, 9.5), (31, 41.0))),
    ("2026-10-04-weekly", stored("2026-10-04", "weekly", (9, 99.0), (9, 99.0))),
    ("2026-09-10-daily", daily("2026-09-10", [flag("day-spend", "warn", "day_spend_usd")], "ok")),
    ("2026-09-11-daily", daily("2026-09-11", [flag("day-spend", "critical", "day_spend_usd"),
                                              flag("session-cost:x", "warn", "session_cost_usd")], "critical-only")),
    ("2026-09-12-daily", daily("2026-09-12", [], "stopped")),
]:
    p = os.path.join(store, "reports", name + ".json")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(obj, open(p, "w"))
PY
reset_store

# ── CLI surface ──
run 0 --help
grep -q -- "--window" "$out" || fail "--help does not list --window" "$(cat "$out")"
run 0 --version
run 0
grep -q "^store:" "$out" || fail "home view does not report the store" "$(cat "$out")"
grep -q "2026-10-04-weekly\|2026-10-04" "$out" || fail "home view does not list recent reports" "$(cat "$out")"
run 2 --window fortnightly
grep -q "^error:" "$out" || fail "a bad window does not print a structured error" "$(cat "$out")"
run 2 --window daily --end 2026-13-45
grep -q "YYYY-MM-DD" "$out" || fail "a bad --end is not explained" "$(cat "$out")"
run 2 --frobnicate

# ── Window arithmetic (UTC, end exclusive, label = last day inside) ──
win() {  # window end start end label prev-start
    run 0 --window "$1" --end "$2" --dry-run --no-insights --no-github
    local got
    got="$(field start) $(field end) $(field label_date) $(field previous_start)"
    [ "$got" = "$3 $4 $5 $6" ] || fail "$1 window for --end $2: got '$got', want '$3 $4 $5 $6'"
}
win daily 2026-10-09 2026-10-08 2026-10-09 2026-10-08 2026-10-07
win daily 2026-01-01 2025-12-31 2026-01-01 2025-12-31 2025-12-30
win daily 2024-03-01 2024-02-29 2024-03-01 2024-02-29 2024-02-28
win weekly 2026-10-09 2026-09-28 2026-10-05 2026-10-04 2026-09-21
win weekly 2026-10-05 2026-09-28 2026-10-05 2026-10-04 2026-09-21
win weekly 2026-01-01 2025-12-22 2025-12-29 2025-12-28 2025-12-15
win biweekly 2026-10-05 2026-09-14 2026-09-28 2026-09-27 2026-08-31
win biweekly 2026-10-12 2026-09-28 2026-10-12 2026-10-11 2026-09-14
win biweekly 2027-01-04 2026-12-21 2027-01-04 2027-01-03 2026-12-07
win biweekly 2026-12-28 2026-12-07 2026-12-21 2026-12-20 2026-11-23
win monthly 2026-10-09 2026-09-01 2026-10-01 2026-09-30 2026-08-01
win monthly 2026-01-15 2025-12-01 2026-01-01 2025-12-31 2025-11-01
win monthly 2026-03-01 2026-02-01 2026-03-01 2026-02-28 2026-01-01
win quarterly 2026-10-09 2026-07-01 2026-10-01 2026-09-30 2026-04-01
win quarterly 2026-01-15 2025-10-01 2026-01-01 2025-12-31 2025-07-01
win quarterly 2026-06-30 2026-01-01 2026-04-01 2026-03-31 2025-10-01
win yearly 2026-10-09 2025-01-01 2026-01-01 2025-12-31 2024-01-01
win yearly 2026-01-01 2025-01-01 2026-01-01 2025-12-31 2024-01-01

# ── Thresholds: unreadable or nonsensical config is a setup error, never a default ──
cp "$tmp/config/thresholds.json" "$tmp/thresholds.bak"
rm "$tmp/config/thresholds.json"
run 2 --window daily --dry-run
grep -q "thresholds.json" "$out" || fail "a missing thresholds.json is not named" "$(cat "$out")"
echo '{"spend_warn_multiple": "lots"}' >"$tmp/config/thresholds.json"
run 2 --window daily --dry-run
grep -q "thresholds.json" "$out" || fail "a malformed thresholds.json is not named" "$(cat "$out")"
python3 - "$tmp/thresholds.bak" "$tmp/config/thresholds.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["session_warn_usd"] = -5
json.dump(t, open(sys.argv[2], "w"))
PY
run 2 --window daily --dry-run
grep -q "session_warn_usd" "$out" || fail "a negative threshold is not named" "$(cat "$out")"
cp "$tmp/thresholds.bak" "$tmp/config/thresholds.json"

# ── Store metrics, hand-computed from the fixture ──
run 0 --window weekly --end 2026-10-09 --dry-run --no-insights --no-github
wjson="$(field json)"
[ -f "$wjson" ] || fail "dry run did not print a JSON path that exists" "$(cat "$out")"
python3 - "$wjson" <<'PY' || fail "weekly store metrics are wrong"
import json, sys
j = json.load(open(sys.argv[1]))
for k in ("schema", "window", "start", "end", "label_date", "generated_at", "current", "previous", "trend",
          "flags", "delivery", "audit", "insights"):
    assert k in j, f"top-level key {k} missing"
assert (j["schema"], j["window"], j["start"], j["end"], j["label_date"]) == (1, "weekly", "2026-09-28", "2026-10-05", "2026-10-04")
cur, prev = j["current"], j["previous"]
i, s = cur["populations"]["interactive"], cur["populations"]["scripted"]
def eq(name, got, want):
    assert got == want, f"{name}: got {got!r}, want {want!r}"
# The 10-05 00:00:00 session belongs to the next window; 09-30 23:59:59 and 10-04 23:59:59 are inside.
eq("sessions", (i["sessions"], s["sessions"]), (2, 2))
eq("cost", (i["cost_usd"], s["cost_usd"]), (5.0, 6.0))
eq("cost_by_pipeline", (i["cost_by_pipeline"], s["cost_by_pipeline"]), ({"none": 5.0}, {"no-mistakes": 5.0, "none": 1.0}))
eq("models", i["models"], [
    {"model": "claude-sonnet-5-5", "main_calls": 5, "main_cost_usd": 3.0, "subagent_calls": 0, "subagent_cost_usd": 0.0},
    {"model": "claude-opus-5-5", "main_calls": 10, "main_cost_usd": 1.5, "subagent_calls": 0, "subagent_cost_usd": 0.0},
    {"model": "claude-haiku-4-5-20251001", "main_calls": 0, "main_cost_usd": 0.0, "subagent_calls": 4, "subagent_cost_usd": 0.5}])
eq("cache", (i["cache_read_share"], s["cache_read_share"]), (0.7917, 0.9))
eq("friction i", i["friction"], {"tool_errors": 2, "denials": 1, "rate_limits": 1, "api_errors": 0, "compactions": 1, "interrupts": 1})
eq("friction s", s["friction"], {"tool_errors": 0, "denials": 0, "rate_limits": 0, "api_errors": 3, "compactions": 0, "interrupts": 0})
eq("output i", i["output"], {"commits": 3, "pushes": 1, "prs_created": 1, "linked_prs": 2})
eq("linked cost", i["linked_pr_cost"], {"covered_cost_usd": 5.0, "cost_per_linked_pr_usd": 2.5, "share_of_spend": 1.0})
eq("linked cost none", s["linked_pr_cost"], {"covered_cost_usd": 0.0, "cost_per_linked_pr_usd": None, "share_of_spend": 0.0})
eq("time", i["time"], {"active_s": 700, "idle_s": 400, "wait_human_s": 300})
eq("top skills", i["top"]["skills"], [{"name": "brainstorm", "count": 3}, {"name": "tdd", "count": 1}])
eq("top tools", i["top"]["tools"], [{"name": "Bash", "count": 7}, {"name": "Read", "count": 3}])
eq("top mcp", i["top"]["mcp"], [{"name": "jira", "count": 1}])
eq("top subagents", i["top"]["subagent_types"], [{"name": "Explore", "count": 2}])
# Peaks come from readings inside the window only: the 10-05 reading (99%) is outside.
eq("quota", cur["quota"], {"peak_five_hour_pct": 90, "peak_seven_day_pct": 88, "readings": 3})
eq("ledger", cur["ledger"], {"usd": 0.3, "entries": 2})
pi, ps = prev["populations"]["interactive"], prev["populations"]["scripted"]
eq("prev", (pi["sessions"], pi["cost_usd"], ps["sessions"], ps["cost_usd"]), (1, 1.0, 1, 4.0))
eq("prev quota", prev["quota"], {"peak_five_hour_pct": None, "peak_seven_day_pct": None, "readings": 0})
eq("prev ledger", prev["ledger"], {"usd": 0.0, "entries": 0})
eq("prev window", (prev["start"], prev["end"]), ("2026-09-21", "2026-09-28"))
eq("trend", j["trend"], [
    {"label_date": "2026-09-13", "interactive": {"sessions": 4, "cost_usd": 8.0}, "scripted": {"sessions": 30, "cost_usd": 40.0}},
    {"label_date": "2026-09-20", "interactive": {"sessions": 5, "cost_usd": 9.5}, "scripted": {"sessions": 31, "cost_usd": 41.0}}])
PY

# An empty window is reported as empty, with unknowns left null rather than zero.
run 0 --window daily --end 2026-10-03 --dry-run --no-insights
python3 - "$(field json)" <<'PY' || fail "an empty day is mishandled"
import json, sys
c = json.load(open(sys.argv[1]))["current"]
i = c["populations"]["interactive"]
assert i["sessions"] == 0 and i["cost_usd"] == 0.0 and i["cache_read_share"] is None, i
assert c["quota"]["peak_seven_day_pct"] is None, c["quota"]
PY

# Store data that cannot be read as numbers is an error naming the file, never zero.
cp "$store/sessions/2026-09.jsonl" "$tmp/sessions-09.bak"
sed -i 's/"cost_usd": 2.0/"cost_usd": "two"/' "$store/sessions/2026-09.jsonl"
run 2 --window weekly --end 2026-10-09 --dry-run --no-insights --no-github
grep -q "2026-09.jsonl" "$out" || fail "a bad cost_usd does not name the file" "$(cat "$out")"
cp "$tmp/sessions-09.bak" "$store/sessions/2026-09.jsonl"
echo '{"hour":"2026-10-01T05:00:00Z","seven_day_pct":"high"}' >>"$store/quota/2026-10.jsonl"
run 2 --window weekly --end 2026-10-09 --dry-run --no-insights --no-github
grep -q "quota/2026-10.jsonl" "$out" || fail "a bad quota reading does not name the file" "$(cat "$out")"
reset_store

# ── Flags: deterministic thresholds on the daily window ──
flagsfile="$tmp/state/flags.json"
run 0 --window daily --end 2026-10-09 --no-insights
[ -f "$flagsfile" ] || fail "a daily run with flags did not write flags.json" "$(cat "$out" "$err")"
python3 - "$flagsfile" "$store/reports/2026-10-08-daily.json" <<'PY' || fail "daily flags are wrong"
import json, sys
f = json.load(open(sys.argv[1]))
assert sorted(f) == ["date", "flags", "window"], sorted(f)
assert (f["date"], f["window"]) == ("2026-10-08", "daily"), f
for x in f["flags"]:
    assert sorted(x) == ["baseline", "id", "message", "metric", "severity", "value"], sorted(x)
by = {x["id"]: x for x in f["flags"]}
assert sorted(by) == ["day-spend", "runaway-calls:s-d3", "session-cost:s-d2", "weekly-quota"], sorted(by)
assert (by["day-spend"]["severity"], by["day-spend"]["metric"], by["day-spend"]["value"], by["day-spend"]["baseline"]) \
    == ("critical", "day_spend_usd", 91.0, 2.2857), by["day-spend"]
assert "39.8x" in by["day-spend"]["message"], by["day-spend"]["message"]
assert (by["session-cost:s-d2"]["severity"], by["session-cost:s-d2"]["value"], by["session-cost:s-d2"]["baseline"]) \
    == ("warn", 60.0, 50), by["session-cost:s-d2"]
assert by["session-cost:s-d2"]["message"] == "session s-d2 (acme/app, no-mistakes) cost $60.00, above $50", by["session-cost:s-d2"]["message"]
assert (by["runaway-calls:s-d3"]["severity"], by["runaway-calls:s-d3"]["metric"], by["runaway-calls:s-d3"]["value"]) \
    == ("critical", "session_api_calls", 600), by["runaway-calls:s-d3"]
assert (by["weekly-quota"]["severity"], by["weekly-quota"]["value"], by["weekly-quota"]["baseline"]) == ("warn", 91, 85)
assert json.load(open(sys.argv[2]))["flags"] == f["flags"], "the report and flags.json disagree"
PY

# A quiet day removes the file, so a stale flag never outlives its day.
run 0 --window daily --end 2026-10-03 --no-insights
[ ! -e "$flagsfile" ] || fail "a daily run without flags left flags.json behind" "$(cat "$flagsfile")"
grep -q "^flags: 0" "$out" || fail "the run does not report its flag count" "$(cat "$out")"

# Other windows never touch the flag file.
echo '{"date": "x", "window": "daily", "flags": []}' >"$flagsfile"
run 0 --window weekly --end 2026-10-09 --no-insights --no-github
grep -q '"date": "x"' "$flagsfile" || fail "a weekly run rewrote flags.json"
rm "$flagsfile"

# Warn below critical: a 2.3x day fires the warn level only.
run 0 --window daily --end 2026-10-02 --no-insights
python3 - "$flagsfile" <<'PY' || fail "a warn-level spend day is flagged wrongly"
import json, sys
f = json.load(open(sys.argv[1]))["flags"]
assert [(x["id"], x["severity"], x["value"]) for x in f] == [("day-spend", "warn", 3.0)], f
PY

# The same day under a looser threshold fires nothing.
python3 - "$tmp/thresholds.bak" "$tmp/config/thresholds.json" <<'PY'
import json, sys
t = json.load(open(sys.argv[1])); t["spend_warn_multiple"] = 2.4
json.dump(t, open(sys.argv[2], "w"))
PY
run 0 --window daily --end 2026-10-02 --no-insights
[ ! -e "$flagsfile" ] || fail "a day under the threshold was flagged" "$(cat "$flagsfile")"
cp "$tmp/thresholds.bak" "$tmp/config/thresholds.json"
reset_store

# ── Output: files in the store, one commit, pushed; Markdown for people ──
wmd="$store/reports/2026-10-04-weekly.md"
run 0 --window weekly --end 2026-10-09 --no-insights --no-github
[ -f "$store/reports/2026-10-04-weekly.json" ] && [ -f "$wmd" ] || fail "the report files are not in the store" "$(cat "$out" "$err")"
[ "$(gs log -1 --format=%s)" = "report: 2026-10-04 weekly" ] || fail "report commit subject: $(gs log -1 --format=%s)"
[ "$(gs rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "the report was not pushed"
[ -z "$(gs status --porcelain)" ] || fail "the store was left dirty" "$(gs status --porcelain)"
grep -q "^pushed: true" "$out" || fail "the run does not report the push" "$(cat "$out")"
for want in "list-price estimates" "## Interactive" "## Scripted" "\$5.00" "\$6.00" "2026-09-28" "no-mistakes"; do
    grep -q -- "$want" "$wmd" || fail "the Markdown report lacks '$want'" "$(cat "$wmd")"
done

# Re-running a window overwrites it; with nothing new the files are identical and nothing is committed.
cp "$store/reports/2026-10-04-weekly.json" "$tmp/first.json"
commits_before="$(gs rev-list --count HEAD)"
run 0 --window weekly --end 2026-10-09 --no-insights --no-github
cmp -s "$tmp/first.json" "$store/reports/2026-10-04-weekly.json" || fail "a re-run changed the report"
[ "$(gs rev-list --count HEAD)" = "$commits_before" ] || fail "a re-run committed again"
grep -q "^committed: false" "$out" || fail "a re-run should report no commit" "$(cat "$out")"

# A dry run writes outside the store and touches nothing in it.
reset_store
echo '{"date": "keep", "window": "daily", "flags": []}' >"$tmp/state/flags.json"
head_before="$(gs rev-parse HEAD)"
ledger_before="$(cat "$store/ledger/2026-10.jsonl")"
for w in daily weekly monthly; do
    run 0 --window "$w" --end 2026-10-09 --dry-run
    for k in json md; do
        p="$(field "$k")"
        [ -f "$p" ] || fail "dry run $w did not write $k" "$(cat "$out")"
        case "$p" in "$store"/*) fail "dry run $w wrote into the store: $p" ;; esac
    done
done
[ "$(gs rev-parse HEAD)" = "$head_before" ] && [ -z "$(gs status --porcelain)" ] || fail "a dry run changed the store" "$(gs status --porcelain)"
[ "$ledger_before" = "$(cat "$store/ledger/2026-10.jsonl")" ] || fail "a dry run changed the ledger"
grep -q '"keep"' "$tmp/state/flags.json" || fail "a dry run rewrote flags.json"
rm "$tmp/state/flags.json"
run 0 --window daily --end 2026-10-09 --dry-run
[ ! -e "$tmp/state/flags.json" ] || fail "a dry run wrote flags.json"

# One run at a time: a held lock times out as a failure, not a hang.
python3 - "$tmp/state/collect.lock" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "w"); fcntl.flock(fh, fcntl.LOCK_EX)
time.sleep(4)
PY
holder=$!
python3 -c 'import time; time.sleep(0.5)'
AGENT_METRICS_LOCK_WAIT=1 run 1 --window weekly --end 2026-10-09 --no-insights --no-github
grep -q "lock" "$out" || fail "a lock timeout is not explained" "$(cat "$out")"
wait "$holder"

# A failed push keeps the commit and fails the run, so the next run delivers it.
mv "$remote" "$remote.gone"
run 1 --window weekly --end 2026-10-09 --no-insights --no-github
grep -q "^pushed: false" "$out" || fail "a failed push is not reported" "$(cat "$out")"
[ "$(gs log -1 --format=%s)" = "report: 2026-10-04 weekly" ] || fail "the commit was not kept after a failed push"
mv "$remote.gone" "$remote"
reset_store

# ── Config inventory from the audit's JSON ──
mkdir -p "$AGENT_REPORT_AUDIT_DIR"
python3 - "$AGENT_REPORT_AUDIT_DIR/2026-10-04-weekly.json" <<'PY'
import json, sys
json.dump({"label_date": "2026-10-04",
           "current": {"sessions": 99, "hooks": [
               {"plugin": "superpowers", "event": "SessionStart", "fires": 201, "bytes": 686817},
               {"plugin": "unattributed: LAUNCH CODES are purple", "event": "UserPromptSubmit", "fires": 5, "bytes": 55}]},
           "disable_candidates": {"plugins": [{"plugin": "caveman", "provides": "hooks", "hook_bytes": 338822}],
                                  "skills": ["pr", "standup"], "mcp_servers": [], "agents": []},
           "instructions": {"files": [{"path": "~/.claude/CLAUDE.md", "lines": 97, "bytes": 5503, "flag": ""}], "combined": {"bytes": 5503}},
           "prs": {"current": {"body_words_median": 40}}}, open(sys.argv[1], "w"))
PY
run 0 --window weekly --end 2026-10-09 --dry-run --no-insights --no-github
wjson="$(field json)"
python3 - "$wjson" "$(field md)" <<'PY' || fail "the audit inventory is embedded wrongly"
import json, sys
j = json.load(open(sys.argv[1]))
a = j["audit"]
assert a["source"] == "2026-10-04-weekly.json", a
assert [h["fires"] for h in a["hooks"]] == [201, 5], a["hooks"]
assert a["hooks"][1]["plugin"] == "unattributed", a["hooks"][1]
assert a["disable_candidates"]["plugins"][0]["plugin"] == "caveman" and a["disable_candidates"]["skills"] == ["pr", "standup"]
assert a["instructions"]["files"][0]["path"] == "~/.claude/CLAUDE.md", a["instructions"]
raw = open(sys.argv[1]).read() + open(sys.argv[2]).read()
assert "LAUNCH CODES" not in raw and "body_words" not in raw, "audit text or unrelated sections leaked"
assert "caveman" in open(sys.argv[2]).read(), "the Markdown omits the disable candidates"
PY
run 0 --window weekly --end 2026-10-16 --dry-run --no-insights --no-github
python3 - "$(field json)" "$(field md)" <<'PY' || fail "a window without an audit report is mishandled"
import json, sys
assert json.load(open(sys.argv[1]))["audit"] is None
assert "config inventory was not available" in open(sys.argv[2]).read()
PY
run 0 --window daily --end 2026-10-09 --dry-run --no-insights
grep -q "config inventory" "$(field md)" && fail "a daily report should not mention the inventory"
echo '{broken' >"$AGENT_REPORT_AUDIT_DIR/2026-10-11-biweekly.json"
run 2 --window biweekly --end 2026-10-12 --dry-run --no-insights --no-github
grep -q "2026-10-11-biweekly.json" "$out" || fail "an unreadable audit report is not named" "$(cat "$out")"
rm "$AGENT_REPORT_AUDIT_DIR/2026-10-11-biweekly.json"

# ── Monthly thresholds review ──
run 0 --window monthly --end 2026-10-09 --dry-run --no-insights --no-github
python3 - "$(field json)" "$(field md)" <<'PY' || fail "the thresholds review is wrong"
import json, sys
t = json.load(open(sys.argv[1]))["current"]["thresholds_review"]
assert t["daily_reports"] == 3, t
got = {(x["source"], x["key"]): x for x in t["thresholds"]}
want = {("thresholds.json", "spend_warn_multiple"): 2, ("thresholds.json", "spend_critical_multiple"): 1,
        ("thresholds.json", "session_warn_usd"): 1, ("thresholds.json", "runaway_session_usd"): 0,
        ("thresholds.json", "runaway_session_calls"): 0, ("thresholds.json", "weekly_quota_warn_pct"): 0,
        ("budget.json", "plan_pct"): 2, ("budget.json", "hard_pct"): 1, ("budget.json", "weekly_quota_cutoff_pct"): 0}
assert {k: v["fired"] for k, v in got.items()} == want, {k: v["fired"] for k, v in got.items()}
assert got[("thresholds.json", "spend_warn_multiple")]["value"] == 1.5 and got[("budget.json", "hard_pct")]["value"] == 5
assert "spend_warn_multiple" in open(sys.argv[2]).read()
PY
run 0 --window monthly --end 2026-09-10 --dry-run --no-insights --no-github
python3 - "$(field json)" <<'PY' || fail "a month with no daily reports must not read as zero firings"
import json, sys
t = json.load(open(sys.argv[1]))["current"]["thresholds_review"]
assert t["daily_reports"] == 0 and all(x["fired"] is None for x in t["thresholds"]), t
PY
run 0 --window weekly --end 2026-10-09 --dry-run --no-insights --no-github
python3 - "$(field json)" <<'PY' || fail "only the monthly report carries a thresholds review"
import json, sys
assert "thresholds_review" not in json.load(open(sys.argv[1]))["current"]
PY
echo '{broken' >"$store/reports/2026-09-12-daily.json"
run 2 --window monthly --end 2026-10-09 --dry-run --no-insights --no-github
grep -q "2026-09-12-daily.json" "$out" || fail "an unreadable daily report is not named" "$(cat "$out")"
reset_store

# ── Insights: one capped model call for weekly and monthly only ──
cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
    echo "ARGS: $*"
    echo "CWD: $(pwd)"
    echo "TOKENS: $(env | grep -c 'SECRET_TOKEN' || true)"
} >>"$CLAUDE_LOG"
cat >"$CLAUDE_STDIN"
case "${STUB_CLAUDE_MODE:-ok}" in
    ok) printf '{"type":"result","is_error":false,"result":"%s","total_cost_usd":0.1234}\n' "${STUB_CLAUDE_TEXT:-Spend is up. Trim the plugin hooks.}" ;;
    error) printf '{"type":"result","is_error":true,"subtype":"error_max_budget_usd","total_cost_usd":0.05}\n' ;;
    fail) echo "boom" >&2; exit 1 ;;
    sleep) sleep 5 ;;
esac
STUB
chmod +x "$tmp/bin/claude"
export CLAUDE_LOG="$tmp/claude.log" CLAUDE_STDIN="$tmp/claude.stdin"
export MY_SECRET_TOKEN=hunter2
ledger() { cat "$store/ledger/2026-10.jsonl"; }
insights() { python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1]))["insights"], sort_keys=True))' "$store/reports/$1.json"; }

reset_store
: >"$CLAUDE_LOG"
run 0 --window weekly --end 2026-10-09 --no-github
[ "$(insights 2026-10-04-weekly)" = '{"cost_usd": 0.1234, "text": "Spend is up. Trim the plugin hooks."}' ] \
    || fail "insights not recorded" "$(insights 2026-10-04-weekly)"
tail -1 <(ledger) | python3 -c '
import json, sys
e = json.loads(sys.stdin.read())
assert (e["run"], e["usd"], e["critical"]) == ("report-weekly", 0.1234, False), e
assert e["at"] == "2026-10-09T12:00:00Z", e
' || fail "the insights cost is not in the ledger" "$(ledger)"
grep -q "Trim the plugin hooks" "$store/reports/2026-10-04-weekly.md" || fail "the Markdown omits the insights"
gs show --stat --format=%s HEAD | grep -q "ledger/2026-10.jsonl" || fail "the ledger entry was not committed with the report" "$(gs show --stat HEAD)"
[ -z "$(gs status --porcelain)" ] || fail "store left dirty"
args="$(grep '^ARGS:' "$CLAUDE_LOG")"
for want in "-p" "--model sonnet" "--max-turns 1" "--max-budget-usd 0.50" "--no-session-persistence" "--output-format json" "--tools "; do
    grep -q -- "$want" <<<"$args" || fail "claude was not called with '$want'" "$args"
done
cwd="$(sed -n 's/^CWD: //p' "$CLAUDE_LOG")"
case "$cwd" in "$store"* | "$here"*) fail "claude ran inside the store or the repo: $cwd" ;; esac
[ ! -d "$cwd" ] || fail "the temp working directory was left behind: $cwd"
[ "$(sed -n 's/^TOKENS: //p' "$CLAUDE_LOG")" = 0 ] || fail "a credential-shaped variable reached claude"
grep -q "hours saved" "$CLAUDE_STDIN" || fail "the prompt does not forbid hours-saved claims"
grep -q '"populations"' "$CLAUDE_STDIN" || fail "the prompt carries no metrics"
grep -qi "never" "$CLAUDE_STDIN" || fail "the prompt does not forbid anything"

# The ledger line has the same shape `agent-metrics budget record` writes.
"$metrics" budget record --usd 0.2 --run report-weekly >/dev/null
python3 - "$store/ledger/2026-10.jsonl" <<'PY' || fail "the ledger entry differs in shape from budget record's"
import json, sys
a, b = [json.loads(l) for l in open(sys.argv[1]).read().splitlines()[-2:]]
assert sorted(a) == sorted(b), (a, b)
PY

# Over budget: no call, and the state is recorded.
reset_store
: >"$CLAUDE_LOG"
cp -r "$tmp/config" "$tmp/config-tight"
echo '{"plan_pct": 0.0001, "hard_pct": 0.0002, "weekly_quota_cutoff_pct": 85}' >"$tmp/config-tight/budget.json"
ledger_before="$(ledger)"
AGENT_METRICS_CONFIG="$tmp/config-tight" run 0 --window weekly --end 2026-10-09 --no-github
[ ! -s "$CLAUDE_LOG" ] || fail "claude was called with the budget denied" "$(cat "$CLAUDE_LOG")"
python3 - "$store/reports/2026-10-04-weekly.json" <<'PY' || fail "a budget denial is not recorded"
import json, sys
i = json.load(open(sys.argv[1]))["insights"]
assert i["skipped"] == "budget" and i["state"]["state"] == "stopped" and i["state"]["allowed"] is False, i
PY
[ "$ledger_before" = "$(ledger)" ] || fail "the ledger changed without a call"

# A failure, an error result and a timeout are recorded; the run carries on.
for mode in fail error sleep; do
    reset_store
    : >"$CLAUDE_LOG"
    ledger_before="$(ledger)"
    STUB_CLAUDE_MODE=$mode AGENT_REPORT_INSIGHTS_TIMEOUT=1 run 0 --window weekly --end 2026-10-09 --no-github
    [ -f "$store/reports/2026-10-04-weekly.json" ] || fail "no report after a $mode insights call"
    python3 - "$store/reports/2026-10-04-weekly.json" "$mode" <<'PY' || fail "insights $mode not recorded as an error"
import json, sys
i = json.load(open(sys.argv[1]))["insights"]
assert set(i) == {"error"} and i["error"], i
assert {"fail": "exited 1", "error": "error_max_budget_usd", "sleep": "timed out"}[sys.argv[2]] in i["error"], i
PY
    if [ "$mode" = error ]; then
        tail -1 <(ledger) | grep -q '"usd":0.05' || fail "the cost of a failed call is not in the ledger" "$(ledger)"
    else
        [ "$ledger_before" = "$(ledger)" ] || fail "a $mode call left a ledger entry"
    fi
done

# Only weekly and monthly call a model, and never on a dry run or with --no-insights.
reset_store
: >"$CLAUDE_LOG"
for w in daily biweekly quarterly yearly; do
    run 0 --window "$w" --end 2026-10-09 --no-github
    [ "$(insights "$(field label_date)-$w")" = '{"skipped": "window"}' ] || fail "$w should not call a model" "$(insights "$(field label_date)-$w")"
done
run 0 --window weekly --end 2026-10-09 --no-github --no-insights
[ "$(insights 2026-10-04-weekly)" = '{"skipped": "--no-insights"}' ] || fail "--no-insights not recorded"
run 0 --window weekly --end 2026-10-09 --no-github --dry-run
python3 - "$(field json)" <<'PY' || fail "dry run insights not recorded as skipped"
import json, sys
assert json.load(open(sys.argv[1]))["insights"] == {"skipped": "dry-run"}
PY
[ ! -s "$CLAUDE_LOG" ] || fail "a model was called when none should be" "$(cat "$CLAUDE_LOG")"
run 0 --window monthly --end 2026-10-09 --no-github
grep -q "report-monthly\|ARGS" "$CLAUDE_LOG" || fail "monthly should call a model"
[ "$(wc -l <"$CLAUDE_LOG")" -le 3 ] || fail "monthly called the model more than once"
long="$(python3 -c 'print("word " * 400)')"
reset_store
STUB_CLAUDE_TEXT="$long" run 0 --window weekly --end 2026-10-09 --no-github
python3 - "$store/reports/2026-10-04-weekly.json" <<'PY' || fail "overlong insights are not cut"
import json, sys
n = len(json.load(open(sys.argv[1]))["insights"]["text"].split())
assert n <= 260, n
PY
unset MY_SECRET_TOKEN
reset_store

# ── Delivery: GitHub merged PRs and no-mistakes runs ──
gh_fx="$tmp/gh-fixtures"
mkdir -p "$gh_fx"
python3 - "$gh_fx" "$AGENT_REPORT_NM_DB" <<'PY'
import json, os, sqlite3, sys, datetime as dt
fxdir, db = sys.argv[1:]
ok = lambda s: {"statusCheckRollup": None if s is None else {"state": s}}
def pr(number, repo, created, merged, add, dele, files, commits, head, ref="feat/x", title="t", changed=None):
    return {"number": number, "createdAt": created, "mergedAt": merged, "additions": add, "deletions": dele,
            "changedFiles": changed if changed is not None else len(files), "headRefName": ref, "title": title,
            "repository": {"nameWithOwner": repo}, "files": {"nodes": [{"path": p} for p in files]},
            "allCommits": {"totalCount": len(commits), "nodes": [{"commit": ok(c)} for c in commits]},
            "head": {"nodes": [{"commit": ok(head)}]}}
merged = [
    pr(1, "acme/app", "2026-09-28T10:00:00Z", "2026-09-28T12:00:00Z", 40, 10, ["src/a.py", "README.md", "uv.lock"], ["SUCCESS", "SUCCESS"], "SUCCESS"),
    pr(2, "acme/app", "2026-09-29T00:00:00Z", "2026-09-30T00:00:00Z", 100, 20, ["src/b.py", "src/c.py"], ["FAILURE", "SUCCESS"], "SUCCESS"),
    pr(3, "acme/lib", "2026-10-01T00:00:00Z", "2026-10-01T10:00:00Z", 5, 5, ["lib/x.py"], ["FAILURE"], "FAILURE"),
    pr(4, "acme/lib", "2026-10-02T00:00:00Z", "2026-10-04T00:00:00Z", 200, 0, ["lib/y.py"], [None, "SUCCESS"], "SUCCESS"),
]
def fu(number, ref, title, merged_at, files):
    return {"number": number, "mergedAt": merged_at, "headRefName": ref, "title": title, "changedFiles": len(files),
            "repository": {"nameWithOwner": "acme/app"}, "files": {"nodes": [{"path": p} for p in files]}}
followups = {"acme__app": [
    fu(10, "fix/b-bug", "Fix b", "2026-10-03T00:00:00Z", ["src/b.py"]),
    fu(11, "revert-12", 'Revert "A"', "2026-10-08T00:00:00Z", ["src/a.py", "README.md"]),
    fu(12, "feat/x", "Feature", "2026-10-01T00:00:00Z", ["src/b.py", "src/c.py"]),
    fu(13, "fix/early", "Fix early", "2026-09-28T06:00:00Z", ["src/a.py"]),
    fu(14, "fix/other", "Fix other", "2026-10-02T00:00:00Z", ["docs/z.py"]),
], "acme__lib": []}
json.dump(merged, open(os.path.join(fxdir, "merged.json"), "w"))
for k, v in followups.items():
    json.dump(v, open(os.path.join(fxdir, f"followup-{k}.json"), "w"))

ts = lambda d: int(dt.datetime.fromisoformat(d + "+00:00").timestamp())
if os.path.exists(db):
    os.remove(db)
c = sqlite3.connect(db)
c.executescript("""
create table runs (id text primary key, status text not null, created_at integer not null);
create table step_results (id text primary key, run_id text not null);
create table step_rounds (id text primary key, step_result_id text not null, trigger_type text not null);
""")
runs = [("r1", "completed", "2026-09-29T10:00:00", 0), ("r2", "completed", "2026-09-30T10:00:00", 1),
        ("r3", "completed", "2026-10-01T10:00:00", 0), ("r4", "failed", "2026-10-02T10:00:00", 2),
        ("r5", "cancelled", "2026-10-03T10:00:00", 0), ("r6", "running", "2026-10-04T10:00:00", 0),
        ("r7", "completed", "2026-10-06T10:00:00", 0), ("r8", "completed", "2026-09-20T10:00:00", 0)]
for rid, st, at, fixes in runs:
    c.execute("insert into runs values (?,?,?)", (rid, st, ts(at)))
    c.execute("insert into step_results values (?,?)", (rid + "-s", rid))
    c.execute("insert into step_rounds values (?,?,?)", (rid + "-i", rid + "-s", "initial"))
    for n in range(fixes):
        c.execute("insert into step_rounds values (?,?,?)", (f"{rid}-f{n}", rid + "-s", "auto_fix"))
c.commit()
PY
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env python3
import json, os, re, sys
args = sys.argv[1:]
with open(os.environ["GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
mode = os.environ.get("STUB_GH_MODE", "ok")
fx = os.environ["GH_FIXTURES"]
if mode == "fail":
    sys.stderr.write("HTTP 502: Bad Gateway\n"); sys.exit(1)
if mode == "ratelimit":
    sys.stderr.write("API rate limit exceeded for user\n"); sys.exit(1)
if args[:2] == ["api", "user"]:
    print("tester"); sys.exit(0)
assert args[:2] == ["api", "graphql"], args
v = {}
for flag, val in zip(args, args[1:]):
    if flag in ("-f", "-F") and "=" in val:
        k, _, x = val.partition("=")
        v[k] = x
q, first, after = v["q"], int(v.get("first", "100")), int(v.get("after", "0") or 0)
if "author:" in q:
    nodes = json.load(open(os.path.join(fx, "merged.json")))
    lo, hi = re.search(r"merged:(\S+)\.\.(\S+)", q).groups()
    nodes = [n for n in nodes if lo <= n["mergedAt"][:10] <= hi]
    if mode == "empty":
        nodes = []
    days = (__import__("datetime").date.fromisoformat(hi) - __import__("datetime").date.fromisoformat(lo)).days + 1
    count = 1500 if (mode == "big" and days > 1) or mode == "huge" else len(nodes)
    if mode == "big" and days > 1:
        nodes = []
else:
    repo = re.search(r"repo:(\S+)", q).group(1).replace("/", "__")
    nodes = json.load(open(os.path.join(fx, f"followup-{repo}.json")))
    count = len(nodes)
page = nodes[after:after + first]
print(json.dumps({"data": {"search": {"issueCount": count,
    "pageInfo": {"hasNextPage": after + first < len(nodes), "endCursor": str(after + first)}, "nodes": page}}}))
STUB
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log" GH_FIXTURES="$gh_fx"
: >"$GH_LOG"

# deliver [env...] run-args: a weekly window whose PRs have been watched for different lengths of time.
deliver() { AGENT_METRICS_NOW="2026-10-14T00:00:00+00:00" run 0 --window weekly --end 2026-10-05 --dry-run --no-insights "$@"; }
dj() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1]))["delivery"]; print(json.dumps(eval(sys.argv[2], {"d": d}), sort_keys=True))' "$(field json)" "$1"; }

deliver
python3 - "$(field json)" <<'PY' || fail "delivery metrics are wrong"
import json, sys
d = json.load(open(sys.argv[1]))["delivery"]
g, n = d["github"], d["no_mistakes"]
assert g["available"] is True and g["owners"] == ["acme", "acme-labs"], g
assert g["merged"] == 4, g
assert g["open_to_merge_hours"] == {"median": 17.0, "p90": 48.0}, g["open_to_merge_hours"]
assert g["lines_changed_median"] == 85.0, g["lines_changed_median"]
assert (g["failed_check_share"], g["red_head_share"]) == (0.5, 0.25), g
# At the fixture clock all four PRs have been watched for 7 days, only the two oldest for 14.
assert g["followup"] == {"d7": {"eligible": 4, "followed_up": 1, "rate": 0.25},
                         "d14": {"eligible": 2, "followed_up": 2, "rate": 1.0}}, g["followup"]
assert g["truncated"] is False
assert n == {"available": True, "runs": 5, "completed": 3, "failed": 1, "cancelled": 1, "in_progress": 1,
             "first_pass_runs": 2, "first_pass_rate": 0.4}, n
PY
q1="$(grep 'author:' "$GH_LOG" | head -1)"
for want in "author:tester" "is:pr" "is:merged" "user:acme user:acme-labs" "merged:2026-09-28..2026-10-04"; do
    grep -q -- "$want" <<<"$q1" || fail "the merged-PR search lacks '$want'" "$q1"
done
grep -q "repo:acme/app" "$GH_LOG" && grep -q "repo:acme/lib" "$GH_LOG" || fail "follow-ups were not searched per repo" "$(cat "$GH_LOG")"
grep -q "Merged PRs" "$(field md)" || fail "the Markdown omits the delivery section" "$(cat "$(field md)")"

# Pagination returns the same numbers from more requests.
: >"$GH_LOG"
deliver
single="$(wc -l <"$GH_LOG")"
: >"$GH_LOG"
AGENT_REPORT_GH_PAGE=2 deliver
[ "$(dj 'd["github"]["merged"]')" = 4 ] || fail "paged fetch lost PRs"
[ "$(wc -l <"$GH_LOG")" -gt "$single" ] || fail "page size had no effect on request count"

# A range over the search cap is halved until it fits; one day over it is marked truncated.
STUB_GH_MODE=big deliver
[ "$(dj 'd["github"]["merged"]')" = 4 ] && [ "$(dj 'd["github"]["truncated"]')" = false ] || fail "splitting a large range lost PRs" "$(dj 'd["github"]')"
STUB_GH_MODE=huge deliver
[ "$(dj 'd["github"]["truncated"]')" = true ] || fail "a day over the search cap is not marked truncated"

# Failures are errored with a reason, never zero; the local section is unaffected.
STUB_GH_MODE=fail deliver
python3 - "$(field json)" <<'PY' || fail "a GitHub failure is not recorded as errored"
import json, sys
d = json.load(open(sys.argv[1]))["delivery"]
g = d["github"]
assert g["errored"] is True and "502" in g["reason"] and "merged" not in g, g
assert d["no_mistakes"]["available"] is True
PY
grep -qi "errored" "$(field md)" || fail "the Markdown does not show the errored section"
STUB_GH_MODE=ratelimit deliver
[ "$(dj '"rate limit" in d["github"]["reason"]')" = true ] || fail "a rate limit is not named" "$(dj 'd["github"]')"
STUB_GH_MODE=empty deliver
python3 - "$(field json)" <<'PY' || fail "a window with no merged PRs must be a real zero with unknown rates"
import json, sys
g = json.load(open(sys.argv[1]))["delivery"]["github"]
assert g["available"] is True and g["merged"] == 0 and g["open_to_merge_hours"] == {"median": None, "p90": None}, g
assert g["failed_check_share"] is None and g["followup"]["d7"] == {"eligible": 0, "followed_up": 0, "rate": None}, g
PY
AGENT_REPORT_GH_MAX_REQUESTS=2 deliver
python3 - "$(field json)" <<'PY' || fail "the request cap is not enforced per section"
import json, sys
g = json.load(open(sys.argv[1]))["delivery"]["github"]
assert g["merged"] == 4 and g["followup"]["errored"] is True and "request cap" in g["followup"]["reason"], g
PY
AGENT_REPORT_GH_MAX_SECONDS=0 deliver
[ "$(dj '"wall time" in d["github"]["reason"]')" = true ] || fail "the wall-time cap is not enforced" "$(dj 'd["github"]')"
mv "$fx/.config/streams.json" "$fx/.config/streams.json.bak"
deliver
[ "$(dj '"streams.json" in d["github"]["reason"]')" = true ] || fail "an unreadable stream map is not named" "$(dj 'd["github"]')"
mv "$fx/.config/streams.json.bak" "$fx/.config/streams.json"
AGENT_REPORT_NM_DB="$tmp/nope.sqlite" deliver
[ "$(dj 'd["no_mistakes"]["errored"]')" = true ] || fail "a missing no-mistakes database is not errored" "$(dj 'd["no_mistakes"]')"

# --no-github and the daily window skip GitHub; the daily window skips delivery altogether.
: >"$GH_LOG"
deliver --no-github
[ "$(dj 'd["github"]')" = '{"skipped": "--no-github"}' ] && [ "$(dj 'd["no_mistakes"]["available"]')" = true ] || fail "--no-github not honoured"
[ ! -s "$GH_LOG" ] || fail "gh was called with --no-github" "$(cat "$GH_LOG")"
run 0 --window daily --end 2026-10-09 --dry-run --no-insights
[ "$(dj 'd')" = '{"skipped": "daily window"}' ] || fail "a daily report should skip delivery" "$(dj 'd')"
[ ! -s "$GH_LOG" ] || fail "a daily run called gh"
unset STUB_GH_MODE

# ── Units: one template service and six calendar timers ──
svc="$units/agent-report@.service"
grep -qx 'ExecStart=%h/.local/bin/agent-report --window %i' "$svc" || fail "service ExecStart"
grep -qx 'NoNewPrivileges=yes' "$svc" && grep -qx 'PrivateTmp=yes' "$svc" || fail "service hardening missing"
grep -qx 'Nice=10' "$svc" && grep -qx 'IOSchedulingClass=idle' "$svc" || fail "service scheduling hints missing"
grep -q '^TimeoutStartSec=' "$svc" || fail "service needs a hard timeout"
grep -q '^Environment=PATH=.*/usr/bin' "$svc" || fail "service needs a PATH: a user manager starts with a bare one"
declare -A cal=([daily]="*-*-* 07:00:00" [weekly]="Mon *-*-* 08:40:00" [biweekly]="Mon *-*-* 08:50:00"
    [monthly]="*-*-01 09:10:00" [quarterly]="*-01,04,07,10-01 09:20:00" [yearly]="*-01-01 09:30:00")
for w in "${!cal[@]}"; do
    t="$units/agent-report-$w.timer"
    [ -f "$t" ] || fail "missing $(basename "$t")"
    grep -qxF "OnCalendar=${cal[$w]}" "$t" || fail "$w timer calendar"
    grep -qx "Unit=agent-report@$w.service" "$t" || fail "$w timer target"
    grep -qx "Persistent=true" "$t" || fail "$w timer must catch up after downtime"
    grep -qx "WantedBy=timers.target" "$t" || fail "$w timer install target"
    if command -v systemd-analyze >/dev/null 2>&1; then
        systemd-analyze calendar "${cal[$w]}" >/dev/null || fail "$w calendar rejected by systemd"
    fi
done
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify --user "$svc" 2>&1 | grep -i "agent-report" | grep -iv "no such file\|not-found" && fail "systemd rejects the service" || true
fi

# ── Trigger: stubbed systemctl/loginctl ──
shellcheck -s bash "$trigger"
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
for w in "${!cal[@]}"; do
    grep -q -- "--user enable .*agent-report-$w.timer" "$trig/calls" || fail "trigger does not enable the $w timer" "$(cat "$trig/calls")"
done
grep -q "start" "$trig/calls" && fail "trigger must not start a run"
grep -q "agent-report@" "$trig/calls" && fail "trigger must only touch the timers, never the service" "$(cat "$trig/calls")"
grep -q "linger is off" <<<"$trig_out" || fail "trigger should warn when linger is off"
run_trigger "$trig/home" yes
grep -q "linger is off" <<<"$trig_out" && fail "no linger warning expected when linger is on"
rm "$trig/home/.config/systemd/user/agent-report@.service"
run_trigger "$trig/home" yes
grep -q "not a home apply" <<<"$trig_out" && [ ! -s "$trig/calls" ] || fail "trigger must skip when the unit is absent" "$trig_out"

echo "test_agent_report_script: OK"
