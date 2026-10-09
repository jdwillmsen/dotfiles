#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-propose reads the store, calls gh and claude, commits to a repo and
# pushes, so everything it touches is redirected here: a fixture store and a
# fixture target repo, each a clone of a local bare remote, a stub gh that
# records its arguments and plays back fixtures, a stub claude that performs
# scripted edits (hostile ones included), and a fixed clock.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
propose="$here/home/dot_local/bin/executable_agent-propose"
checker="$here/scripts/check-agent-diff"
cfgsrc="$here/home/dot_config/agent-metrics"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$propose" ] || fail "agent-propose missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$propose" || fail "agent-propose does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
fx="$tmp/home"
remote="$tmp/store-remote.git"
store="$tmp/store"
target="$tmp/target"
target_remote="$tmp/target-remote.git"
stub="$tmp/stub"
sandbox="$tmp/state/propose/worktrees"
mkdir -p "$fx" "$tmp/config" "$tmp/bin" "$tmp/state"

export HOME="$fx"
export STUB="$stub"
export AGENT_METRICS_STORE="$store"
export AGENT_METRICS_STATE="$tmp/state"
export AGENT_METRICS_CONFIG="$tmp/config"
export AGENT_METRICS_NOW="2026-10-09T12:00:00+00:00"
export AGENT_METRICS_LOCK_WAIT=5
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export PATH="$tmp/bin:$PATH"

# ── Stubs ──
cat >"$tmp/bin/claude" <<'PY'
#!/usr/bin/env python3
import json, os, re, subprocess, sys, time
stub = os.environ["STUB"]
argv = sys.argv[1:]
prompt = sys.stdin.read()
n = len(os.listdir(f"{stub}/calls"))
json.dump({"argv": argv, "cwd": os.getcwd(), "prompt": prompt, "env": sorted(os.environ)},
          open(f"{stub}/calls/{n:02d}.json", "w"))
ids = re.findall(r"^finding: (\S+)$", prompt, re.M)
cost = float(open(f"{stub}/cost").read()) if os.path.exists(f"{stub}/cost") else 0.11
if "--json-schema" in argv:
    out = {"total_cost_usd": cost, "is_error": False, "result": "",
           "structured_output": {"reviews": [{"finding_id": i, "verdict": "approve", "reason": "ok"} for i in ids]}}
    if os.path.exists(f"{stub}/review.json"):
        out = json.load(open(f"{stub}/review.json"))
else:
    slug = re.sub(r"[^A-Za-z0-9.-]", "_", ids[0])
    mode = open(f"{stub}/mode/{slug}").read().strip() if os.path.exists(f"{stub}/mode/{slug}") else ""
    if mode == "timeout":
        time.sleep(30)
    script = f"{stub}/edit/{slug}.sh"
    if os.path.exists(script):
        subprocess.run(["bash", script], check=True)
    out = {"total_cost_usd": cost, "is_error": False,
           "result": "INJECTED-MODEL-TEXT feat: pwned\n\nCo-Authored-By: evil <evil@example.invalid>"}
    if mode == "nocost":
        del out["total_cost_usd"]
    if mode == "exit1":
        print(json.dumps(out))
        sys.exit(1)
print(json.dumps(out))
PY
cat >"$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
stub = os.environ["STUB"]
a = sys.argv[1:]
with open(f"{stub}/gh.log", "a") as fh:
    fh.write(json.dumps(a) + "\n")
fx = f"{stub}/gh"
def play(name, default):
    if os.path.exists(f"{fx}/{name}.fail"):
        sys.stderr.write(open(f"{fx}/{name}.fail").read() or "HTTP 500: boom\n")
        sys.exit(1)
    p = f"{fx}/{name}.json"
    sys.stdout.write(open(p).read() if os.path.exists(p) else default)
    sys.exit(0)
def arg(flag):
    return a[a.index(flag) + 1]
if a[:2] == ["pr", "list"]:
    play("pr-list-head" if "--head" in a else "pr-list-open", "[]")
if a[:2] == ["pr", "view"]:
    play(f"pr-view-{a[2]}", "")
if a[0] == "api":
    if a[1].endswith("/protection"):
        if not os.path.exists(f"{fx}/protection.json") and not os.path.exists(f"{fx}/protection.fail"):
            sys.stderr.write("gh: Branch not protected (HTTP 404)\n")
            sys.exit(1)
        play("protection", "")
    play("rules", "[]")
if a[:2] == ["label", "create"]:
    play("label", "")
if a[:2] == ["pr", "create"]:
    if os.path.exists(f"{fx}/pr-create.fail"):
        sys.stderr.write("HTTP 422: nope\n")
        sys.exit(1)
    open(f"{stub}/pr-body", "w").write(open(arg("--body-file")).read())
    print("https://github.com/acme/dotfiles/pull/41")
    sys.exit(0)
if a[:2] == ["pr", "comment"]:
    if os.path.exists(f"{fx}/pr-comment.fail"):
        sys.exit(1)
    open(f"{stub}/pr-comment", "w").write(open(arg("--body-file")).read())
    sys.exit(0)
if a[:2] == ["pr", "edit"]:
    sys.exit(0)
sys.stderr.write("stub gh: unexpected call\n")
sys.exit(1)
PY
chmod +x "$tmp/bin/claude" "$tmp/bin/gh"

# ── Config: the deployed defaults, pointed at the fixture repo ──
cp "$cfgsrc"/*.json "$tmp/config/"
python3 - "$tmp/config/config.json" "$remote" <<'PY'
import json, sys
json.dump({"store_remote": sys.argv[2]}, open(sys.argv[1], "w"))
PY
# cfg key=json ...: rewrite keys of the test's propose.json from the deployed one.
cfg() {
    python3 - "$cfgsrc/propose.json" "$tmp/config/propose.json" "$target" "$@" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c.update(repo_path=sys.argv[3], repo_slug="acme/dotfiles", call_timeout_s=3, test_timeout_s=30)
for kv in sys.argv[4:]:
    k, v = kv.split("=", 1)
    c[k] = json.loads(v)
json.dump(c, open(sys.argv[2], "w"), indent=1)
PY
}
cfg

out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$propose" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-propose $* exited $got, want $want" "$(cat "$out" "$err")"
}
field() { sed -n "s/^ *$1: //p" "$out" | head -1; }
# row <id>: the rest of that finding's table row.
row() { sed -n "s|^  \"$1\",||p" "$out" | head -1; }
gate() { sed -n "s|^  $1,||p" "$out" | head -1; }
has() { grep -qF -- "$1" "$out" || fail "${2:-output lacks $1}" "$(cat "$out" "$err")"; }
gs() { git -C "$store" "$@"; }
gt() { git -C "$target" "$@"; }
calls() { find "$stub/calls" -name '*.json' | wc -l | tr -d ' '; }
ghlog() { cat "$stub/gh.log" 2>/dev/null || true; }

# The store does not exist yet.
mkdir -p "$stub/calls"
run 0
has "store not cloned" "home view does not say the store is missing"
run 2 run --window weekly --dry-run
has "agent-metrics init" "a missing store does not name agent-metrics init"

# ── Fixtures ──
cat >"$tmp/store-fixture.py" <<'PY'
import json, os, sys
store = sys.argv[1]

def row(sid, started, pop, repo=None, cost=1.0, **kw):
    r = {"schema": 1, "session_id": sid, "started_at": started, "ended_at": started, "population": pop,
         "pipeline": None, "repo": repo, "cost_usd": cost, "unpriced_models": [], "models": {"main": {}, "subagent": {}},
         "active_s": 0, "idle_s": 0, "wait_human_s": 0, "interrupts": 0, "tool_errors": 0, "denials": 0,
         "rate_limits": 0, "api_errors": 0, "compactions": 0, "commits": 0, "pushes": 0, "prs_created": 0,
         "pr_links": [], "skills": {}, "tools": {}, "mcp": {}, "subagent_types": {}, "cache_read_share": None}
    r.update(kw)
    return r

def write(rel, objs):
    p = os.path.join(store, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        for o in objs:
            f.write(json.dumps(o, sort_keys=True) + "\n")

# Budget baseline: 1012 over the trailing 30 days, so the 1% plan is $10.12.
write("sessions/2026-09.jsonl", [
    row("b0", "2026-09-12T00:00:00Z", "scripted", cost=1000.0),
    # Weekly window 09-28..10-05: six interactive sessions, four with no repo.
    row("w1", "2026-09-28T00:00:00Z", "interactive", "acme/app"),
    row("w2", "2026-09-29T10:00:00Z", "interactive", "acme/app"),
    row("w3", "2026-09-29T11:00:00Z", "interactive", skills={"busy:run": 1}),
    row("w4", "2026-09-30T10:00:00Z", "interactive"),
    row("s1", "2026-09-30T11:00:00Z", "scripted"),
])
write("sessions/2026-10.jsonl", [
    row("w5", "2026-10-01T10:00:00Z", "interactive"),
    row("w6", "2026-10-04T23:59:59Z", "interactive"),
    # 10-05 belongs to the next week.
    row("x1", "2026-10-05T00:00:00Z", "interactive"),
    # The daily window 10-08: five interactive sessions, none in a repo.
    *[row(f"d{i}", f"2026-10-08T1{i}:00:00Z", "interactive") for i in range(5)],
])
hook = lambda plugin, b: {"plugin": plugin, "event": "SessionStart", "fires": 10, "bytes": b,
                          "bytes_per_fire": b // 10, "bytes_per_session": b // 10}
audit = {
    "source": "2026-10-04-weekly.json",
    # 1000 bytes in all.
    "hooks": [hook("superpowers", 540), hook("caveman", 300), hook("unmapped", 100), hook("busy", 40), hook("quiet", 20)],
    "disable_candidates": {"plugins": [
        {"plugin": "caveman", "provides": "_invalid", "hook_bytes": 300},
        {"plugin": "quiet", "provides": "hooks", "hook_bytes": 20},
        # Listed by the audit, but the store shows a busy:run skill call in the window.
        {"plugin": "busy", "provides": "skills", "hook_bytes": 40},
        {"plugin": "nohooks", "provides": "skills", "hook_bytes": 0},
        {"plugin": "_invalid", "provides": "hooks", "hook_bytes": 50},
    ], "skills": [], "mcp_servers": [], "agents": []},
    "instructions": {"files": [
        {"path": "~/.claude/CLAUDE.md", "lines": 250, "bytes": 9000, "flag": ""},
        {"path": "~/AGENTS.md", "lines": 200, "bytes": 3000, "flag": ""},
        {"path": "~/.claude/projects/x/memory/MEMORY.md", "lines": 10, "bytes": 30000, "flag": ""},
        {"path": "~/projects/acme/AGENTS.md", "lines": 201, "bytes": 100, "flag": ""},
        {"path": "_invalid", "lines": 900, "bytes": 100, "flag": ""},
    ], "combined": []},
}
pops = {"interactive": {"sessions": 6, "cost_usd": 6.0}, "scripted": {"sessions": 1, "cost_usd": 1.0}}
def report(label, window, start, end, peak, prev_peak, audit=None):
    return {"schema": 1, "window": window, "start": start, "end": end, "label_date": label,
            "current": {"populations": pops, "quota": {"peak_five_hour_pct": None, "peak_seven_day_pct": peak, "readings": 1}},
            "previous": {"start": "x", "end": start, "quota": {"peak_five_hour_pct": None, "peak_seven_day_pct": prev_peak, "readings": 1}},
            "flags": [], "audit": audit}
for r in [
    report("2026-09-27", "weekly", "2026-09-21", "2026-09-28", 86, 10),
    report("2026-10-04", "weekly", "2026-09-28", "2026-10-05", 88, 86, audit),
    report("2026-10-08", "daily", "2026-10-08", "2026-10-09", None, None),
    report("2026-09-30", "monthly", "2026-09-01", "2026-10-01", 88, 20, {**audit, "source": "2026-09-30-monthly.json"}),
]:
    p = os.path.join(store, "reports", f"{r['label_date']}-{r['window']}.json")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    json.dump(r, open(p, "w"))
PY

reset_store() {
    rm -rf "$store" "$remote" "$tmp/state"
    mkdir -p "$tmp/state"
    git init -q --bare -b main "$remote"
    git clone -q "$remote" "$store" 2>/dev/null
    python3 "$tmp/store-fixture.py" "$store"
    gs add -A
    gs commit -q -m "fixture"
    gs push -q -u origin HEAD
}

reset_target() {
    rm -rf "$target" "$target_remote"
    git init -q --bare -b main "$target_remote"
    git clone -q "$target_remote" "$target" 2>/dev/null
    (
        cd "$target"
        mkdir -p .github/workflows scripts tests/scripts home/private_dot_claude home/dot_config/agent-metrics
        echo "name: CI" >.github/workflows/ci.yml
        cp "$checker" scripts/check-agent-diff
        cp "$cfgsrc/propose.json" "$cfgsrc/budget.json" home/dot_config/agent-metrics/
        cat >home/private_dot_claude/modify_settings.json.json.tmpl <<'EOF'
#!/usr/bin/env bash
DEFAULTS='{
  "model": "opus",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude" } ] }
    ]
  }
}'
ENFORCED='{
  "enabledPlugins": {
    "remember@official": false
  }
}'
EOF
        seq -f "rule %g" 1 250 >home/private_dot_claude/CLAUDE.md
        printf '# Map\n\nstart claude anywhere you like\n\nend\n' >home/AGENTS.md
        # Fails once the quiet plugin is disabled, to exercise the test-failure drop.
        cat >tests/scripts/test_settings.sh <<'EOF'
#!/usr/bin/env bash
echo settings >>"$STUB/tests.log"
if [ -e "$STUB/tests-pass" ]; then exit 0; fi
! grep -q '"quiet@' home/private_dot_claude/modify_settings.json.json.tmpl
EOF
        cat >tests/scripts/test_other.sh <<'EOF'
#!/usr/bin/env bash
echo other >>"$STUB/tests.log"
EOF
        git add -A
        git commit -q -m "base"
        git push -q -u origin HEAD
    )
}

# Scripted edits the stub claude performs, one per finding.
reset_stub() {
    rm -rf "$stub"
    mkdir -p "$stub/calls" "$stub/edit" "$stub/mode" "$stub/gh"
    cat >"$stub/edit/unused-plugin_caveman.sh" <<'EOF'
sed -i 's/"remember@official": false/"remember@official": false,\n    "caveman@market": false/' home/private_dot_claude/modify_settings.json.json.tmpl
EOF
    cat >"$stub/edit/unused-plugin_quiet.sh" <<'EOF'
f=home/private_dot_claude/modify_settings.json.json.tmpl
last="$(grep -n '@.*": false$' "$f" | tail -1 | cut -d: -f1)"
sed -i "${last}s/\$/,\n    \"quiet@market\": false/" "$f"
EOF
    cat >"$stub/edit/oversize-instructions_.claude_CLAUDE.md.sh" <<'EOF'
sed -i '201,$d' home/private_dot_claude/CLAUDE.md
EOF
    cat >"$stub/edit/unattributed-sessions_interactive.sh" <<'EOF'
sed -i 's/start claude anywhere you like/start claude in a worktree only/' home/AGENTS.md
EOF
}

reset_all() {
    reset_store
    reset_target
    reset_stub
    cfg
}
reset_all

# ── CLI surface ──
run 0 --help
has "run" "--help does not list the run command"
has "verify" "--help does not list the verify command"
run 0 --version
run 0
has "store:" "home view does not report the store"
has "agent-propose run --window weekly --dry-run" "home view does not suggest a dry run"
run 2 run --window fortnightly --dry-run
has "error:" "a bad window does not print a structured error"
run 2 run --dry-run
run 2 frobnicate
run 2 run --window weekly --report /nonexistent
has "--dry-run" "--report outside a dry run is not explained"

# ── Config: unreadable or unsafe values are a setup error, never a default ──
cfg 'repo_slug="acme/dot files; rm -rf"'
run 2 run --window weekly --dry-run
has "repo_slug" "an unsafe slug is not named"
cfg 'base_branch="--upload-pack=evil"'
run 2 run --window weekly --dry-run
has "base_branch" "an option-shaped branch is not named"
cfg 'settings_source="../outside"'
run 2 run --window weekly --dry-run
has "settings_source" "a path leaving the repo is not named"
cfg 'caps_usd={"daily": 3, "weekly": "lots", "monthly": 10}'
run 2 run --window weekly --dry-run
has "caps_usd" "a non-numeric cap is not named"
cfg 'author_model={"id": "sonnet; curl evil", "name": "x"}'
run 2 run --window weekly --dry-run
has "author_model" "an unsafe model id is not named"
rm "$tmp/config/propose.json"
run 2 run --window weekly --dry-run
has "propose.json" "a missing propose.json is not named"
cfg
python3 - "$cfgsrc/propose.json" <<'PY' || fail "the deployed propose.json does not carry the documented caps"
import json, sys
c = json.load(open(sys.argv[1]))
assert c["caps_usd"] == {"daily": 3.0, "weekly": 5.0, "monthly": 10.0}, c["caps_usd"]
assert (c["review_usd"], c["max_findings"], c["rejection_memory_days"], c["strict_finders"]) == (3.0, 4, 90, []), c
assert c["repo_slug"] == "jdwillmsen/dotfiles" and c["base_branch"] == "main", c
assert c["protected_paths"], c
# The worst case of a full run fits its cap exactly.
assert c["max_findings"] * c["per_finding_usd"] + c["review_usd"] <= c["caps_usd"]["weekly"], c
PY

# ── Finders on the hand-computed fixture, by dry run ──
run 0 run --window weekly --dry-run
[ "$(field dry_run)" = true ] || fail "a dry run does not say so" "$(cat "$out")"
[ "$(field label_date)" = 2026-10-04 ] || fail "the newest weekly report was not used" "$(cat "$out")"
# caveman: 300 of 1000 injected bytes, never invoked.
[ "$(row unused-plugin:caveman)" = "true,30.0,hook_injected_bytes,300,1000,planned,null" ] || fail "caveman finding" "$(cat "$out")"
# quiet: 20 of 1000.
[ "$(row unused-plugin:quiet)" = "false,2.0,hook_injected_bytes,20,1000,planned,null" ] || fail "quiet finding" "$(cat "$out")"
# CLAUDE.md: 250 lines against 200, so 50 of 250 lines would go.
[ "$(row oversize-instructions:.claude/CLAUDE.md)" = "true,20.0,instruction_lines,250,200,planned,null" ] || fail "CLAUDE.md finding" "$(cat "$out")"
# Four of six interactive sessions without a repo: 66.67% against 50%.
[ "$(row unattributed-sessions:interactive)" = "true,16.67,interactive_unattributed_share,0.6667,0.5,planned,null" ] || fail "unattributed finding" "$(cat "$out")"
# busy was invoked, nohooks injects nothing, _invalid is no identifier, AGENTS.md sits exactly on the limit.
for absent in unused-plugin:busy unused-plugin:nohooks unused-plugin:_invalid oversize-instructions:AGENTS.md; do
    grep -qF "\"$absent\"" "$out" && fail "$absent should not be a finding" "$(cat "$out")"
done
# Files this repo does not own, and the quota default, are reported for a person.
# MEMORY.md: 30000 bytes against 25600. The other AGENTS.md: 201 lines against 200.
[ "$(row oversize-instructions:.claude/projects/x/memory/MEMORY.md)" = "true,14.67,instruction_bytes,30000,25600,needs_human,null" ] || fail "MEMORY.md finding" "$(cat "$out")"
[ "$(row oversize-instructions:projects/acme/AGENTS.md)" = "false,0.5,instruction_lines,201,200,needs_human,null" ] || fail "foreign AGENTS.md finding" "$(cat "$out")"
# Peak 88 this week and 86 the week before, cut-off 85.
[ "$(row weekly-quota-peak:weekly)" = "false,3.0,weekly_quota_peak_pct,88,85,needs_human,null" ] || fail "quota finding" "$(cat "$out")"
# Ranked by effect.
python3 - "$out" <<'PY' || fail "findings are not ranked by effect" "$(cat "$out")"
import re, sys
ids = re.findall(r'^  "([^"]+)",(?:true|false),[\d.]+,\w+,[\d.]+,[\d.]+,planned', open(sys.argv[1]).read(), re.M)
assert ids == ["unused-plugin:caveman", "oversize-instructions:.claude/CLAUDE.md", "unattributed-sessions:interactive",
               "unused-plugin:quiet"], ids
PY
# Gates and planned caps.
[ "$(gate store)" = "ok,present" ] || fail "store gate" "$(cat "$out")"
[ "$(gate open-pr)" = "ok,none open" ] || fail "open-pr gate" "$(cat "$out")"
gate budget | grep -q "^ok," || fail "budget gate" "$(cat "$out")"
[ "$(gate review-gate)" = "ok,no approving review required" ] || fail "review gate" "$(cat "$out")"
[ "$(field run_usd)" = 5.0 ] && [ "$(field per_finding_usd)" = 0.5 ] && [ "$(field review_usd)" = 3.0 ] || fail "planned caps" "$(cat "$out")"
[ "$(field planned_max_usd)" = 5.0 ] || fail "planned worst case: 4 x 0.50 + 3.00" "$(cat "$out")"
[ "$(field result)" = dry-run ] || fail "dry-run result" "$(cat "$out")"

# The quota finding needs two consecutive weeks at the cut-off.
python3 - "$store/reports/2026-10-04-weekly.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j["previous"]["quota"]["peak_seven_day_pct"] = 84
json.dump(j, open(sys.argv[1], "w"))
PY
run 0 run --window weekly --dry-run
grep -qF '"weekly-quota-peak:weekly"' "$out" && fail "one week at the cut-off is not a finding" "$(cat "$out")"
# Too few interactive sessions to take a share of.
python3 - "$store/sessions/2026-09.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows = [r for r in rows if r["session_id"] not in ("w3", "w4")]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
run 0 run --window weekly --dry-run
grep -qF '"unattributed-sessions:interactive"' "$out" && fail "four sessions are too few for a share" "$(cat "$out")"
# With w3 gone nothing invoked busy any more: 40 of 1000.
[ "$(row unused-plugin:busy)" = "false,4.0,hook_injected_bytes,40,1000,planned,null" ] || fail "busy finding" "$(cat "$out")"
reset_store

# A daily report embeds no inventory; the newest stored one stands in, and only
# critical findings are taken. Five of five sessions without a repo: 100% against 50%.
run 0 run --window daily --dry-run
[ "$(field label_date)" = 2026-10-08 ] || fail "daily label" "$(cat "$out")"
[ "$(row unattributed-sessions:interactive)" = "true,50.0,interactive_unattributed_share,1.0,0.5,planned,null" ] || fail "daily unattributed" "$(cat "$out")"
[ "$(row unused-plugin:caveman)" = "true,30.0,hook_injected_bytes,300,1000,planned,null" ] || fail "daily caveman" "$(cat "$out")"
[ "$(row unused-plugin:quiet)" = "false,2.0,hook_injected_bytes,20,1000,skipped,not-critical" ] || fail "a daily run takes critical findings only" "$(cat "$out")"
[ "$(field run_usd)" = 3.0 ] || fail "daily cap" "$(cat "$out")"
# 3 x 0.50 leaves 1.50 of the 3.00 for the review.
[ "$(field planned_max_usd)" = 3.0 ] || fail "daily worst case" "$(cat "$out")"
run 0 run --window monthly --dry-run
[ "$(field run_usd)" = 10.0 ] && [ "$(field label_date)" = 2026-09-30 ] || fail "monthly cap and label" "$(cat "$out")"

# At most the configured number per run.
cfg max_findings=2
run 0 run --window weekly --dry-run
[ "$(row unattributed-sessions:interactive | cut -d, -f6-)" = "skipped,over-max" ] || fail "third finding should wait for the next run" "$(cat "$out")"
[ "$(field planned_max_usd)" = 4.0 ] || fail "worst case for two findings" "$(cat "$out")"
cfg

# Trend findings wait for stored variance.
python3 - "$propose" <<'PY' || fail "the trend finder stub must return nothing"
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("agent_propose", sys.argv[1]).load_module()
assert m.find_trends({}) == [], "trend findings are out of scope until a month of variance is stored"
assert m.find_trends in m.FINDERS, "the stub must be wired in, so filling it in is the only step left"
PY

# No stored report for the window is a failure that names the fix.
rm "$store"/reports/*-monthly.json
run 1 run --window monthly --dry-run
has "agent-report --window monthly" "a missing report does not name agent-report"
reset_store

# Hostile report values never become identifiers or reach a command line.
python3 - "$store/reports/2026-10-04-weekly.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
j["audit"]["disable_candidates"]["plugins"] += [
    {"plugin": "evil; rm -rf ~", "provides": "hooks", "hook_bytes": 500},
    {"plugin": "--upload-pack=x", "provides": "hooks", "hook_bytes": 500},
    {"plugin": "nan", "provides": "hooks", "hook_bytes": float("nan")},
    {"plugin": "text", "provides": "hooks", "hook_bytes": "300"}]
j["audit"]["instructions"]["files"] += [{"path": "~/../../etc/passwd", "lines": 999, "bytes": 1},
                                        {"path": "~/a b`id`.md", "lines": 999, "bytes": 1}]
json.dump(j, open(sys.argv[1], "w"))
PY
run 0 run --window weekly --dry-run
for bad in "evil" "upload-pack" '"unused-plugin:nan"' '"unused-plugin:text"' "passwd" "id\`"; do
    grep -qF -- "$bad" "$out" "$err" && fail "a hostile report value surfaced: $bad" "$(cat "$out" "$err")"
done
[ "$(row unused-plugin:caveman)" = "true,30.0,hook_injected_bytes,300,1000,planned,null" ] || fail "hostile neighbours changed a real finding" "$(cat "$out")"
echo '{"window": "weekly", "label_date": "2026-10-04; x"}' >"$store/reports/2026-10-04-weekly.json"
run 2 run --window weekly --dry-run
has "not a usable stored report" "a damaged report is not named"
reset_store

# ── Gates ──
# An audit PR is already open: a weekly run stops there.
echo '[{"number": 40, "headRefName": "chore/agent-audit-2026-10-05"}]' >"$stub/gh/pr-list-open.json"
run 0 run --window weekly --dry-run
[ "$(field result)" = stopped ] && [ "$(field stopped)" = open-pr ] || fail "an open audit PR must stop a weekly run" "$(cat "$out")"
[ "$(gate open-pr)" = "stop,#40 open" ] || fail "open-pr gate detail" "$(cat "$out")"
grep -qF '["pr", "list", "--repo", "acme/dotfiles", "--label", "agent-audit", "--state", "open"' "$stub/gh.log" || fail "open-PR query" "$(ghlog)"
# A daily run with a critical finding may add to it.
run 0 run --window daily --dry-run
[ "$(gate open-pr)" = "ok,append to #40" ] || fail "a critical daily run may append" "$(cat "$out")"
[ "$(field result)" = dry-run ] || fail "daily append dry run" "$(cat "$out")"
# A head branch this tool would not have made is not trusted.
echo '[{"number": 40, "headRefName": "feat/x; rm -rf"}]' >"$stub/gh/pr-list-open.json"
run 0 run --window daily --dry-run
[ "$(field stopped)" = open-pr ] || fail "a foreign head branch must stop the run" "$(cat "$out")"
grep -q "rm -rf" "$out" "$err" && fail "a hostile branch name was echoed"
echo '[{"number": 40, "headRefName": "chore/agent-audit-2026-10-05"}, {"number": 39, "headRefName": "chore/agent-audit-2026-10-01"}]' >"$stub/gh/pr-list-open.json"
run 0 run --window daily --dry-run
[ "$(field stopped)" = open-pr ] || fail "two open audit PRs must stop the run" "$(cat "$out")"
echo 'not json' >"$stub/gh/pr-list-open.json"
run 1 run --window weekly
has "open-pr" "an unreadable PR list is a failure, not a pass"
[ "$(calls)" = 0 ] || fail "a model was called after a failed gate"
rm "$stub/gh/pr-list-open.json"

# Budget: the whole run's cap must fit.
echo '{"plan_pct": 0.1, "hard_pct": 0.2, "weekly_quota_cutoff_pct": 85}' >"$tmp/config/budget.json"
run 0 run --window weekly
[ "$(field stopped)" = budget ] || fail "a denied budget must stop the run" "$(cat "$out")"
gate budget | grep -q "^stop," || fail "budget gate detail" "$(cat "$out")"
[ "$(calls)" = 0 ] || fail "a model was called past the budget gate"
# Over the plan and under the hard stop, only a run with a critical finding may spend.
echo '{"plan_pct": 0.3, "hard_pct": 5, "weekly_quota_cutoff_pct": 85}' >"$tmp/config/budget.json"
run 0 run --window weekly --dry-run
gate budget | grep -q "^ok," || fail "a critical finding may spend in critical-only" "$(cat "$out")"
python3 - "$store/reports/2026-10-04-weekly.json" <<'PY'
import json, sys
j = json.load(open(sys.argv[1]))
j["audit"]["disable_candidates"]["plugins"] = [p for p in j["audit"]["disable_candidates"]["plugins"] if p["plugin"] == "quiet"]
j["audit"]["instructions"]["files"] = []
json.dump(j, open(sys.argv[1], "w"))
PY
python3 - "$store/sessions/2026-09.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
for r in rows:
    r["repo"] = r["repo"] or "acme/app"
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
run 0 run --window weekly --dry-run
[ "$(field stopped)" = budget ] || fail "without a critical finding critical-only must stop" "$(cat "$out")"
# The daily window still has its own critical finding, and its smaller cap fits the plan.
run 0 run --window daily --dry-run
[ "$(row unattributed-sessions:interactive | cut -d, -f6-)" = "planned,null" ] || fail "daily still has its own finding" "$(cat "$out")"
cp "$cfgsrc/budget.json" "$tmp/config/budget.json"
reset_store

# The base branch requires an approving review: stop before spending, in both places it can live.
echo '[{"type": "pull_request", "parameters": {"required_approving_review_count": 1}}]' >"$stub/gh/rules.json"
run 0 run --window weekly
[ "$(field stopped)" = review-required ] || fail "a ruleset approval gate must stop the run" "$(cat "$out")"
has "bot" "the stop does not say the PR must be opened as the bot"
[ "$(calls)" = 0 ] || fail "a model was called although no PR could be opened"
echo '[{"type": "pull_request", "parameters": {"required_approving_review_count": 0, "require_code_owner_review": true}}]' >"$stub/gh/rules.json"
run 0 run --window weekly
[ "$(field stopped)" = review-required ] || fail "a code-owner gate must stop the run" "$(cat "$out")"
echo '[{"type": "pull_request", "parameters": {"required_approving_review_count": 0}}, {"type": "deletion"}]' >"$stub/gh/rules.json"
echo '{"required_pull_request_reviews": {"required_approving_review_count": 2}}' >"$stub/gh/protection.json"
run 0 run --window weekly
[ "$(field stopped)" = review-required ] || fail "classic protection must stop the run" "$(cat "$out")"
grep -qF '["api", "repos/acme/dotfiles/rules/branches/main"]' "$stub/gh.log" || fail "ruleset query" "$(ghlog)"
grep -qF '["api", "repos/acme/dotfiles/branches/main/protection"]' "$stub/gh.log" || fail "protection query" "$(ghlog)"
rm "$stub/gh/protection.json" "$stub/gh/rules.json"
# An access error is not a "no".
echo "HTTP 403: Resource not accessible" >"$stub/gh/rules.fail"
run 0 run --window weekly
[ "$(field stopped)" = review-gate-unknown ] || fail "an unreadable ruleset must stop the run" "$(cat "$out")"
rm "$stub/gh/rules.fail"
echo "HTTP 403: Must have admin rights" >"$stub/gh/protection.fail"
run 0 run --window weekly
[ "$(field stopped)" = review-gate-unknown ] || fail "unreadable protection must stop the run" "$(cat "$out")"
rm "$stub/gh/protection.fail"
[ "$(calls)" = 0 ] || fail "a model was called behind a closed gate"

# ── Rejection memory ──
hist="$store/findings/history.jsonl"
write_history() {
    mkdir -p "$store/findings"
    python3 - "$hist" "$@" <<'PY'
import json, sys
rows = []
for spec in sys.argv[2:]:
    fid, proposed, pr, outcome, *rest = spec.split("|")
    r = {"id": fid, "proposed_at": proposed, "pr": int(pr) if pr else None, "branch": "chore/agent-audit-" + proposed[:10],
         "commit_subject": "chore(agent-audit): x", "outcome": outcome, "window": "weekly", "label_date": "2026-09-27",
         "metric": "hook_injected_bytes"}
    for kv in rest:
        k, v = kv.split("=", 1)
        r[k] = json.loads(v)
    rows.append(r)
open(sys.argv[1], "w").write("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
PY
    gs add -A
    gs commit -q -m "history"
    gs push -q
}
pr_view() {  # <number> <state> <mergedAt|null> <closedAt|null> [finding id in a commit]
    python3 - "$stub/gh/pr-view-$1.json" "$2" "$3" "$4" "${5:-}" <<'PY'
import json, sys
path, state, merged, closed, fid = sys.argv[1:6]
commits = [{"messageHeadline": "chore(agent-audit): x", "messageBody": f"why\n\nFinding: {fid}\nEvidence: weekly 2026-09-27"}] if fid else []
commits.append({"messageHeadline": "docs: a person's commit", "messageBody": ""})
json.dump({"number": int(path.rsplit("-", 1)[1].split(".")[0]), "state": state,
           "mergedAt": None if merged == "null" else merged, "closedAt": None if closed == "null" else closed,
           "commits": commits}, open(path, "w"))
PY
}
# PR 30 merged with caveman's commit removed (dropped) and quiet's kept (merged);
# PR 31 closed unmerged (closed); PR 32 still open.
write_history "unused-plugin:caveman|2026-09-01T10:00:00Z|30|open" \
    "unused-plugin:quiet|2026-09-01T10:00:00Z|30|open" \
    "oversize-instructions:.claude/CLAUDE.md|2026-09-08T10:00:00Z|31|open" \
    "unattributed-sessions:interactive|2026-06-01T10:00:00Z|29|closed|resolved_at=\"2026-06-10T00:00:00Z\""
pr_view 30 MERGED 2026-09-03T09:00:00Z 2026-09-03T09:00:00Z unused-plugin:quiet
pr_view 31 CLOSED null 2026-09-09T09:00:00Z
run 0 run --window weekly --dry-run
[ "$(row unused-plugin:caveman | cut -d, -f6-)" = "skipped,dropped" ] || fail "a dropped finding must not return within 90 days" "$(cat "$out")"
[ "$(row oversize-instructions:.claude/CLAUDE.md | cut -d, -f6-)" = "skipped,closed" ] || fail "a closed finding must not return within 90 days" "$(cat "$out")"
# Closed 121 days ago: outside the memory.
[ "$(row unattributed-sessions:interactive | cut -d, -f6-)" = "planned,null" ] || fail "a rejection older than 90 days should be forgotten" "$(cat "$out")"
# Merged 36 days ago: the fix is in, and the finder still fires, so it may be proposed again.
[ "$(row unused-plugin:quiet | cut -d, -f6-)" = "planned,null" ] || fail "a finding merged long ago may return" "$(cat "$out")"
grep -qF '["pr", "view", "30", "--repo", "acme/dotfiles", "--json", "state,mergedAt,closedAt,commits"]' "$stub/gh.log" || fail "outcome query" "$(ghlog)"
# The dry run refreshed nothing on disk.
grep -q '"outcome":"open"' "$hist" || grep -q '"outcome": "open"' "$hist" || fail "a dry run rewrote history"
[ -z "$(gs status --porcelain)" ] || fail "a dry run changed the store" "$(gs status --porcelain)"
# Still open: not proposed twice.
write_history "unused-plugin:caveman|2026-10-06T10:00:00Z|32|open"
pr_view 32 OPEN null null unused-plugin:caveman
run 0 run --window weekly --dry-run
[ "$(row unused-plugin:caveman | cut -d, -f6-)" = "skipped,open" ] || fail "an open finding must not be proposed twice" "$(cat "$out")"
# Merged a week ago: its effect is not measured yet.
pr_view 32 MERGED 2026-10-02T09:00:00Z 2026-10-02T09:00:00Z unused-plugin:caveman
run 0 run --window weekly --dry-run
[ "$(row unused-plugin:caveman | cut -d, -f6-)" = "skipped,merged" ] || fail "a just-merged finding must wait for its verdict" "$(cat "$out")"
# GitHub cannot be asked: the memory is unknown, so a real run stops.
rm "$stub/gh/pr-view-32.json"
run 1 run --window weekly
has "history" "a failed outcome refresh is not named"
[ "$(calls)" = 0 ] || fail "a model was called with the rejection memory unknown"
# A history line that is not a row stops the run and names the file.
echo '{"id": "x; rm", "outcome": "open"}' >>"$hist"
run 2 run --window weekly --dry-run
has "history.jsonl" "a damaged history is not named"
reset_all

# ── Dry run touches nothing ──
before_store="$(gs rev-parse HEAD)$(gs status --porcelain)$(git -C "$remote" for-each-ref)"
before_target="$(gt rev-parse HEAD)$(gt status --porcelain)$(gt worktree list)$(gt branch -a)$(git -C "$target_remote" for-each-ref)"
rm -f "$stub/gh.log"
run 0 run --window weekly --dry-run
[ "$before_store" = "$(gs rev-parse HEAD)$(gs status --porcelain)$(git -C "$remote" for-each-ref)" ] || fail "a dry run changed the store"
[ "$before_target" = "$(gt rev-parse HEAD)$(gt status --porcelain)$(gt worktree list)$(gt branch -a)$(git -C "$target_remote" for-each-ref)" ] || fail "a dry run changed the target repo"
[ "$(calls)" = 0 ] || fail "a dry run called a model"
[ ! -e "$sandbox" ] || [ -z "$(ls -A "$sandbox")" ] || fail "a dry run left a worktree"
[ ! -e "$store/findings" ] && [ ! -e "$store/ledger" ] || fail "a dry run wrote findings or ledger"
grep -vE '^\["(pr", "(list|view)|api)"' "$stub/gh.log" && fail "a dry run made a GitHub call that is not a read" "$(ghlog)"
# A report outside the store can be previewed, and only previewed.
cp "$store/reports/2026-10-04-weekly.json" "$tmp/elsewhere.json"
rm "$store"/reports/*-weekly.json
run 0 run --window weekly --dry-run --report "$tmp/elsewhere.json"
[ "$(row unused-plugin:caveman)" = "true,30.0,hook_injected_bytes,300,1000,planned,null" ] || fail "--report preview" "$(cat "$out")"
reset_all

echo "test_agent_propose_script: OK"
