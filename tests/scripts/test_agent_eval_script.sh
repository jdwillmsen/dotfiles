#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-eval reads a T3 database and two ledgers, so every test runs against a
# fixture sqlite file with the tables collect reads, ledgers built under a temp
# dir, and a stubbed gh. Nothing here touches real T3 data or the network.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
ae="$here/home/dot_local/bin/executable_agent-eval"
report_tool="$here/home/dot_local/bin/executable_agent-report"
lanes_real="$here/home/dot_config/agents/lanes.toml"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$ae" ] || fail "agent-eval missing or not executable"
python3 -I -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$ae" || fail "agent-eval does not parse"
head -1 "$ae" | grep -q '^#!/usr/bin/env python3$' || fail "agent-eval has the wrong shebang"
[ -f "$lanes_real" ] || fail "lanes.toml missing"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT

export HOME="$tmp/home"
mkdir -p "$HOME"
export AGENT_EVAL_LANES="$lanes_real"
export AGENT_EVAL_NOW="2026-10-23T12:00:00+00:00"
export AGENT_EVAL_T3_DB="$tmp/missing.sqlite"
export AGENT_EVAL_GH="$tmp/no-gh"

out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$ae" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-eval $* exited $got, want $want" "$(cat "$out" "$err")"
}

# A fresh ledger directory for each scenario; AGENT_EVAL_STATE is what the tool reads.
fresh() {
    export AGENT_EVAL_STATE="$tmp/state-$1"
    rm -rf "$AGENT_EVAL_STATE"
    mkdir -p "$AGENT_EVAL_STATE"
}

# ── Basics ──
run 0 --version
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$out" || fail "--version is not a version" "$(cat "$out")"
run 0 --help
for c in record collect enrich scoreboard weights verdicts report; do
    grep -q "$c" "$out" || fail "--help does not list $c" "$(cat "$out")"
done
run 2 frobnicate
grep -q "^error:" "$out" || fail "an unknown command does not print a structured error" "$(cat "$out")"
grep -q "^code: usage" "$out" || fail "a usage error has no code" "$(cat "$out")"
run 2 report --window yearly
grep -q "^error:" "$out" || fail "a bad window is not a structured error" "$(cat "$out")"

# ── record: re-recording an id replaces it, never duplicates ──
fresh record
run 1 record --id nope-1 --status completed
grep -q "^error:" "$out" || fail "recording an unknown id without --lane is not an error" "$(cat "$out")"
run 0 record --id a-1 --lane claude-sonnet --class impl --status completed --duration-s 120 --risk R1 --ticket JDW-1
run 0 record --id a-1 --status failed --failure-kind quality --ci-first-pass false --note "reviewer found a regression"
[ "$(wc -l <"$AGENT_EVAL_STATE/outcomes.jsonl")" = 2 ] || fail "outcomes.jsonl is not append-only" "$(cat "$AGENT_EVAL_STATE/outcomes.jsonl")"
run 0 scoreboard --json
python3 - "$out" <<'PY' || fail "re-recorded id was duplicated or not replaced"
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
assert len(rows) == 1, rows
r = rows[0]
assert (r["lane"], r["class"]) == ("claude-sonnet", "impl"), r
assert r["attempts"] == 1 and r["judged"] == 1 and r["success"] == 0, r
PY
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "re-record lost fields from the first record"
import json, sys
last = [json.loads(l) for l in open(sys.argv[1])][-1]
assert last["status"] == "failed" and last["failure_kind"] == "quality" and last["ci_first_pass"] is False, last
assert last["lane"] == "claude-sonnet" and last["ticket"] == "JDW-1" and last["duration_s"] == 120, last
assert last["provider"] == "claudeAgent" and last["model"] == "claude-sonnet-5-5", last
assert last["note"] == "reviewer found a regression"
for k in ("id", "at", "lane", "provider", "model", "class", "class_source", "risk", "ticket", "status",
          "failure_kind", "duration_s", "items", "attempt", "escalated_from", "pr", "ci_first_pass",
          "review_findings", "merged", "reverted", "human_touch", "cost_usd", "source"):
    assert k in last, k
PY
# An assignment supplies the lane and risk the agent would otherwise have to repeat.
printf '%s\n' '{"id":"a-20261023-1642-7f3","at":"2026-10-23T11:00:00Z","lane":"opencode-glm-flash-free","provider":"opencode","model":"opencode/glm-5.3-flash-free","class":"test","risk":"R0","ticket":"JDW-9","pace":{"used":40,"line":50,"multiplier":1.2},"implementer":null}' \
    >"$AGENT_EVAL_STATE/assignments.jsonl"
run 0 record --id a-20261023-1642-7f3 --status completed --merged true
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "record did not take lane and risk from the assignment"
import json, sys
last = [json.loads(l) for l in open(sys.argv[1])][-1]
assert last["lane"] == "opencode-glm-flash-free" and last["class"] == "test" and last["class_source"] == "assigned", last
assert last["risk"] == "R0" and last["ticket"] == "JDW-9" and last["merged"] is True, last
PY
run 2 record --id a-1 --merged maybe
run 2 record --id a-1 --status exploded

# ── collect: fixture T3 database ──
mkdb() {
    python3 -I - "$1" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
create table orchestration_v2_projection_threads (thread_id text primary key, title text);
create table orchestration_v2_projection_runs (run_id text primary key, thread_id text, ordinal integer,
    provider text, status text, requested_at text, completed_at text, payload_json text);
create table orchestration_v2_projection_turn_items (turn_item_id text primary key, thread_id text, run_id text,
    type text, status text, updated_at text, payload_json text);
create table orchestration_v2_projection_provider_sessions (provider_session_id text, thread_id text,
    provider text, model text);
create table projection_thread_pull_requests (thread_id text, url text);
""")
n = [0]
def tid(slug):
    return "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3A" + slug
def add(slug, title, provider, model, status, start, end, errors=(), cmds=(), work=0, session_model=None):
    t = tid(slug)
    run = f"run:{t}:1"
    payload = {"modelSelection": {"model": model} if model else {}, "startedAt": start}
    db.execute("insert into orchestration_v2_projection_threads values (?,?)", (t, title))
    db.execute("insert into orchestration_v2_projection_runs values (?,?,?,?,?,?,?,?)",
               (run, t, 1, provider, status, start, end, json.dumps(payload)))
    def item(kind, st, payload=None):
        n[0] += 1
        db.execute("insert into orchestration_v2_projection_turn_items values (?,?,?,?,?,?,?)",
                   (f"i{n[0]}", t, run, kind, st, end, json.dumps(payload or {})))
    item("user_message", "completed", {"text": "SECRET PROMPT TEXT"})
    for _ in range(work):
        item("reasoning", "completed")
    for c in cmds:
        item("command_execution", "completed", {"input": c, "exitCode": 0})
    for cls, code, msg in errors:
        item("error", "failed", {"failure": {"class": cls, "code": code, "message": msg}})
    if session_model:
        db.execute("insert into orchestration_v2_projection_provider_sessions values (?,?,?,?)",
                   (f"s{n[0]}", t, provider, session_model))
GLM = "nvidia/z-ai/glm-5.3"
FLASH = "opencode/glm-5.3-flash-free"
add("build-thing-r2", "Build thing JDW-12 tests", "opencode", GLM, "completed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:10:00.000Z", work=3)
add("quota-429", "Docs for the thing", "opencode", FLASH, "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:00:05.000Z",
    errors=[("provider_error", "APIError", 'Too Many Requests: {"status":429}')])
add("timeout", "Spike a thing", "opencode", FLASH, "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:05:00.000Z",
    errors=[("provider_error", "APIError", "Provider response headers timed out after 300000ms")])
add("gone-410", "Plan the thing", "opencode", GLM, "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:00:02.000Z",
    errors=[("provider_error", "APIError", 'Gone: {"status":410,"title":"Gone"}')])
add("context", "Large impl-large change", "opencode", FLASH, "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:00:03.000Z",
    errors=[("provider_error", "ContextOverflowError", "This model's maximum context length is 32768 tokens")])
add("mystery-error", "Implement a thing", "opencode", FLASH, "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:20:00.000Z",
    errors=[("transport_error", "unknown", "Something odd happened")])
add("mystery-with-commit", "Implement another thing", "opencode", FLASH, "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:20:00.000Z",
    errors=[("transport_error", "unknown", "Something odd happened")], cmds=["git commit -m 'wip'"])
add("usage-limit", "Review the thing", "codex", "gpt-6-luna", "failed",
    "2026-10-23T10:00:00.000Z", "2026-10-23T10:00:04.000Z",
    errors=[("usage_limit", "usageLimitExceeded", "You've hit your usage limit.")])
add("still-running", "Implement a running thing", "opencode", FLASH, "running",
    "2026-10-23T11:00:00.000Z", None, work=1)
add("unknown-model", "Implement a strange thing", "claudeAgent", "claude-mystery-9", "completed",
    "2026-10-23T09:00:00.000Z", "2026-10-23T09:30:00.000Z", work=2)
add("interrupted", "Implement an interrupted thing", "opencode", FLASH, "interrupted",
    "2026-10-23T09:00:00.000Z", "2026-10-23T09:01:00.000Z", work=1)
add("cancelled", "Implement a cancelled thing", "opencode", FLASH, "cancelled",
    "2026-10-23T09:00:00.000Z", "2026-10-23T09:01:00.000Z", work=1)
add("no-model-in-run", "Fallback model thing", "opencode", None, "completed",
    "2026-10-23T09:00:00.000Z", "2026-10-23T09:10:00.000Z", work=1, session_model=FLASH)
add("old-one", "Implement an old thing", "opencode", FLASH, "completed",
    "2026-08-01T09:00:00.000Z", "2026-08-01T09:10:00.000Z", work=1)
# Not a delegated task: must never be read.
db.execute("insert into orchestration_v2_projection_threads values (?,?)", ("thread:plain-chat", "Chat"))
db.execute("insert into orchestration_v2_projection_runs values (?,?,?,?,?,?,?,?)",
           ("run:plain", "thread:plain-chat", 1, "claudeAgent", "completed", "2026-10-23T08:00:00.000Z",
            "2026-10-23T08:10:00.000Z", json.dumps({"modelSelection": {"model": "claude-sonnet-5-5"}})))
db.commit()
PY
}

fresh collect
export AGENT_EVAL_T3_DB="$tmp/t3.sqlite"
mkdb "$AGENT_EVAL_T3_DB"
cp "$AGENT_EVAL_T3_DB" "$tmp/t3.before"
run 0 collect --dry-run
grep -q "^added: 12$" "$out" || fail "dry run did not find 12 finished tasks" "$(cat "$out")"
[ ! -e "$AGENT_EVAL_STATE/outcomes.jsonl" ] || fail "--dry-run wrote the ledger"
run 0 collect
grep -q "^added: 12$" "$out" && grep -q "^skipped_running: 1$" "$out" || fail "collect counts are wrong" "$(cat "$out")"
cmp -s "$AGENT_EVAL_T3_DB" "$tmp/t3.before" || fail "collect modified the T3 database"
lines="$(wc -l <"$AGENT_EVAL_STATE/outcomes.jsonl")"
[ "$lines" = 12 ] || fail "expected 12 ledger lines, got $lines"
grep -q "SECRET PROMPT TEXT" "$AGENT_EVAL_STATE/outcomes.jsonl" && fail "prompt text reached the ledger"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "collected outcomes are wrong"
import json, sys
rows = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    rows[r["id"].split("%3A")[-1]] = r
a = rows["build-thing-r2"]
assert a["id"].startswith("t3:thread:delegated-task:"), a["id"]
assert a["lane"] == "opencode-nim-glm" and a["provider"] == "opencode" and a["model"] == "nvidia/z-ai/glm-5.3", a
assert a["status"] == "completed" and a["failure_kind"] == "none", a
assert a["duration_s"] == 600 and a["items"] == 3 and a["attempt"] == 2 and a["ticket"] == "JDW-12", a
assert a["class"] == "test" and a["class_source"] == "heuristic" and a["source"] == "t3", a
assert a["at"] == "2026-10-23T10:10:00Z", a["at"]
assert a["pr"] is None and a["merged"] is None and a["ci_first_pass"] is None and a["cost_usd"] is None, a
kinds = {k: (v["status"], v["failure_kind"]) for k, v in rows.items()}
want = {
    "quota-429": ("failed", "quota"),
    "timeout": ("failed", "timeout"),
    "gone-410": ("failed", "infra"),
    "context": ("failed", "infra"),
    "mystery-error": ("failed", "infra"),
    "mystery-with-commit": ("failed", "quality"),
    "usage-limit": ("failed", "quota"),
    "interrupted": ("interrupted", "none"),
    "cancelled": ("interrupted", "none"),
    "unknown-model": ("completed", "none"),
}
for slug, w in want.items():
    assert kinds[slug] == w, (slug, kinds[slug], w)
assert rows["unknown-model"]["lane"] == "unmapped:claudeAgent/claude-mystery-9", rows["unknown-model"]["lane"]
assert rows["no-model-in-run"]["lane"] == "opencode-glm-flash-free", rows["no-model-in-run"]["lane"]
assert rows["usage-limit"]["lane"] == "unmapped:codex/gpt-6-luna" or rows["usage-limit"]["lane"] == "codex-luna"
assert rows["context"]["class"] == "impl-large", rows["context"]["class"]
assert rows["gone-410"]["class"] == "plan" and rows["quota-429"]["class"] == "docs" and rows["timeout"]["class"] == "spike"
assert rows["usage-limit"]["class"] == "review"
assert not any("plain" in k for k in rows), "read a non-delegated thread"
PY
# Second run adds nothing.
before="$(cat "$AGENT_EVAL_STATE/outcomes.jsonl")"
run 0 collect
grep -q "^added: 0$" "$out" && grep -q "^updated: 0$" "$out" && grep -q "^unchanged: 12$" "$out" \
    || fail "second collect was not a no-op" "$(cat "$out")"
[ "$before" = "$(cat "$AGENT_EVAL_STATE/outcomes.jsonl")" ] || fail "second collect changed the ledger"
# An outcome added by record or enrich survives a re-collect.
# The id of the first collected task whose slug ends with $1.
id_ending() {
    python3 -I -c "
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r['id'].endswith(sys.argv[2]):
        print(r['id'])
        break" "$AGENT_EVAL_STATE/outcomes.jsonl" "$1"
}
quota_id="$(id_ending build-thing-r2)"
run 0 record --id "$quota_id" --merged true --ci-first-pass true --pr https://example.invalid/o/r/pull/5
run 0 collect
grep -q "^updated: 0$" "$out" || fail "collect touched a record it only enriched" "$(cat "$out")"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" "$quota_id" <<'PY' || fail "collect lost recorded fields"
import json, sys
last = [r for r in map(json.loads, open(sys.argv[1])) if r["id"] == sys.argv[2]][-1]
assert last["merged"] is True and last["ci_first_pass"] is True and last["pr"].endswith("/pull/5"), last
assert last["source"] == "t3" and last["duration_s"] == 600, last
PY
# A changed status updates the existing record rather than adding one.
python3 -I - "$AGENT_EVAL_T3_DB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("update orchestration_v2_projection_runs set status='completed' where thread_id like '%quota-429'")
db.execute("delete from orchestration_v2_projection_turn_items where thread_id like '%quota-429' and type='error'")
db.execute("update orchestration_v2_projection_runs set status='completed', completed_at='2026-10-23T11:30:00.000Z' "
           "where thread_id like '%still-running'")
db.commit()
PY
run 0 collect
grep -q "^added: 1$" "$out" && grep -q "^updated: 1$" "$out" && grep -q "^skipped_running: 0$" "$out" \
    || fail "a changed status was not picked up" "$(cat "$out")"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "changed status did not replace the old record"
import json, sys
rows = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    rows[r["id"]] = r
assert len(rows) == 13, len(rows)
q = next(v for k, v in rows.items() if k.endswith("quota-429"))
assert q["status"] == "completed" and q["failure_kind"] == "none", q
PY
# An explicit verdict from record outranks history.
run 0 record --id "$(id_ending quota-429)" --status failed --failure-kind quality
run 0 collect
grep -q "^updated: 0$" "$out" || fail "collect overwrote an explicit record" "$(cat "$out")"
# Missing database is a structured failure, not an empty success.
AGENT_EVAL_T3_DB="$tmp/missing.sqlite" run 1 collect
grep -q "^error:" "$out" || fail "a missing T3 database is not a structured error" "$(cat "$out")"

# ── Ledger builder for statistics scenarios ──
# Each spec: lane,class,risk,status,failure_kind,ci,touch,count,at-start (minutes after 2026-10-22T00:00Z).
ledger() {
    python3 -I - "$AGENT_EVAL_STATE/outcomes.jsonl" "$@" <<'PY'
import datetime as dt, json, sys
path, specs = sys.argv[1], sys.argv[2:]
base = dt.datetime(2026, 10, 22, tzinfo=dt.timezone.utc)
seq = 0
def tri(x):
    return {"t": True, "f": False, "-": None}[x]
with open(path, "a") as fh:
    for spec in specs:
        lane, cls, risk, status, kind, ci, touch, count, start = spec.split(",")
        for i in range(int(count)):
            seq += 1
            at = base + dt.timedelta(minutes=int(start) + i * 10)
            fh.write(json.dumps({
                "id": f"x{seq}", "at": at.strftime("%Y-%m-%dT%H:%M:%SZ"), "lane": lane, "provider": "p", "model": "m",
                "class": cls, "class_source": "assigned", "risk": risk, "ticket": None, "status": status,
                "failure_kind": kind, "duration_s": 100 + i * 100, "items": 1, "attempt": 1, "escalated_from": None,
                "pr": None, "ci_first_pass": tri(ci), "review_findings": None, "merged": None, "reverted": False,
                "human_touch": tri(touch), "cost_usd": None, "source": "record"}) + "\n")
PY
}
json_get() { # file key... : walk nested keys of a JSON file and print the value
    python3 -I - "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d[k]
print(d)
PY
}

# ── Judged outcomes, Wilson bound and the prior-weighted mean ──
fresh stats
# claude-sonnet / impl: 8 successes + 2 quality failures judged; availability failures must not count.
ledger "claude-sonnet,impl,R1,completed,none,t,f,8,0" \
    "claude-sonnet,impl,R1,failed,quality,-,-,2,100" \
    "claude-sonnet,impl,R1,failed,infra,-,-,1,200" \
    "claude-sonnet,impl,R1,failed,quota,-,-,1,210" \
    "claude-sonnet,impl,R1,failed,timeout,-,-,1,220"
run 0 weights --json
cp "$out" "$tmp/w.json"
python3 - "$tmp/w.json" <<'PY' || fail "weights --json shape or statistics are wrong"
import json, math, sys
d = json.load(open(sys.argv[1]))
assert list(d) == ["lanes"], list(d)
cell = d["lanes"]["claude-sonnet"]["impl"]
assert sorted(cell) == ["cooldown_until", "infra_rate", "median_s", "n", "quality_lb", "quality_mean"], sorted(cell)
assert cell["n"] == 10, cell
# Wilson 8/10 at z=1.96, worked by hand: (0.8 + 1.9208 - 1.96*sqrt((0.16 + 0.09604)/10)) / 1.38416
s, n, z = 8, 10, 1.96
lb = (s / n + z * z / (2 * n) - z * math.sqrt((s / n * (1 - s / n) + z * z / (4 * n)) / n)) / (1 + z * z / n)
assert abs(lb - 0.4902) < 5e-4, lb
assert abs(cell["quality_lb"] - lb) < 1e-4, cell
# (prior_weight * prior + successes) / (prior_weight + n) = (6*0.88 + 8) / 16
assert abs(cell["quality_mean"] - (6 * 0.88 + 8) / 16) < 1e-4, cell
assert abs(cell["quality_mean"] - 0.83) < 1e-4
assert abs(cell["infra_rate"] - 3 / 13) < 1e-4, cell
assert cell["median_s"] is not None
assert cell["cooldown_until"] is None
PY
run 0 weights --json --class review
[ "$(json_get "$out" lanes)" = "{}" ] || fail "--class did not filter weights" "$(cat "$out")"

# Unknown ci_first_pass and human_touch do not count against a lane; known bad values do.
fresh unknowns
ledger "claude-haiku,docs,R0,completed,none,-,-,5,0" \
    "claude-haiku,docs,R0,completed,none,f,-,1,100" \
    "claude-haiku,docs,R0,completed,none,-,t,1,110"
run 0 scoreboard --json
python3 - "$out" <<'PY' || fail "unknown fields were counted against the lane"
import json, sys
r = json.load(open(sys.argv[1]))["rows"][0]
assert r["judged"] == 7 and r["success"] == 5, r
assert abs(r["quality_mean"] - (6 * 0.75 + 5) / 13) < 1e-4, r
PY

# ── Cooldown ──
fresh cooldown
ledger "claude-haiku,docs,R0,completed,none,-,-,1,0" \
    "claude-haiku,docs,R0,failed,infra,-,-,1,600" \
    "claude-haiku,docs,R0,failed,quota,-,-,1,610" \
    "claude-haiku,docs,R0,failed,timeout,-,-,1,620" \
    "opencode-mimo-free,impl,R1,failed,infra,-,-,2,600" \
    "opencode-mimo-free,impl,R1,completed,none,-,-,1,640"
# haiku's third consecutive failure is 2026-10-22T10:20Z: cooldown to 12:20Z. 2h from the newest failure.
AGENT_EVAL_NOW="2026-10-22T11:00:00+00:00" run 0 weights --json
[ "$(json_get "$out" lanes claude-haiku docs cooldown_until)" = "2026-10-22T12:20:00Z" ] \
    || fail "cooldown did not trigger at the third consecutive failure" "$(cat "$out")"
[ "$(json_get "$out" lanes opencode-mimo-free impl cooldown_until)" = "None" ] \
    || fail "two failures and a success put a lane in cooldown" "$(cat "$out")"
AGENT_EVAL_NOW="2026-10-22T12:30:00+00:00" run 0 weights --json
[ "$(json_get "$out" lanes claude-haiku docs cooldown_until)" = "None" ] \
    || fail "cooldown did not expire after cooldown_hours" "$(cat "$out")"
# Failures are availability, not quality: the cooled lane keeps its one good result.
[ "$(json_get "$out" lanes claude-haiku docs n)" = 1 ] || fail "infra failures counted as judged"
AGENT_EVAL_NOW="2026-10-22T11:00:00+00:00" run 0 scoreboard
grep -q "2026-10-22T12:20:00Z" "$out" || fail "scoreboard does not show the cooldown" "$(cat "$out")"

# ── Verdicts at the lanes.toml thresholds ──
fresh verdicts
ledger "claude-sonnet,impl,R1,completed,none,t,f,10,0" \
    "claude-sonnet,docs,R0,completed,none,t,f,8,0" \
    "claude-sonnet,docs,R0,failed,quality,-,-,2,100" \
    "claude-sonnet,test,R0,completed,none,t,f,4,0" \
    "claude-sonnet,test,R0,failed,quality,-,-,6,100" \
    "claude-sonnet,review,R1,completed,none,t,f,7,0" \
    "claude-sonnet,plan,R1,completed,none,t,f,10,0" \
    "claude-sonnet,plan,R1,failed,infra,-,-,6,200" \
    "opencode-glm-flash-free,impl,R1,completed,none,t,f,15,0" \
    "opencode-deepseek-flash-free,impl,R1,completed,none,t,f,14,0" \
    "opencode-mimo-free,impl,R1,completed,none,t,f,15,0" \
    "opencode-mimo-free,impl,R1,failed,quality,-,-,5,200"
run 0 verdicts
row() { grep -E "^  $1,$2," "$out" || true; }
row claude-sonnet impl | grep -q ",keep,null$" || fail "10/10 is not keep" "$(cat "$out")"
row claude-sonnet docs | grep -q ",probation,null$" || fail "8/10 (lb 0.49) is not probation" "$(cat "$out")"
row claude-sonnet test | grep -q ",drop-for-class,null$" || fail "4/10 is not drop-for-class" "$(cat "$out")"
row claude-sonnet review | grep -q ",insufficient data,null$" || fail "7 judged is not insufficient data" "$(cat "$out")"
row claude-sonnet plan | grep -q ",10,.*,keep,null$" || fail "infra failures changed the judged count or verdict" "$(cat "$out")"
row opencode-glm-flash-free impl | grep -q ",keep,allow R2$" || fail "15 clean R1 outcomes on an R1 lane do not advise allow R2" "$(cat "$out")"
row opencode-deepseek-flash-free impl | grep -q ",null$" || fail "14 outcomes advised promotion" "$(cat "$out")"
row opencode-deepseek-flash-free impl | grep -q "allow R2" && fail "14 outcomes advised promotion"
row opencode-mimo-free impl | grep -q "allow R2" && fail "a 75% lane below promote_lb advised promotion"
row claude-sonnet impl | grep -q "allow R2" && fail "an R3 lane was advised to be allowed R2"
run 0 verdicts --since 1
grep -q "^verdicts: 0 results$" "$out" || fail "--since did not narrow the evidence window" "$(cat "$out")"
AGENT_EVAL_NOW="2027-03-01T00:00:00+00:00" run 0 verdicts
grep -q "^verdicts: 0 results$" "$out" || fail "an out-of-window ledger is not a definitive empty state" "$(cat "$out")"

# ── enrich with a stubbed gh ──
cat >"$tmp/gh-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = search ] && [ "$2" = prs ] || { echo "unexpected gh call: $*" >&2; exit 9; }
key="${*: -1}"
merged=0
for a in "$@"; do [ "$a" = "--merged" ] && merged=1; done
case "$key" in
JDW-12)
    echo '[{"number":5,"title":"feat: the thing JDW-12","url":"https://example.invalid/o/r/pull/5","state":"closed"},{"number":6,"title":"Revert \"feat: the thing JDW-12\"","url":"https://example.invalid/o/r/pull/6","state":"closed"}]'
    ;;
JDW-13)
    if [ "$merged" = 1 ]; then echo '[]'; else echo '[{"number":7,"title":"fix: JDW-13","url":"https://example.invalid/o/r/pull/7","state":"closed"}]'; fi
    ;;
JDW-14)
    if [ "$merged" = 1 ]; then echo '[]'; else echo '[{"number":8,"title":"feat: JDW-14","url":"https://example.invalid/o/r/pull/8","state":"open"}]'; fi
    ;;
JDW-15)
    if [ "$merged" = 1 ]; then echo '[{"number":9,"title":"feat: JDW-15","url":"https://example.invalid/o/r/pull/9","state":"closed"}]'; else echo '[{"number":9,"title":"feat: JDW-15","url":"https://example.invalid/o/r/pull/9","state":"closed"}]'; fi
    ;;
*) echo '[]' ;;
esac
STUB
chmod +x "$tmp/gh-stub"
fresh enrich
for k in 12 13 14 15 16; do
    "$ae" record --id "e-$k" --lane claude-sonnet --class impl --status completed --ticket "JDW-$k" >/dev/null
done
"$ae" record --id e-none --lane claude-sonnet --class impl --status completed >/dev/null
AGENT_EVAL_GH="$tmp/gh-stub" run 0 enrich
grep -q "^tickets: 5$" "$out" || fail "enrich did not look up five tickets" "$(cat "$out")"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "enrich set the wrong merged, reverted or pr"
import json, sys
rows = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    rows[r["id"]] = r
def chk(k, merged, reverted, pr):
    r = rows[f"e-{k}"]
    assert (r["merged"], r["reverted"], r["pr"]) == (merged, reverted, pr), (k, r["merged"], r["reverted"], r["pr"])
chk(12, True, True, "https://example.invalid/o/r/pull/5")
chk(13, False, None, "https://example.invalid/o/r/pull/7")
chk(14, None, None, "https://example.invalid/o/r/pull/8")
chk(15, True, False, "https://example.invalid/o/r/pull/9")
chk(16, None, None, None)
assert rows["e-none"]["merged"] is None
PY
# A reverted outcome no longer counts as a quality success.
run 0 scoreboard --json --lane claude-sonnet
python3 - "$out" <<'PY' || fail "a reverted PR still counted as a success"
import json, sys
r = json.load(open(sys.argv[1]))["rows"][0]
assert r["attempts"] == 6 and r["success"] == 5, r
PY
AGENT_EVAL_GH="$tmp/no-gh" run 1 enrich
grep -q "^error:\|^errors: 5$" "$out" || fail "a missing gh was not reported" "$(cat "$out")"

# ── report ──
# Window arithmetic is the same as agent-report's compute_windows, across a month of anchor dates.
python3 -I - "$ae" "$report_tool" <<'PY' || fail "report windows differ from agent-report"
import datetime as dt, sys
from importlib.machinery import SourceFileLoader
mine = SourceFileLoader("agent_eval", sys.argv[1]).load_module()
theirs = SourceFileLoader("agent_report", sys.argv[2]).load_module()
day = dt.date(2026, 1, 1)
checked = 0
while day < dt.date(2027, 2, 1):
    for w in ("daily", "weekly", "biweekly", "monthly"):
        assert mine.compute_windows(w, day) == theirs.compute_windows(w, day), (w, day)
        checked += 1
    day += dt.timedelta(days=1)
assert checked == 4 * (dt.date(2027, 2, 1) - dt.date(2026, 1, 1)).days
PY
fresh empty
rm -rf "$AGENT_EVAL_STATE"
for w in daily weekly biweekly monthly; do
    run 0 report --window "$w" --end 2026-10-23 --format json
    cp "$out" "$tmp/r-$w.json"
    python3 - "$tmp/r-$w.json" "$w" <<'PY' || fail "empty-ledger $w report is wrong"
import datetime as dt, json, sys
r = json.load(open(sys.argv[1]))
assert r["window"] == sys.argv[2] and r["empty"] is True, r
assert dt.date.fromisoformat(r["start"]) < dt.date.fromisoformat(r["end"]) <= dt.date(2026, 10, 23)
p = r["previous"]
assert p["end"] == r["start"], (p["end"], r["start"])
assert r["dispatches"]["total"] == 0 and p["dispatches"]["total"] == 0
assert any("empty" in o.lower() for o in r["observations"]), r["observations"]
PY
    run 0 report --window "$w" --end 2026-10-23 --format md
    grep -qi "ledger is empty" "$out" || fail "empty-ledger $w md report does not say so" "$(cat "$out")"
done
run 0 report --window weekly --end 2026-10-23
grep -q '"window": "weekly"' "$out" || fail "report does not default to json"

fresh report
# Weekly window for end 2026-10-23: 2026-10-12 .. 2026-10-19; previous 2026-10-05 .. 2026-10-12.
python3 -I - "$AGENT_EVAL_STATE" <<'PY'
import json, sys
d = sys.argv[1]
def asg(i, at, lane, cls, risk, mult):
    return {"id": f"a{i}", "at": at, "lane": lane, "provider": "p", "model": "m", "class": cls, "risk": risk,
            "ticket": None, "pace": {"used": 40, "line": 50, "multiplier": mult}, "implementer": None}
def out(i, at, lane, cls, status, kind):
    return {"id": f"o{i}", "at": at, "lane": lane, "provider": "p", "model": "m", "class": cls,
            "class_source": "assigned", "risk": "R1", "ticket": None, "status": status, "failure_kind": kind,
            "duration_s": 60, "items": 1, "attempt": 1, "escalated_from": None, "pr": None, "ci_first_pass": None,
            "review_findings": None, "merged": None, "reverted": None, "human_touch": None, "cost_usd": None,
            "source": "record"}
a = [asg(1, "2026-10-13T09:00:00Z", "claude-sonnet", "impl", "R1", 1.2),
     asg(2, "2026-10-14T09:00:00Z", "claude-sonnet", "docs", "R0", 1.4),
     asg(3, "2026-10-15T09:00:00Z", "opencode-nim-glm", "impl", "R1", 1.4),
     asg(4, "2026-10-06T09:00:00Z", "claude-sonnet", "impl", "R1", 1.0),
     asg(5, "2026-10-19T00:00:00Z", "claude-sonnet", "impl", "R1", 1.0)]
o = [out(1, "2026-10-13T10:00:00Z", "claude-sonnet", "impl", "completed", "none"),
     out(2, "2026-10-14T10:00:00Z", "claude-sonnet", "docs", "failed", "quality"),
     out(3, "2026-10-15T10:00:00Z", "opencode-nim-glm", "impl", "failed", "quota"),
     out(4, "2026-10-15T10:10:00Z", "opencode-nim-glm", "impl", "failed", "infra"),
     out(5, "2026-10-15T10:20:00Z", "opencode-nim-glm", "impl", "failed", "timeout"),
     out(6, "2026-10-06T10:00:00Z", "claude-sonnet", "impl", "completed", "none"),
     out(7, "2026-10-19T00:00:00Z", "claude-sonnet", "impl", "completed", "none")]
open(d + "/assignments.jsonl", "w").write("".join(json.dumps(x) + "\n" for x in a))
open(d + "/outcomes.jsonl", "w").write("".join(json.dumps(x) + "\n" for x in o))
PY
run 0 report --window weekly --end 2026-10-23 --format json
cp "$out" "$tmp/rep.json"
python3 - "$tmp/rep.json" <<'PY' || fail "weekly report contents are wrong"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["empty"] is False and (r["start"], r["end"]) == ("2026-10-12", "2026-10-19"), r
p = r["previous"]
assert (p["start"], p["end"]) == ("2026-10-05", "2026-10-12"), p
assert r["dispatches"]["total"] == 3 and p["dispatches"]["total"] == 1, (r["dispatches"], p["dispatches"])
assert r["dispatches"]["by_lane"] == {"claude-sonnet": 2, "opencode-nim-glm": 1}, r["dispatches"]
assert r["dispatches"]["by_class"] == {"docs": 1, "impl": 2}, r["dispatches"]
assert p["dispatches"]["by_lane"] == {"claude-sonnet": 1}
sonnet = r["outcomes"]["by_lane"]["claude-sonnet"]
assert (sonnet["attempts"], sonnet["completed"], sonnet["judged"], sonnet["success"]) == (2, 1, 2, 1), sonnet
assert sonnet["completion"] == 0.5 and sonnet["quality"] == 0.5, sonnet
glm = r["outcomes"]["by_lane"]["opencode-nim-glm"]
assert (glm["attempts"], glm["judged"], glm["quality"]) == (3, 0, None), glm
assert r["pace"]["assignments"] == 3 and r["pace"]["multiplier_min"] == 1.2 and r["pace"]["multiplier_max"] == 1.4, r["pace"]
assert [c["lane"] for c in r["cooldowns"]] == ["opencode-nim-glm"], r["cooldowns"]
assert r["cooldowns"][0]["until"] == "2026-10-15T12:20:00Z", r["cooldowns"]
assert any("cooldown" in x for x in r["observations"]), r["observations"]
assert p["pace"]["assignments"] == 1 and p["cooldowns"] == []
assert isinstance(r["verdicts"], list) and r["verdicts"], r["verdicts"]
assert set(r["verdicts"][0]) == {"lane", "class", "n", "quality_lb", "verdict", "advise"}
PY
run 0 report --window weekly --end 2026-10-23 --format md
cp "$out" "$tmp/rep.md"
python3 - "$tmp/rep.md" <<'PY' || fail "markdown report is not valid GitHub markdown with tables"
import re, sys
text = open(sys.argv[1]).read()
lines = text.split("\n")
assert lines[0].startswith("## "), lines[0]
assert text.endswith("\n") and "\t" not in text
def cells(line):
    return len(re.split(r"(?<!\\)\|", line.strip())) - 2
tables = 0
i = 0
while i < len(lines):
    if lines[i].startswith("|"):
        assert i > 0 and lines[i - 1] == "", f"table at line {i + 1} is not preceded by a blank line"
        sep = lines[i + 1]
        assert re.fullmatch(r"\|(---\|)+", sep), sep
        n = cells(lines[i])
        assert cells(sep) == n, (lines[i], sep)
        j = i + 2
        while j < len(lines) and lines[j].startswith("|"):
            assert cells(lines[j]) == n, (n, lines[j])
            j += 1
        assert j > i + 2, "table has no rows"
        tables += 1
        i = j
    else:
        i += 1
assert tables >= 4, tables
for heading in ("Dispatches by lane", "Completion and quality by lane", "Cooldowns", "Verdicts", "Observations"):
    assert f"### {heading}" in text, heading
assert "opencode-nim-glm" in text and "claude-sonnet" in text
PY
run 2 report --window weekly --end 2026-13-45

# ── No secret or prompt text is ever written ──
if grep -rqi "secret prompt\|token\|api_key" "$tmp"/state-* 2>/dev/null; then
    fail "a ledger contains something that looks like a secret or prompt" "$(grep -rli "secret prompt\|token\|api_key" "$tmp"/state-*)"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$0" || fail "shellcheck reports issues in this test"
fi

echo "PASS: agent-eval"
