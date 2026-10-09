#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-report reads a store, shells out to gh and claude, and pushes to a git
# remote, so everything it touches is redirected here: a fixture store with a
# local bare remote, stub gh and claude executables, a fixture no-mistakes
# database and a fixed clock.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
report="$here/home/dot_local/bin/executable_agent-report"
cfgsrc="$here/home/dot_config/agent-metrics"

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

echo "test_agent_report_script: OK"
