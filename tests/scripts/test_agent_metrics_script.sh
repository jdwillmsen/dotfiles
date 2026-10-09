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

echo "test_agent_metrics_script: OK"
