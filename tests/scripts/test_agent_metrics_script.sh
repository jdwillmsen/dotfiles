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

# ── Config that cannot be read is an error, never a default ──
cp "$tmp/config/pricing.json" "$tmp/pricing.bak"
echo '{not json' >"$tmp/config/pricing.json"
run 2 budget
grep -q "pricing.json" "$out" || fail "a broken pricing.json is not named in the error" "$(cat "$out")"
cp "$tmp/pricing.bak" "$tmp/config/pricing.json"

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
eq("tools", {"Agent": 1, "Bash": 2, "Skill": 1, "mcp__jira__search": 1})
eq("mcp", {"jira": 1}); eq("subagent_types", {"Explore": 1}); eq("subagent_runs", 1)
(skill, n), = r["skills"].items()
assert n == 1 and len(skill) == 64 and re.fullmatch(r"[A-Za-z0-9:_.@/-]+", skill), skill
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

echo "test_agent_metrics_script: OK"
