#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-metrics runs unattended and pushes to a git remote, so everything it
# reads and writes is redirected here: synthetic transcripts in a fixture
# home, and a local bare repo standing in for the store remote.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
metrics="$here/home/dot_local/bin/executable_agent-metrics"
audit="$here/home/dot_local/bin/executable_agent-audit"
cfgsrc="$here/home/dot_config/agent-metrics"
units="$here/home/dot_config/systemd/user"
trigger="$here/home/run_onchange_53-enable-agent-metrics.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$metrics" ] || fail "agent-metrics missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$metrics" || fail "agent-metrics does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
fx="$tmp/home"
remote="$tmp/remote.git"
mkdir -p "$fx" "$tmp/config"
cp "$cfgsrc"/*.json "$tmp/config/"
git init -q --bare -b main "$remote"
python3 - "$tmp/config/config.json" "$remote" <<'PY'
import json, sys
json.dump({"store_remote": sys.argv[2]}, open(sys.argv[1], "w"))
PY

export HOME="$fx"
export CLAUDE_CONFIG_DIR="$fx/.claude"
export AGENT_METRICS_STORE="$tmp/store"
export AGENT_METRICS_STATE="$tmp/state"
export AGENT_METRICS_CONFIG="$tmp/config"
export AGENT_METRICS_NOW="2026-10-09T12:00:00+00:00"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# run <expected-exit> <args...>: stdout lands in $out, stderr in $err.
out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$metrics" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-metrics $* exited $got, want $want" "$(cat "$out" "$err")"
}

# ── CLI surface ──
run 0 --help
grep -q "collect" "$out" || fail "--help does not list collect" "$(cat "$out")"
run 0 --version
run 0
grep -q "^store:" "$out" || fail "home view does not report the store" "$(cat "$out")"
grep -q "agent-metrics init" "$out" || fail "home view does not point at init when the store is missing" "$(cat "$out")"
run 2 frobnicate
grep -q "^error:" "$out" || fail "an unknown command does not print a structured error" "$(cat "$out")"

# ── Pricing: one table in two places until the audit reads this file ──
python3 - "$audit" "$cfgsrc/pricing.json" <<'PY' || fail "pricing.json disagrees with agent-audit's PRICING table"
import ast, json, sys
tree = ast.parse(open(sys.argv[1]).read())
found = {}
for node in tree.body:
    if isinstance(node, ast.Assign):
        for t in node.targets:
            names = [e.id for e in t.elts] if isinstance(t, ast.Tuple) else [t.id] if isinstance(t, ast.Name) else []
            if "PRICING" in names or "CACHE_W5M" in names:
                found[",".join(names)] = ast.literal_eval(node.value)
p = json.load(open(sys.argv[2]))
assert {k: list(v) for k, v in found["PRICING"].items()} == p["models"], "model prices differ"
assert list(found["CACHE_W5M,CACHE_W1H"]) == [p["cache_write_5m"], p["cache_write_1h"]], "cache multipliers differ"
assert p["as_of"]
PY

# ── Fixture transcripts ──
python3 - "$fx" <<'PY'
import json, os, sys
fx = sys.argv[1]
proj = os.path.join(fx, ".claude/projects")
def write(rel, recs):
    p = os.path.join(proj, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        for r in recs:
            f.write((r if isinstance(r, str) else json.dumps(r)) + "\n")
def base(sid, cwd, entry, t, **kw):
    return {"sessionId": sid, "cwd": cwd, "entrypoint": entry, "version": "2.1.300", "gitBranch": "main",
            "timestamp": f"2026-10-08T{t}.000Z", **kw}
def usage(i, o, cr, w5, w1):
    return {"input_tokens": i, "output_tokens": o, "cache_read_input_tokens": cr,
            "cache_creation_input_tokens": w5 + w1,
            "cache_creation": {"ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1}}
def tu(i, name, **inp):
    return {"type": "tool_use", "id": i, "name": name, "input": inp}
def tr(i, err=False):
    return {"type": "tool_result", "tool_use_id": i, "content": "secret tool output", "is_error": err}

# (a) interactive session: split message, subagent, friction, output, unsafe identifiers
a, acwd = "aaaa-1", os.path.join(fx, "projects/acme/app")
A = lambda t, **kw: base(a, acwd, "cli", t, **kw)
secret = "ghp_" + "Q" * 36
write("-a/aaaa-1.jsonl", [
    A("10:00:00", type="user", message={"role": "user", "content": f"fix it {secret} the launch codes are purple"}),
    A("10:00:10", type="assistant", message={"id": "m1", "model": "claude-opus-5-5", "usage": usage(100, 50, 1000, 200, 0),
        "content": [tu("tu1", "Bash", command="git commit -m 'the launch codes are purple'")]}),
    A("10:00:11", type="assistant", message={"id": "m1", "model": "claude-opus-5-5", "usage": usage(100, 80, 1000, 200, 0),
        "content": [tu("tu2", "Bash", command="gh pr create --fill"),
                    tu("tu3", "Skill", skill="bad name $ " + "x" * 100),
                    tu("tu6", "Skill", skill="ghp_" + "Q" * 36),
                    tu("tu7", "Skill", skill="x" * 100),
                    tu("tu4", "mcp__jira__search", q="purple"),
                    tu("tu5", "Agent", subagent_type="Explore", prompt="purple")]}),
    A("10:00:20", type="user", message={"role": "user", "content": [tr("tu1"), tr("tu2", True), tr("tu3"), tr("tu4"), tr("tu5")]}),
    A("10:00:30", type="system", subtype="compact_boundary"),
    A("10:00:40", type="assistant", isApiErrorMessage=True, apiErrorStatus=429,
      message={"id": "e1", "model": "<synthetic>", "content": [{"type": "text", "text": "rate limited"}]}),
    A("10:00:50", type="user", message={"role": "user", "content": "[Request interrupted by user]"}),
    A("10:07:30", type="user", message={"role": "user", "content": "next"}),
    A("10:07:40", type="assistant", message={"id": "m2", "model": "claude-sonnet-5-5", "usage": usage(10, 20, 0, 0, 100),
        "content": [{"type": "text", "text": "done, purple"}]}),
    {"type": "pr-link", "sessionId": a, "prNumber": 7, "prRepository": "acme/app",
     "prUrl": "https://example.invalid/acme/app/pull/7", "timestamp": "2026-10-08T10:07:45.000Z"},
    "{this line is not json",
])
write("-a/aaaa-1/subagents/agent-x1.jsonl", [
    A("10:00:15", type="assistant", isSidechain=True, agentId="x1",
      message={"id": "m3", "model": "claude-haiku-4-5-20251001", "usage": usage(1000, 100, 0, 0, 0), "content": []}),
])

# (b) scripted pipeline session
b, bcwd = "bbbb-2", os.path.join(fx, ".no-mistakes/worktrees/x")
write("-b/bbbb-2.jsonl", [
    base(b, bcwd, "sdk-cli", "11:00:00", type="user", message={"role": "user", "content": "review"}),
    base(b, bcwd, "sdk-cli", "11:00:30", type="assistant",
         message={"id": "n1", "model": "claude-opus-5-5", "usage": usage(1, 1, 0, 0, 0), "content": []}),
])

# (c) empty file, (d) records with no timestamps
write("-c/cccc-3.jsonl", [])
write("-d/dddd-4.jsonl", [{"type": "user", "sessionId": "dddd-4", "message": {"role": "user", "content": "hi"}}])

# (e) null usage fields and a model the pricing file does not know
e, ecwd = "eeee-5", os.path.join(fx, "scratch")
write("-e/eeee-5.jsonl", [
    base(e, ecwd, "cli", "12:00:00", type="user", message={"role": "user", "content": "go"}),
    base(e, ecwd, "cli", "12:00:05", type="assistant", message={"id": "p1", "model": "claude-opus-5-5",
         "usage": {"input_tokens": None, "output_tokens": None, "cache_read_input_tokens": None,
                   "cache_creation_input_tokens": None, "cache_creation": None}, "content": None}),
    base(e, ecwd, "cli", "12:00:09", type="assistant", message={"id": "p2", "model": "mystery-model-1",
         "usage": {"output_tokens": 5}, "content": []}),
])
PY
P="$CLAUDE_CONFIG_DIR/projects"

# ── Row builder ──
run 0 row "$P/-a/aaaa-1.jsonl"
cp "$out" "$tmp/row-a.json"
python3 - "$tmp/row-a.json" <<'PY' || fail "row for the interactive session is wrong" "$(cat "$tmp/row-a.json")"
import json, re, sys
raw = open(sys.argv[1]).read()
r = json.loads(raw)
def eq(k, want, got=None):
    got = r.get(k) if got is None else got
    assert got == want, f"{k}: got {got!r}, want {want!r}"
eq("schema", 1); eq("session_id", "aaaa-1"); eq("entrypoint", "cli"); eq("cli_version", "2.1.300")
eq("started_at", "2026-10-08T10:00:00Z"); eq("ended_at", "2026-10-08T10:07:40Z")
eq("population", "interactive"); eq("pipeline", None); eq("repo", "acme/app")
assert re.fullmatch(r"[0-9a-f]{12}", r["cwd_hash"]), r["cwd_hash"]
eq("wall_s", 460); eq("active_s", 60); eq("idle_s", 400); eq("wait_human_s", 400)
eq("prompts", 2); eq("interrupts", 1)
opus = r["models"]["main"]["claude-opus-5-5"]
eq("opus", {"calls": 1, "input": 100, "output": 80, "cache_read": 1000, "cache_write_5m": 200,
            "cache_write_1h": 0, "cost_usd": 0.0032}, opus)
eq("sonnet", {"calls": 1, "input": 10, "output": 20, "cache_read": 0, "cache_write_5m": 0,
              "cache_write_1h": 100, "cost_usd": 0.00062}, r["models"]["main"]["claude-sonnet-5-5"])
eq("haiku", {"calls": 1, "input": 1000, "output": 100, "cache_read": 0, "cache_write_5m": 0,
             "cache_write_1h": 0, "cost_usd": 0.0015}, r["models"]["subagent"]["claude-haiku-4-5-20251001"])
assert "<synthetic>" not in json.dumps(r["models"]), "the synthetic error model was counted as a model"
eq("cost_usd", 0.00532); eq("unpriced_models", [])
eq("cache_read_share", 0.4149); eq("model_switches", 1); eq("compactions", 1)
eq("tool_errors", 1); eq("denials", 0); eq("rate_limits", 1); eq("api_errors", 1)
eq("commits", 1); eq("pushes", 0); eq("prs_created", 0)
eq("pr_links", [{"repo": "acme/app", "number": 7}])
eq("tools", {"Agent": 1, "Bash": 2, "Skill": 3, "mcp__jira__search": 1})
eq("mcp", {"jira": 1}); eq("subagent_types", {"Explore": 1}); eq("subagent_runs", 1)
eq("skills", {"_invalid": 1, "_redacted": 1, "x" * 64: 1})
eq("bad_lines", 1)
for leak in ("ghp_", "purple", "secret tool output", "example.invalid"):
    assert leak not in raw, f"{leak!r} leaked into the row"
PY

run 0 row "$P/-b/bbbb-2.jsonl"
python3 - "$out" <<'PY' || fail "row for the scripted session is wrong" "$(cat "$out")"
import json, sys
r = json.load(open(sys.argv[1]))
assert (r["population"], r["pipeline"], r["repo"]) == ("scripted", "no-mistakes", None), r
assert r["prompts"] == 1 and r["wall_s"] == 30 and r["subagent_runs"] == 0, r
PY

# T3 Code drives its sessions through the TypeScript SDK; a person is still typing.
printf '%s\n' '{"type":"user","sessionId":"t3","cwd":"/x","entrypoint":"sdk-ts","timestamp":"2026-10-08T09:00:00.000Z","message":{"role":"user","content":"hi"}}' >"$tmp/t3.jsonl"
run 0 row "$tmp/t3.jsonl"
grep -q '"population": "interactive"' "$out" || fail "an sdk-ts session should count as interactive" "$(cat "$out")"

# A credential prefix inside an ordinary word is not a credential.
python3 - "$fx" "$tmp/word.jsonl" <<'PY'
import json, sys
fx, path = sys.argv[1:]
rec = lambda t, **kw: {"sessionId": "w", "cwd": fx + "/projects/acme/task-runner-service-api", "entrypoint": "cli",
                       "timestamp": f"2026-10-08T{t}.000Z", **kw}
skills = ["desk-organizer-skill-pack", "team/sk-" + "a" * 20]
open(path, "w").write("".join(json.dumps(r) + "\n" for r in [
    rec("09:00:00", type="assistant", message={"id": "w1", "model": "claude-opus-5-5", "usage": {}, "content": [
        {"type": "tool_use", "id": f"t{i}", "name": "Skill", "input": {"skill": s}} for i, s in enumerate(skills)]})]))
PY
run 0 row "$tmp/word.jsonl"
python3 - "$out" <<'PY' || fail "credential matching is not anchored to a token boundary" "$(cat "$out")"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["repo"] == "acme/task-runner-service-api", r["repo"]
assert r["skills"] == {"desk-organizer-skill-pack": 1, "_redacted": 1}, r["skills"]
PY

for f in -c/cccc-3 -d/dddd-4; do
    run 0 row "$P/$f.jsonl"
    [ "$(cat "$out")" = "null" ] || fail "a transcript with no timestamped record should give no row ($f)" "$(cat "$out")"
done

run 0 row "$P/-e/eeee-5.jsonl"
python3 - "$out" <<'PY' || fail "null usage or an unpriced model is mishandled" "$(cat "$out")"
import json, sys
r = json.load(open(sys.argv[1]))
assert r["models"]["main"]["claude-opus-5-5"] == {"calls": 1, "input": 0, "output": 0, "cache_read": 0,
    "cache_write_5m": 0, "cache_write_1h": 0, "cost_usd": 0.0}, r["models"]
m = r["models"]["main"]["mystery-model-1"]
assert m["output"] == 5 and m["cost_usd"] is None, m
assert r["unpriced_models"] == ["mystery-model-1"] and r["cost_usd"] == 0.0, r
assert r["cache_read_share"] is None, r["cache_read_share"]
PY

# Prices that cannot be read are an error, never a zero cost.
cp "$tmp/config/pricing.json" "$tmp/pricing.bak"
echo '{not json' >"$tmp/config/pricing.json"
run 2 row "$P/-b/bbbb-2.jsonl"
grep -q "pricing.json" "$out" || fail "a broken pricing.json is not named in the error" "$(cat "$out")"
cp "$tmp/pricing.bak" "$tmp/config/pricing.json"

# ── Collector and store ──
store="$AGENT_METRICS_STORE"
sg() { git -C "$store" "$@"; }
field() { sed -n "s/^$1: //p" "$out"; }
want() { [ "$(field "$1")" = "$2" ] || fail "collect reported $1=$(field "$1"), want $2 ($3)" "$(cat "$out" "$err")"; }
month="$store/sessions/2026-10.jsonl"

run 2 collect
grep -q "agent-metrics init" "$out" || fail "collect without a store does not point at init" "$(cat "$out")"

run 0 init
[ -f "$store/README.md" ] || fail "init did not write the store README"
[ "$(sg rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "init did not push the first commit"
run 0 init

run 0 collect --since 30
want sessions_written 3 "first run"
want files_skipped 2 "empty and timestamp-less transcripts"
want pushed true "first run"
[ "$(wc -l <"$month")" = 3 ] || fail "expected three rows in the month file" "$(cat "$month")"
python3 - "$month" <<'PY' || fail "rows are not sorted by start time with sorted keys"
import json, sys
lines = open(sys.argv[1]).read().splitlines()
rows = [json.loads(l) for l in lines]
assert [r["session_id"] for r in rows] == ["aaaa-1", "bbbb-2", "eeee-5"], [r["session_id"] for r in rows]
assert all(l == json.dumps(r, sort_keys=True, separators=(",", ":")) for l, r in zip(lines, rows))
PY
[ "$(sg rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "collect did not push"
[ -z "$(sg status --porcelain)" ] || fail "collect left the store dirty" "$(sg status --porcelain)"
if grep -rE "ghp_|purple|secret tool output" "$store" --exclude-dir=.git; then fail "transcript text leaked into the store"; fi

commits() { sg rev-list --count HEAD; }
before="$(commits)"
run 0 collect --since 30
want sessions_written 0 "nothing changed"
want sessions_unchanged 3 "nothing changed"
[ "$(commits)" = "$before" ] || fail "an unchanged collect made a commit"

# One changed transcript is a one-line diff.
append() {
    python3 - "$@" <<'PY'
import json, sys
path, sid, t, mid = sys.argv[1:5]
rec = {"type": "assistant", "sessionId": sid, "cwd": "/x", "entrypoint": "cli", "timestamp": f"2026-10-08T{t}.000Z",
       "message": {"id": mid, "model": "claude-haiku-4-5", "usage": {"input_tokens": 7, "output_tokens": 7}, "content": []}}
if len(sys.argv) > 5:
    rec["isSidechain"] = True
open(path, "a").write(json.dumps(rec) + "\n")
PY
}
append "$P/-b/bbbb-2.jsonl" bbbb-2 11:01:00 n2
run 0 collect --since 30
want sessions_written 1 "one transcript grew"
[ "$(sg show --numstat --format= HEAD)" = "1	1	sessions/2026-10.jsonl" ] || fail "a one-session change is not a one-line diff" "$(sg show --numstat --format= HEAD)"

# A subagent that finishes after its parent's last write still reaches the row.
append "$P/-a/aaaa-1/subagents/agent-x1.jsonl" aaaa-1 10:00:16 m4 sub
touch -d "2026-01-01" "$P/-a/aaaa-1.jsonl"
run 0 collect --since 1
want sessions_written 1 "only the subagent file changed"
grep '"aaaa-1"' "$month" | grep -q '"claude-haiku-4-5":{"cache_read":0,"cache_write_1h":0,"cache_write_5m":0,"calls":1' \
    || fail "late subagent usage did not reach the parent's row" "$(grep '"aaaa-1"' "$month")"

# A session outside the window keeps its row, and so does one whose transcript is gone.
append "$P/-b/bbbb-2.jsonl" bbbb-2 11:02:00 n3
touch -d "2026-09-01" "$P/-b/bbbb-2.jsonl"
rm -rf "$P/-e"
row_b="$(grep '"bbbb-2"' "$month")"
run 0 collect --since 1
want sessions_written 0 "nothing inside the window"
[ "$(grep '"bbbb-2"' "$month")" = "$row_b" ] || fail "a session outside --since was rewritten"
grep -q '"eeee-5"' "$month" || fail "a row was dropped when its transcript was deleted"
touch "$P/-b/bbbb-2.jsonl"

# --dry-run reports and writes nothing.
head_before="$(sg rev-parse HEAD)"
run 0 collect --since 1 --dry-run
want sessions_written 1 "dry run still counts"
want dry_run true "dry run"
[ "$(sg rev-parse HEAD)" = "$head_before" ] && [ -z "$(sg status --porcelain)" ] || fail "--dry-run changed the store"

# A rejected push keeps the commit and fails loudly; the next run delivers it.
printf '#!/bin/sh\nexit 1\n' >"$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
run 1 collect --since 1
want committed true "push rejected"
want pushed false "push rejected"
[ "$(sg rev-parse HEAD)" != "$(git -C "$remote" rev-parse main)" ] || fail "the rejecting remote accepted the push"
rm "$remote/hooks/pre-receive"
run 0 collect --since 1
want pushed true "retry after a rejected push"
[ "$(sg rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "the kept commit was not pushed on the next run"

# A store somebody else touched is left alone.
echo stray >"$store/stray.txt"
before="$(commits)"
run 1 collect --since 30
grep -q "stray.txt" "$out" || fail "a dirty store is not named in the error" "$(cat "$out")"
[ "$(commits)" = "$before" ] && [ "$(cat "$store/stray.txt")" = stray ] || fail "collect committed or removed a stray file"
rm "$store/stray.txt"

git clone -q "$remote" "$tmp/other"
git -C "$tmp/other" commit -q --allow-empty -m "elsewhere"
git -C "$tmp/other" push -q origin main
sg commit -q --allow-empty -m "local only"
run 1 collect --since 30
grep -qi "pull" "$out" || fail "a diverged store does not fail on the pull" "$(cat "$out")"
sg reset -q --hard origin/main
run 0 collect --since 30

# A second run waits for the first instead of racing it.
mkdir -p "$AGENT_METRICS_STATE"
flock "$AGENT_METRICS_STATE/collect.lock" sleep 3 &
sleep 0.5
AGENT_METRICS_LOCK_WAIT=1 run 1 collect --since 30
grep -q "another" "$out" || fail "a held lock is not reported" "$(cat "$out")"
wait

# ── Quota roll-up ──
qlog="$AGENT_METRICS_STATE/quota.jsonl"
reading() { printf '{"at":%s,"five_hour_pct":%s,"five_hour_resets_at":1,"seven_day_pct":%s,"seven_day_resets_at":%s}\n' "$(date -u -d "$1" +%s)" "$2" "$3" "$(date -u -d "2026-10-12T00:00:00Z" +%s)"; }
{
    reading "2026-08-30T08:10:00Z" 5 20
    reading "2026-10-09T09:05:00Z" 10 40
    reading "2026-10-09T09:25:00Z" 30 45
    echo "not a reading"
    reading "2026-10-09T09:45:00Z" 20 42
    reading "2026-10-09T10:15:00Z" 25 50
    reading "2026-10-09T12:00:00Z" 35 55
} >"$qlog"
run 0 collect --since 1
want quota_hours_added 3 "two finished hours this month and one old one"
[ "$(wc -l <"$store/quota/2026-10.jsonl")" = 2 ] || fail "the hour still in progress was rolled up, or a finished one was not" "$(cat "$store/quota/2026-10.jsonl")"
grep -q '"five_hour_pct":30,.*"hour":"2026-10-09T09:00:00Z","readings":3,.*"seven_day_pct":45,' "$store/quota/2026-10.jsonl" \
    || fail "an hour does not keep its highest reading per window" "$(cat "$store/quota/2026-10.jsonl")"
[ -f "$store/quota/2026-08.jsonl" ] || fail "an old reading was dropped without being rolled up"
if grep -q "$(date -u -d "2026-08-30T08:10:00Z" +%s)" "$qlog"; then fail "a reading older than 35 days stayed in the local log"; fi
grep -q "$(date -u -d "2026-10-09T12:00:00Z" +%s)" "$qlog" || fail "a recent reading was pruned from the local log"
[ "$(sg rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "the quota roll-up was not pushed"
run 0 collect --since 1
want quota_hours_added 0 "re-run"
run 0
grep -q "seven_day_pct: 55" "$out" || fail "the home view does not show the latest weekly quota" "$(cat "$out")"

# ── Budget ──
# $1,000 of sessions in the trailing 30 days: the plan is $10 and the hard stop $50.
bstore="$tmp/bstore"
bstate="$tmp/bstate"
mkbstore() {
    rm -rf "$1"
    mkdir -p "$1/sessions" "$1/ledger"
    git init -q -b main "$1"
    echo '{"session_id":"s1","started_at":"2026-10-01T00:00:00Z","cost_usd":600}' >"$1/sessions/2026-10.jsonl"
    {
        echo '{"session_id":"s2","started_at":"2026-09-20T00:00:00Z","cost_usd":400}'
        echo '{"session_id":"s3","started_at":"2026-09-01T00:00:00Z","cost_usd":5000}'
    } >"$1/sessions/2026-09.jsonl"
    echo '{"at":"2026-09-15T00:00:00Z","run":"weekly","usd":1000,"critical":false}' >"$1/ledger/2026-09.jsonl"
}
brun() {
    local want="$1"
    shift
    AGENT_METRICS_STORE="$bstore" AGENT_METRICS_STATE="$bstate" run "$want" budget "$@"
}
state() { [ "$(field state)" = "$1" ] || fail "budget state is $(field state), want $1 ($2)" "$(cat "$out")"; }
mkbstore "$bstore"
mkdir -p "$bstate"

brun 0
state ok "nothing spent"
[ "$(field base_usd)" = 1000.0 ] && [ "$(field plan_usd)" = 10.0 ] && [ "$(field hard_usd)" = 50.0 ] && [ "$(field spent_usd)" = 0.0 ] \
    || fail "budget numbers are wrong: last month's ledger or an old session was counted" "$(cat "$out")"
grep -q "^quota: null" "$out" || fail "a missing quota reading is not reported as unknown" "$(cat "$out")"
brun 0 check --need 5
state ok "5 of a 10 plan"
[ "$(field allowed)" = true ] || fail "an allowed spend is not marked allowed" "$(cat "$out")"

brun 0 record --usd 8 --run weekly
brun 3 check --need 5
state critical-only "13 against a 10 plan"
[ "$(field allowed)" = false ] || fail "a denied spend is marked allowed" "$(cat "$out")"
brun 0 check --need 5 --critical
state critical-only "critical spend inside the hard stop"
brun 0 record --usd 40 --run monthly --critical
brun 3 check --need 5 --critical
state stopped "53 against a 50 hard stop"
brun 0
[ "$(field spent_usd)" = 48.0 ] || fail "recorded spend does not add up" "$(cat "$out")"
grep -q '"critical":true' "$bstore/ledger/2026-10.jsonl" || fail "record did not keep the critical flag"

brun 2 record --usd -1 --run weekly
brun 2 record --usd abc --run weekly
brun 2 record --usd 1
brun 2 check

# The weekly plan quota holds model work while it is nearly spent.
mkbstore "$bstore"
soon="$(date -u -d "2026-10-10T00:00:00Z" +%s)"
past="$(date -u -d "2026-10-09T00:00:00Z" +%s)"
at="$(date -u -d "2026-10-09T11:00:00Z" +%s)"
echo "{\"at\":$at,\"seven_day_pct\":90,\"seven_day_resets_at\":$soon}" >"$bstate/quota.jsonl"
brun 3 check --need 1
state quota-hold "weekly quota at 90"
echo "{\"at\":$at,\"seven_day_pct\":90,\"seven_day_resets_at\":$past}" >"$bstate/quota.jsonl"
brun 0 check --need 1
state ok "the window already reset"
echo "{\"at\":$at,\"seven_day_pct\":84,\"seven_day_resets_at\":$soon}" >"$bstate/quota.jsonl"
brun 0 check --need 1
state ok "below the cut-off"
rm "$bstate/quota.jsonl"

# No usage data means no model spend.
rm -rf "$bstore/sessions"
brun 3 check --need 1
state no-baseline "empty store"

# Unreadable inputs are errors, never an allowance.
mkbstore "$bstore"
echo "garbage" >>"$bstore/ledger/2026-10.jsonl"
brun 2 check --need 1
grep -q "ledger/2026-10.jsonl" "$out" || fail "a broken ledger line is not named" "$(cat "$out")"
mkbstore "$bstore"
cp "$tmp/config/budget.json" "$tmp/budget.bak"
echo '{"plan_pct": "lots", "hard_pct": 5, "weekly_quota_cutoff_pct": 85}' >"$tmp/config/budget.json"
brun 2 check --need 1
grep -q "budget.json" "$out" || fail "a malformed budget.json is not named" "$(cat "$out")"
cp "$tmp/budget.bak" "$tmp/config/budget.json"

# A recorded spend is the collector's own change, so it commits it.
run 0 budget record --usd 2.5 --run weekly
run 0 collect --since 1
want committed true "ledger entry"
[ -z "$(sg status --porcelain)" ] && sg show --stat --format= HEAD | grep -q "ledger/2026-10.jsonl" || fail "collect did not commit the ledger"

# ── Hostile and malformed input ──
# Records whose fields have the wrong type must not stop the run or the row.
python3 - "$P" <<'PY'
import json, os, sys
d = os.path.join(sys.argv[1], "-odd"); os.makedirs(d, exist_ok=True)
def rec(t, **kw):
    return {"sessionId": "odd-6", "cwd": "/x", "entrypoint": "cli", "timestamp": f"2026-10-08T{t}.000Z", **kw}
lines = [json.dumps(r) for r in [
    rec("13:00:00", type="user", message={"role": "user", "content": [{"type": "text", "text": 42}]}),
    rec("13:00:01", type="assistant", message={"id": ["not", "a", "string"], "model": "claude-opus-5-5",
        "usage": {"input_tokens": 5}, "content": [{"type": "tool_use", "id": {"a": 1}, "name": "Bash", "input": {"command": "git push"}}]}),
    rec("13:00:02", type="user", message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": {"a": 1}}]}),
    rec("13:00:03", type="assistant", message={"id": "o1", "model": "claude-opus-5-5",
        "usage": {"input_tokens": "many", "output_tokens": 3.5, "cache_read_input_tokens": -4}, "content": "text"}),
]]
# json.loads accepts these; they must never reach a cost.
lines.append('{"sessionId":"odd-6","cwd":"/x","entrypoint":"cli","timestamp":"2026-10-08T13:00:04.000Z","type":"assistant",'
             '"message":{"id":"o2","model":"claude-opus-5-5","usage":{"input_tokens":NaN,"output_tokens":1e999,"cache_read_input_tokens":Infinity},"content":[]}}')
lines += ["[1, 2, 3]", '"just a string"', "null"]
open(os.path.join(d, "odd-6.jsonl"), "w").write("\n".join(lines) + "\n")
PY
run 0 row "$P/-odd/odd-6.jsonl"
python3 - "$out" <<'PY' || fail "odd field types broke the row or reached the cost" "$(cat "$out")"
import json, math, sys
r = json.load(open(sys.argv[1]))
m = r["models"]["main"]["claude-opus-5-5"]
assert m == {"calls": 2, "input": 0, "output": 0, "cache_read": 0, "cache_write_5m": 0, "cache_write_1h": 0,
             "cost_usd": 0.0}, m
assert r["cost_usd"] == 0.0 and math.isfinite(r["cost_usd"]), r["cost_usd"]
assert r["prompts"] == 1 and r["wall_s"] == 4, r
PY
run 0 collect --since 1
want sessions_written 1 "the odd transcript still gets a row"

# A cost in the store that is not a finite amount is an error, never a budget.
for bad in NaN Infinity -5 '"lots"'; do
    mkbstore "$bstore"
    echo "{\"session_id\":\"s9\",\"started_at\":\"2026-10-02T00:00:00Z\",\"cost_usd\":$bad}" >>"$bstore/sessions/2026-10.jsonl"
    brun 2 check --need 1000000
    grep -q "sessions/2026-10.jsonl" "$out" || fail "a bad stored cost ($bad) is not named" "$(cat "$out")"
done
mkbstore "$bstore"
echo "not a row" >>"$bstore/sessions/2026-10.jsonl"
brun 2 check --need 1
grep -q "sessions/2026-10.jsonl" "$out" || fail "a corrupt session line is not named" "$(cat "$out")"

# The weekly hold survives a newer reading without a weekly value, and a reset time it cannot use.
mkbstore "$bstore"
later="$(date -u -d "2026-10-09T11:30:00Z" +%s)"
{
    echo "{\"at\":$at,\"seven_day_pct\":95,\"seven_day_resets_at\":$soon}"
    echo "{\"at\":$later,\"five_hour_pct\":10,\"five_hour_resets_at\":$soon}"
} >"$bstate/quota.jsonl"
brun 3 check --need 1
state quota-hold "a newer five-hour-only reading"
{
    echo "{\"at\":$at,\"seven_day_pct\":95,\"seven_day_resets_at\":$soon}"
    echo "{\"at\":$later,\"seven_day_pct\":\"95\",\"seven_day_resets_at\":$soon}"
} >"$bstate/quota.jsonl"
brun 3 check --need 1
state quota-hold "a newer reading with a non-numeric percentage"
echo "{\"at\":$at,\"seven_day_pct\":99,\"seven_day_resets_at\":0}" >"$bstate/quota.jsonl"
brun 3 check --need 1
state quota-hold "a reset time that cannot be used"
old="$(date -u -d "2026-09-25T00:00:00Z" +%s)"
echo "{\"at\":$old,\"seven_day_pct\":99,\"seven_day_resets_at\":0}" >"$bstate/quota.jsonl"
brun 0 check --need 1
state ok "a reading older than the weekly window"
rm "$bstate/quota.jsonl"

# A run that died after writing rows must not block the next one.
echo '{"at":Infinity,"seven_day_pct":1}' >>"$qlog"
echo '{"session_id":"left-behind","started_at":"2026-10-07T00:00:00Z","cost_usd":0}' >>"$month"
: >"$store/sessions/2026-10.tmp"
run 0 collect --since 1
want committed true "leftovers from a dead run"
[ -z "$(sg status --porcelain)" ] || fail "leftovers from a dead run were not cleaned up" "$(sg status --porcelain)"
[ ! -e "$store/sessions/2026-10.tmp" ] || fail "a stale temp file survived"
if sg ls-files | grep -q '\.tmp$'; then fail "a temp file was committed"; fi
echo stray >"$store/stray.txt"
run 1 collect --since 1
rm "$store/stray.txt"

# ── Library use: sibling tools load this file for the store helpers ──
# The sentinel proves the script ran to its end: an early exit 0 would pass otherwise.
lib_out="$(python3 - "$metrics" "$store" <<'PY'
import subprocess, sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
path, store = sys.argv[1], Path(sys.argv[2])
sys.argv = ["sibling", "--version"]          # a sibling's own flag must not trip this file's fast path
am = SourceFileLoader("agent_metrics", path).load_module()
assert set(("sessions", "quota", "ledger", "reports", "labels", "site", "findings")) <= set(am.OWN_DIRS), am.OWN_DIRS
(store / "reports").mkdir(exist_ok=True)
(store / "reports" / "probe.md").write_text("probe\n")
with am.Lock():
    out = am.publish("report: probe")
assert out == {"committed": True, "pushed": True}, out
head = subprocess.run(["git", "-C", str(store), "log", "-1", "--format=%s"], capture_output=True, text=True).stdout.strip()
assert head == "report: probe", head
with am.Lock():
    assert am.publish("report: nothing") == {"committed": False, "pushed": "nothing to push"}
print("LIB-OK")
PY
)" || fail "publish does not commit and push a sibling tool's files" "$lib_out"
[ "$lib_out" = "LIB-OK" ] || fail "loading agent-metrics as a library ran its command line" "$lib_out"
[ "$(sg rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "publish did not push"

# publish(dirs=...) leaves other tools' in-progress files alone.
dirs_out="$(python3 - "$metrics" "$store" <<'PY'
import subprocess, sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
path, store = sys.argv[1], Path(sys.argv[2])
sys.argv = ["sibling"]
am = SourceFileLoader("agent_metrics", path).load_module()
(store / "reports").mkdir(exist_ok=True)
(store / "reports" / "inflight.json").write_text("{}\n")
(store / "site").mkdir(exist_ok=True)
(store / "site" / "index.html").write_text("<p>page</p>\n")
with am.Lock():
    out = am.publish("site: only", dirs=("site",))
assert out == {"committed": True, "pushed": True}, out
files = subprocess.run(["git", "-C", str(store), "show", "--name-only", "--format=", "HEAD"], capture_output=True, text=True).stdout.split()
assert files == ["site/index.html"], files
status = subprocess.run(["git", "-C", str(store), "status", "--porcelain"], capture_output=True, text=True).stdout
assert "reports/inflight.json" in status, status
with am.Lock():
    assert am.publish("site: nothing more", dirs=("site",)) == {"committed": False, "pushed": "nothing to push"}
with am.Lock():
    assert am.publish("report: rest")["committed"] is True

def git(*args):
    return subprocess.run(["git", "-C", str(store), *args], capture_output=True, text=True).stdout

# A file another tool already staged must not ride along in a scoped commit.
(store / "reports" / "staged.json").write_text("{}\n")
git("add", "reports/staged.json")
(store / "site" / "index.html").write_text("<p>page 2</p>\n")
with am.Lock():
    assert am.publish("site: scoped", dirs=("site",))["committed"] is True
assert git("show", "--name-only", "--format=", "HEAD").split() == ["site/index.html"], git("show", "--name-only", "--format=", "HEAD")
assert "reports/staged.json" in git("status", "--porcelain")
with am.Lock():
    am.publish("report: staged")

# Removing a whole owned directory is a change too.
import shutil
shutil.rmtree(store / "site")
with am.Lock():
    assert am.publish("site: removed", dirs=("site",))["committed"] is True
assert git("ls-files", "site") == "", git("ls-files", "site")
with am.Lock():
    assert am.publish("site: still gone", dirs=("site",))["committed"] is False
print("DIRS-OK")
PY
)" || fail "publish(dirs=...) staged more than it was given" "$dirs_out"
[ "$dirs_out" = "DIRS-OK" ] || fail "publish(dirs=...) test did not finish" "$dirs_out"

# ── Units: one daily collect ──
svc="$units/agent-metrics-collect.service"
timer="$units/agent-metrics-collect.timer"
grep -qx 'ExecStart=%h/.local/bin/agent-metrics collect' "$svc" || fail "service ExecStart"
grep -qx 'NoNewPrivileges=yes' "$svc" && grep -qx 'PrivateTmp=yes' "$svc" || fail "service hardening missing"
grep -q '^TimeoutStartSec=' "$svc" || fail "service needs a hard timeout"
grep -q '^Environment=PATH=' "$svc" || fail "service needs a PATH: a user manager starts with a bare one"
grep -qxF "OnCalendar=*-*-* 06:30:00" "$timer" || fail "timer calendar"
grep -qx "Unit=agent-metrics-collect.service" "$timer" || fail "timer target"
grep -qx "Persistent=true" "$timer" || fail "timer must catch up after downtime"
grep -qx "WantedBy=timers.target" "$timer" || fail "timer install target"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "*-*-* 06:30:00" >/dev/null || fail "calendar rejected by systemd"
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
        STUB_LINGER="$2" AGENT_METRICS_STORE="$trig/home/no-store" bash "$trigger" 2>&1)"
}
run_trigger /elsewhere no
grep -q "skipping enable" <<<"$trig_out" && [ ! -s "$trig/calls" ] || fail "trigger must skip a scratch-dest apply" "$trig_out"
run_trigger "$trig/home" no
grep -qx -- "--user daemon-reload" "$trig/calls" || fail "trigger never reloads systemd"
grep -qx -- "--user enable --now agent-metrics-collect.timer" "$trig/calls" || fail "trigger does not enable the timer" "$(cat "$trig/calls")"
grep -q "start" "$trig/calls" && fail "trigger must not start a collect"
grep -q "linger is off" <<<"$trig_out" || fail "trigger should warn when linger is off"
grep -q "agent-metrics init" <<<"$trig_out" || fail "trigger should say the store still needs cloning" "$trig_out"
run_trigger "$trig/home" yes
grep -q "linger is off" <<<"$trig_out" && fail "no linger warning expected when linger is on"

echo "test_agent_metrics_script: OK"
