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
export AGENT_EVAL_STREAMS="$tmp/streams.json"
printf '%s\n' '{"jiraSite":"https://x.invalid","streams":{"jdwillmsen":{"jira":"JDW"},"jdwlabs":{"jira":"JDWLABS"}}}' \
    >"$AGENT_EVAL_STREAMS"

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

# A new row needs a verdict: without --status it would silently become a success.
run 2 record --id brand-new --lane claude-sonnet --class impl
grep -q "^code: usage" "$out" && grep -q "status" "$out" || fail "a new row without --status is not a usage error" "$(cat "$out")"
run 2 record --id a-1 --ticket jdw-1
run 2 record --id a-1 --ticket JDW
run 2 record --id a-1 --pr http://github.com/o/r/pull/5
run 2 record --id a-1 --pr https://example.com/o/r/pull/5
run 2 record --id a-1 --pr https://github.com/o/r/issues/5
before="$(wc -l <"$AGENT_EVAL_STATE/outcomes.jsonl")"
run 0 record --id a-1 --pr https://github.com/o/r/pull/5 --ticket JDW-2
[ "$(wc -l <"$AGENT_EVAL_STATE/outcomes.jsonl")" = $((before + 1)) ] || fail "a valid amendment was not written"
# Notes are capped and scrubbed before they are stored.
long="$(python3 -I -c "print('word ' * 80)")"
run 0 record --id a-1 --note "$long"
note_len="$(python3 -I -c "import json,sys; print(len([json.loads(l) for l in open(sys.argv[1])][-1]['note']))" \
    "$AGENT_EVAL_STATE/outcomes.jsonl")"
[ "$note_len" = 200 ] || fail "a long note was not capped at 200" "$note_len"
run 0 record --id a-1 --note "retry failed, login used password=hunter2 and then gave up"
grep -q "hunter2" "$AGENT_EVAL_STATE/outcomes.jsonl" && fail "a password reached the ledger"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "a note with a password was not redacted in place"
import json, sys
note = [json.loads(l) for l in open(sys.argv[1])][-1]["note"]
assert note == "retry failed, login used [redacted] and then gave up", note
PY
for secret in 'token: abc123def' 'API_KEY=zzz' 'ghp_abcdefghijklmnopqrstuvwxyz0123456789' \
    'sk-proj-abcdefghijklmnopqrstuvwxyz' 'Bearer eyJhbGciOi' 'blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5 end'; do
    run 0 record --id a-1 --note "see $secret now"
    python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" "$secret" <<'PY' || fail "credential shape '$secret' was stored"
import json, sys
note = [json.loads(l) for l in open(sys.argv[1])][-1]["note"]
assert "[redacted]" in note and note.startswith("see "), note
assert max(sys.argv[2].split(), key=len) not in note, note
PY
done

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
import hashlib, json, re, sys
def t3id(slug):
    tid = "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3A" + slug
    return "t3:" + hashlib.sha256(tid.encode()).hexdigest()[:16]
by_id = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    by_id[r["id"]] = r
slugs = ("build-thing-r2 quota-429 timeout gone-410 context mystery-error mystery-with-commit usage-limit "
         "unknown-model interrupted cancelled no-model-in-run").split()
rows = {slug: by_id[t3id(slug)] for slug in slugs}
assert len(by_id) == len(slugs)
for i in by_id:
    assert re.fullmatch(r"t3:[0-9a-f]{16}", i), ("an id embeds the thread or its title slug", i)
a = rows["build-thing-r2"]
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
# The ledger id of the collected task with slug $1 (the fixture thread id is hashed, never stored).
id_ending() {
    python3 -I -c "
import hashlib, sys
tid = 'thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3A' + sys.argv[1]
print('t3:' + hashlib.sha256(tid.encode()).hexdigest()[:16])" "$1"
}
quota_id="$(id_ending build-thing-r2)"
run 0 record --id "$quota_id" --merged true --ci-first-pass true --pr https://github.com/o/r/pull/5
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
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" "$(id_ending quota-429)" <<'PY' || fail "changed status did not replace the old record"
import json, sys
rows = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    rows[r["id"]] = r
assert len(rows) == 13, len(rows)
q = rows[sys.argv[2]]
assert q["status"] == "completed" and q["failure_kind"] == "none", q
PY
# An explicit verdict from record outranks history.
run 0 record --id "$(id_ending quota-429)" --status failed --failure-kind quality
run 0 collect
grep -q "^updated: 0$" "$out" || fail "collect overwrote an explicit record" "$(cat "$out")"
# A lane chosen with record on a collected row survives the next collect.
unknown_id="$(id_ending unknown-model)"
run 0 record --id "$unknown_id" --lane claude-sonnet
run 0 collect
grep -q "^updated: 0$" "$out" || fail "collect overwrote a lane set by record" "$(cat "$out")"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" "$unknown_id" <<'PY' || fail "record --lane on a collected row did not stick"
import json, sys
last = [r for r in map(json.loads, open(sys.argv[1])) if r["id"] == sys.argv[2]][-1]
assert last["lane"] == "claude-sonnet" and last["source"] == "record", last
PY
# Missing database is a structured failure, not an empty success.
AGENT_EVAL_T3_DB="$tmp/missing.sqlite" run 1 collect
grep -q "^error:" "$out" || fail "a missing T3 database is not a structured error" "$(cat "$out")"

# Ids written by early collects embedded the thread id: a re-collect finds them by thread and adds no second row.
fresh legacy
python3 -I - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY'
import json, sys
tid = "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aquota-429"
rec = dict.fromkeys(("at", "lane", "provider", "model", "risk", "ticket", "duration_s", "items", "escalated_from",
                     "pr", "ci_first_pass", "review_findings", "merged", "reverted", "human_touch", "cost_usd"))
rec.update(id="t3:" + tid, at="2026-10-23T10:00:05Z", lane="opencode-glm-flash-free", status="failed",
           failure_kind="quota", **{"class": "docs", "class_source": "heuristic"}, attempt=1, source="t3")
open(sys.argv[1], "w").write(json.dumps(rec) + "\n")
PY
run 0 collect
grep -q "^added: 12$" "$out" && grep -q "^updated: 1$" "$out" || fail "a legacy-id row was added a second time" "$(cat "$out")"
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "legacy id was duplicated or rewritten"
import json, sys
latest = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    latest[r["id"]] = r
assert len(latest) == 13, len(latest)
assert sum("quota-429" in i for i in latest) == 1, list(latest)
assert latest["t3:thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aquota-429"]["duration_s"] == 5
PY

# A run that ends before it starts has a duration of zero, never a negative one.
fresh negative
cp "$AGENT_EVAL_T3_DB" "$tmp/t3-neg.sqlite"
python3 -I - "$tmp/t3-neg.sqlite" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
t = "thread:delegated-task:command%3Amcp%3Aabc%3Adelegate-task%3Aclock-skew"
db.execute("insert into orchestration_v2_projection_threads values (?,?)", (t, "Implement skew"))
payload = {"modelSelection": {"model": "opencode/glm-5.3-flash-free"}, "startedAt": "2026-10-23T10:05:00.000Z"}
db.execute("insert into orchestration_v2_projection_runs values (?,?,?,?,?,?,?,?)",
           ("run:skew", t, 1, "opencode", "completed", "2026-10-23T10:00:00.000Z", "2026-10-23T10:00:00.000Z",
            json.dumps(payload)))
db.commit()
PY
AGENT_EVAL_T3_DB="$tmp/t3-neg.sqlite" run 0 collect
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "a negative duration reached the ledger"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert min(r["duration_s"] for r in rows if r["duration_s"] is not None) == 0, rows
assert sum(1 for r in rows if r["duration_s"] == 0) == 1
PY
run 0 record --id a-neg --lane claude-sonnet --status completed --duration-s -30
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "record kept a negative duration"
import json, sys
assert [json.loads(l) for l in open(sys.argv[1])][-1]["duration_s"] == 0
PY

# A T3 database that is locked for writing is read from a copy; the copy is removed afterwards.
fresh locked
cp "$AGENT_EVAL_T3_DB" "$tmp/t3-locked.sqlite"
rm -f "$tmp/lock.ready" "$tmp/lock.release"
python3 -I - "$tmp/t3-locked.sqlite" "$tmp/lock.ready" "$tmp/lock.release" <<'PY' &
import os, sqlite3, sys, time
db = sqlite3.connect(sys.argv[1], isolation_level=None)
db.execute("begin exclusive")
probe = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=0.2)
try:
    probe.execute("select 1 from sqlite_master limit 1").fetchall()
except sqlite3.OperationalError:
    open(sys.argv[2], "w").close()
for _ in range(600):
    if os.path.exists(sys.argv[3]):
        break
    time.sleep(0.1)
db.execute("rollback")
PY
locker=$!
for _ in $(seq 100); do [ -e "$tmp/lock.ready" ] && break; sleep 0.1; done
[ -e "$tmp/lock.ready" ] || { touch "$tmp/lock.release"; fail "the fixture could not lock the T3 database"; }
mkdir -p "$tmp/tmpdir"
TMPDIR="$tmp/tmpdir" AGENT_EVAL_T3_TIMEOUT_S=0.3 AGENT_EVAL_T3_DB="$tmp/t3-locked.sqlite" run 0 collect
touch "$tmp/lock.release"
wait "$locker"
grep -q "^added: 13$" "$out" || fail "a locked database was not read through a copy" "$(cat "$out")"
[ -z "$(ls -A "$tmp/tmpdir")" ] || fail "the database copy was left behind" "$(ls -A "$tmp/tmpdir")"

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
assert sorted(cell) == ["cooldown_until", "infra_rate", "median_s", "n", "quality_lb", "quality_mean", "success"], \
    sorted(cell)
assert cell["n"] == 10 and cell["success"] == 8, cell
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

# --since is bounded to 1..3650 days.
fresh since
for bad in 0 -3 3651 99999 abc; do
    run 2 scoreboard --since "$bad"
    grep -q "^code: usage" "$out" || fail "--since $bad is not a usage error" "$(cat "$out")"
done
run 2 collect --since 0
run 2 enrich --since 3651
run 2 verdicts --since -1
run 0 scoreboard --since 3650
run 0 scoreboard --since 1

# ── Interrupted runs are neither a success nor a quality failure ──
fresh interrupted
ledger "claude-haiku,docs,R0,completed,none,t,f,4,0" \
    "claude-haiku,docs,R0,interrupted,none,-,-,3,100"
run 0 scoreboard --json
python3 - "$out" <<'PY' || fail "interrupted runs were judged"
import json, sys
r = json.load(open(sys.argv[1]))["rows"][0]
assert r["attempts"] == 7 and r["judged"] == 4 and r["success"] == 4, r
PY
run 0 weights --json
[ "$(json_get "$out" lanes claude-haiku docs n)" = 4 ] || fail "weights judged interrupted runs" "$(cat "$out")"

# A negative duration already in a ledger is read as zero.
fresh negative-ledger
ledger "claude-haiku,docs,R0,completed,none,t,f,1,0"
sed -i 's/"duration_s": 100/"duration_s": -50/' "$AGENT_EVAL_STATE/outcomes.jsonl"
run 0 scoreboard --json
python3 -I -c "import json,sys; assert json.load(open(sys.argv[1]))['rows'][0]['median_s'] == 0" "$out" 2>/dev/null || fail "a negative duration reached the median" "$(cat "$out")"

# ── Cooldown belongs to the lane: --class must not hide failures from other classes ──
fresh lane-cooldown
ledger "claude-haiku,docs,R0,completed,none,-,-,1,0" \
    "claude-haiku,impl,R1,failed,infra,-,-,1,600" \
    "claude-haiku,impl,R1,failed,quota,-,-,1,610" \
    "claude-haiku,test,R0,failed,timeout,-,-,1,620"
AGENT_EVAL_NOW="2026-10-22T11:00:00+00:00" run 0 weights --json --class docs
[ "$(json_get "$out" lanes claude-haiku docs cooldown_until)" = "2026-10-22T12:20:00Z" ] \
    || fail "a class filter dropped the lane's failures from its cooldown" "$(cat "$out")"
AGENT_EVAL_NOW="2026-10-22T11:00:00+00:00" run 0 scoreboard --json --class docs
python3 - "$out" <<'PY' || fail "scoreboard --class dropped the lane's cooldown"
import json, sys
rows = json.load(open(sys.argv[1]))["rows"]
assert len(rows) == 1 and rows[0]["cooldown_until"] == "2026-10-22T12:20:00Z", rows
PY

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

# Searches are scoped to the owners in the streams map, one call per owner, and only one attempt per ticket is marked.
cat >"$tmp/gh-scoped" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$GH_LOG"
owner=""
for ((i = 1; i <= $#; i++)); do
    if [ "${!i}" = --owner ]; then j=$((i + 1)); owner="${!j}"; fi
done
[ -n "$owner" ] || { echo "unscoped gh search: $*" >&2; exit 9; }
[ "$owner" = jdwlabs ] || { echo '[]'; exit 0; }
case "${*: -1}" in
JDW-20) echo '[{"number":30,"title":"feat: JDW-20","url":"https://github.com/jdwlabs/r/pull/30","state":"closed"}]' ;;
JDW-21) echo '[{"number":31,"title":"feat: JDW-21","url":"https://github.com/jdwlabs/r/pull/31","state":"closed"}]' ;;
JDW-22) echo '[{"number":32,"title":"feat: JDW-22","url":"https://github.com/jdwlabs/r/pull/32","state":"closed"}]' ;;
*) echo '[]' ;;
esac
STUB
chmod +x "$tmp/gh-scoped"
export GH_LOG="$tmp/gh.log"
rec_at() { # time args... : record with the clock at $1
    local when="$1"
    shift
    AGENT_EVAL_NOW="$when" "$ae" record "$@" >/dev/null
}
fresh enrich-scoped
# JDW-20: an abandoned failed lane, an older completed retry, and the newest completed attempt.
rec_at 2026-10-20T10:00:00+00:00 --id s20-abandoned --lane opencode-mimo-free --class impl --status failed --ticket JDW-20
rec_at 2026-10-20T11:00:00+00:00 --id s20-older --lane claude-haiku --class impl --status completed --ticket JDW-20
rec_at 2026-10-20T12:00:00+00:00 --id s20-newest --lane claude-sonnet --class impl --status completed --ticket JDW-20
# JDW-21: the older attempt is already tied to the PR; the newer, completed one is not.
rec_at 2026-10-20T10:00:00+00:00 --id s21-tied --lane claude-haiku --class impl --status completed --ticket JDW-21 \
    --pr https://github.com/jdwlabs/r/pull/31
rec_at 2026-10-20T12:00:00+00:00 --id s21-later --lane claude-sonnet --class impl --status completed --ticket JDW-21
# JDW-22: nothing completed, so nothing to mark.
rec_at 2026-10-20T10:00:00+00:00 --id s22-failed --lane claude-haiku --class impl --status failed --ticket JDW-22
rm -f "$GH_LOG"
AGENT_EVAL_GH="$tmp/gh-scoped" run 0 enrich
grep -q "^owners: 2$" "$out" || fail "enrich did not read two owners" "$(cat "$out")"
[ "$(wc -l <"$GH_LOG")" = 12 ] || fail "enrich did not make one call per owner and ticket and state" "$(cat "$GH_LOG")"
grep -vq -- "--owner" "$GH_LOG" && fail "an unscoped gh search was made" "$(cat "$GH_LOG")"
for o in jdwillmsen jdwlabs; do
    grep -q -- "--owner $o " "$GH_LOG" || fail "no search for owner $o" "$(cat "$GH_LOG")"
done
python3 - "$AGENT_EVAL_STATE/outcomes.jsonl" <<'PY' || fail "enrich marked the wrong attempts"
import json, sys
rows = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    rows[r["id"]] = r
def state(i):
    return (rows[i]["merged"], rows[i]["pr"])
assert state("s20-newest") == (True, "https://github.com/jdwlabs/r/pull/30"), state("s20-newest")
assert state("s20-older") == (None, None), state("s20-older")
assert state("s20-abandoned") == (None, None), state("s20-abandoned")
assert state("s21-tied") == (True, "https://github.com/jdwlabs/r/pull/31"), state("s21-tied")
assert state("s21-later") == (None, None), state("s21-later")
assert state("s22-failed") == (None, None), state("s22-failed")
PY
# Without a readable streams map enrich stops: it never falls back to a search over all of GitHub.
rm -f "$GH_LOG"
for bad in "$tmp/no-streams.json" "$tmp/bad-streams.json" "$tmp/empty-streams.json"; do
    printf '%s' 'not json' >"$tmp/bad-streams.json"
    printf '%s' '{"streams":{}}' >"$tmp/empty-streams.json"
    AGENT_EVAL_STREAMS="$bad" AGENT_EVAL_GH="$tmp/gh-scoped" run 1 enrich
    grep -q "^error:" "$out" || fail "enrich with $bad printed no structured error" "$(cat "$out")"
done
[ ! -e "$GH_LOG" ] || fail "enrich searched without a usable streams map" "$(cat "$GH_LOG")"

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

# ── A damaged ledger is reported, never read as a quiet window ──
fresh damaged
python3 -I - "$AGENT_EVAL_STATE" <<'PY'
import json, sys
d = sys.argv[1]
good = {"id": "g1", "at": "2026-10-13T10:00:00Z", "lane": "claude-sonnet", "class": "impl", "status": "completed",
        "failure_kind": "none"}
open(d + "/outcomes.jsonl", "w").write(json.dumps(good) + "\n{not json\n\n[1, 2]\n{\"no_id\": true}\n")
open(d + "/assignments.jsonl", "w").write("garbage\n" + json.dumps({"id": "a1", "at": "2026-10-13T09:00:00Z",
                                                                  "lane": "claude-sonnet", "class": "impl"}) + "\n")
PY
run 0 report --window weekly --end 2026-10-23 --format json
[ "$(json_get "$out" skipped_lines)" = 4 ] || fail "the report did not count unreadable lines over both ledgers" "$(cat "$out")"
[ "$(json_get "$out" dispatches total)" = 1 ] || fail "the readable lines were not used" "$(cat "$out")"
grep -q "unreadable" "$err" || fail "no stderr message for unreadable lines" "$(cat "$err")"
run 0 report --window weekly --end 2026-10-23 --format md
grep -qF "Partial: 4 unreadable ledger lines." "$out" || fail "the Markdown report hides the damaged lines" "$(cat "$out")"
run 0 scoreboard --json
[ "$(json_get "$out" skipped_lines)" = 4 ] || fail "scoreboard --json did not count unreadable lines" "$(cat "$out")"
run 0 scoreboard
grep -q "^skipped_lines: 4$" "$out" || fail "scoreboard does not show unreadable lines" "$(cat "$out")"
fresh undamaged
ledger "claude-sonnet,impl,R1,completed,none,t,f,1,0"
run 0 scoreboard --json
[ "$(json_get "$out" skipped_lines)" = 0 ] || fail "a clean ledger reports skipped lines" "$(cat "$out")"
run 0 report --window weekly --end 2026-10-23 --format md
grep -q "Partial" "$out" && fail "a clean ledger reports a partial result"

# ── No secret or prompt text is ever written ──
if grep -rqi "secret prompt\|token\|api_key" "$tmp"/state-* 2>/dev/null; then
    fail "a ledger contains something that looks like a secret or prompt" "$(grep -rli "secret prompt\|token\|api_key" "$tmp"/state-*)"
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "$0" || fail "shellcheck reports issues in this test"
fi

echo "PASS: agent-eval"
