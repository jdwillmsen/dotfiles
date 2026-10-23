#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-pace is arithmetic over a quota log, a lane policy and two ledgers, so
# every test builds those under a temp dir and pins the clock.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
pace="$here/home/dot_local/bin/executable_agent-pace"
policy="$here/home/dot_config/agents/lanes.toml"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$pace" ] || fail "agent-pace missing or not executable"
python3 -I -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$pace" || fail "agent-pace does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

now_iso="2026-10-23T12:00:00Z"
now_epoch="$(python3 -c "import datetime as d; print(int(d.datetime(2026, 10, 23, 12, tzinfo=d.timezone.utc).timestamp()))")"
export AGENT_PACE_NOW="$now_iso"
export AGENT_PACE_LANES="$policy"
export AGENT_PACE_QUOTA="$tmp/quota.jsonl"
export AGENT_EVAL_STATE="$tmp/eval"
export AGENT_PACE_EVAL="$tmp/agent-eval-stub"

# The stub prints whatever weights.json holds, the way `agent-eval weights --json` would.
printf '#!/bin/sh\nexec cat "%s/weights.json"\n' "$tmp" >"$tmp/agent-eval-stub"
chmod +x "$tmp/agent-eval-stub"
echo '{"lanes": {}}' >"$tmp/weights.json"

out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$pace" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-pace $* exited $got, want $want" "$(cat "$out" "$err")"
}

# check 'python expression over j' [label]: j is the last JSON output.
check() {
    python3 -I - "$out" "$1" <<'PY' || fail "${2:-$1}" "$(cat "$out")"
import json, sys
j = json.load(open(sys.argv[1]))
assert eval(sys.argv[2]), sys.argv[2]
PY
}

# quota AGE_MIN FIVE_PCT FIVE_RESETS_H SEVEN_PCT SEVEN_RESETS_DAYS: one reading, AGE_MIN old.
quota() {
    python3 - "$AGENT_PACE_QUOTA" "$now_epoch" "$@" <<'PY'
import json, sys
path, now, age, five, five_h, seven, seven_d = sys.argv[1:]
now = int(now)
row = {"at": now - int(float(age) * 60)}
if five != "-":
    row.update(five_hour_pct=float(five), five_hour_resets_at=now + int(float(five_h) * 3600))
if seven != "-":
    row.update(seven_day_pct=float(seven), seven_day_resets_at=now + int(float(seven_d) * 86400))
open(path, "w").write(json.dumps(row) + "\n")
PY
}

weights() { printf '%s\n' "$1" >"$tmp/weights.json"; }

# ── Usage ──
run 0 --version
run 0 --help
grep -q "assign" "$out" || fail "--help does not list assign" "$(cat "$out")"
run 2 frobnicate
grep -q "^error:" "$out" || fail "an unknown command has no structured error" "$(cat "$out")"
run 2 assign --class nonsense --risk R1
grep -q "^error:" "$out" || fail "an unknown class has no structured error" "$(cat "$out")"
run 2 assign --class impl --risk R9
run 2 assign --class impl --risk R1 --exclude no-such-lane
run 2 assign --class impl --risk R1 --ticket "drop table"
AGENT_PACE_LANES="$tmp/missing.toml" run 1 shares
grep -q "^error:" "$out" || fail "missing policy has no structured error" "$(cat "$out")"

# ── No readings: baseline, said so ──
rm -f "$AGENT_PACE_QUOTA"
run 0 status --json
check "j['state'] == 'no-data' and j['claude_multiplier'] == 1.0" "no readings does not pace at baseline"
run 0 status
grep -q "^state: no-data" "$out" || fail "status TOON has no state" "$(cat "$out")"

# ── On the pace line: baseline shares ──
# 3.5 days left -> half the window -> line 47.5; 47 is within the band.
quota 1 10 3 47 3.5
run 0 status --json
check "j['state'] == 'on' and j['pace_line_pct'] == 47.5 and j['gap_pct'] == 0.5 and j['elapsed_pct'] == 50.0"
check "j['hours_left'] == 84.0 and j['claude_multiplier'] == 1.0 and not j['five_hour_paused']"
run 0 shares --json
check "j['claude_multiplier'] == 1.0"
check "{r['lane']: r['effective_pct'] for r in j['lanes']}['claude-sonnet'] == 40.0" "on-pace sonnet is not the baseline 40"
check "abs(sum(r['effective_pct'] for r in j['lanes']) - 100) < 0.1" "shares do not sum to 100"
baseline_free="$(python3 -c "
import json; j = json.load(open('$out'))
print(sum(r['effective_pct'] for r in j['lanes'] if r['group'] == 'free'))")"
baseline_claude="$(python3 -c "
import json; j = json.load(open('$out'))
print(sum(r['effective_pct'] for r in j['lanes'] if r['group'] == 'claude'))")"

group_pct() {
    python3 -c "
import json; j = json.load(open('$out'))
print(sum(r['effective_pct'] for r in j['lanes'] if r['group'] == '$1'))"
}
more() { python3 -c "import sys; sys.exit(0 if float('$1') > float('$2') else 1)"; }

# ── Under the line: claude up, free down ──
quota 1 10 3 27.5 3.5
run 0 shares --json
check "abs(j['claude_multiplier'] - 1.632) < 0.001 and j['state'] == 'under'" "under-pace multiplier is wrong"
more "$(group_pct claude)" "$baseline_claude" || fail "under the line did not raise the claude group"
more "$baseline_free" "$(group_pct free)" || fail "under the line did not lower the free group"
check "'favour claude' in j['recommendation']"

# ── Over the line: the reverse ──
quota 1 10 3 70 3.5
run 0 shares --json
check "abs(j['claude_multiplier'] - 0.289) < 0.001 and j['state'] == 'over'" "over-pace multiplier is wrong"
more "$baseline_claude" "$(group_pct claude)" || fail "over the line did not lower the claude group"
more "$(group_pct free)" "$baseline_free" || fail "over the line did not raise the free group"

# ── The multiplier is clamped ──
quota 1 10 3 0 3.5
run 0 status --json
check "j['claude_multiplier'] == 2.0" "multiplier not clamped to claude_weight_max"
quota 1 10 3 95 3.5
run 0 status --json
check "j['claude_multiplier'] == 0.25" "multiplier not clamped to claude_weight_min"

# ── End of window with quota left: claude never shrinks ──
quota 1 10 3 92 0.7
run 0 status --json
check "j['state'] == 'over' and j['claude_multiplier'] == 1.0" "end-game headroom did not floor the multiplier at 1"
quota 1 10 3 96 0.7
run 0 status --json
check "j['claude_multiplier'] < 1.0" "end-game with no headroom still floored the multiplier"

# ── Opus never exceeds its cap ──
python3 - "$policy" "$tmp/capped.toml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = text.replace('share = 10\nmax_risk = "R3"', 'share = 70\nmax_risk = "R3"', 1)
text = text.replace('id = "opencode-mimo-free"\ngroup = "free"\nprovider = "opencode"\nmodel = "opencode/mimo-v2.6-flash-free"\n'
                    'family = "mimo"\nstatus = "active"', 'id = "opencode-mimo-free"\ngroup = "free"\nprovider = "opencode"\n'
                    'model = "opencode/mimo-v2.6-flash-free"\nfamily = "mimo"\nstatus = "paused"', 1)
assert 'share = 70' in text and 'status = "paused"' in text
open(sys.argv[2], "w").write(text)
PY
quota 1 10 3 0 3.5
AGENT_PACE_LANES="$tmp/capped.toml" run 0 shares --json
check "{r['lane']: r['effective_pct'] for r in j['lanes']}['claude-opus'] <= 20.0" "opus exceeded opus_share_cap"
check "{r['lane']: r['effective_pct'] for r in j['lanes']}['claude-opus'] > 19.0" "opus was cut below the cap"
check "{r['lane']: r for r in j['lanes']}['claude-opus']['note'] == 'capped'"
opus_picks=0
for s in $(seq 1 200); do
    AGENT_PACE_LANES="$tmp/capped.toml" run 0 assign --class plan --risk R2 --seed "cap$s" --no-log --json
    if grep -q '"lane": "claude-opus"' "$out"; then opus_picks=$((opus_picks + 1)); fi
done
# 20% of 200 is 40; leave room for sampling noise but not for the uncapped 70%.
[ "$opus_picks" -le 60 ] || fail "opus took $opus_picks of 200 plan dispatches despite the cap"
# A paused lane never gets work, and says why.
AGENT_PACE_LANES="$tmp/capped.toml" run 0 shares --json
check "{r['lane']: r for r in j['lanes']}['opencode-mimo-free']['effective_pct'] == 0.0" "paused lane has weight"
check "{r['lane']: r for r in j['lanes']}['opencode-mimo-free']['note'] == 'paused'"
AGENT_PACE_LANES="$tmp/capped.toml" run 0 ladder --class docs --risk R1 --json
check "'opencode-mimo-free' not in [r['lane'] for r in j['ladder']]" "paused lane is on the ladder"

# ── Five-hour pause ──
quota 1 90 2 20 3.5
run 0 status --json
check "j['five_hour_paused'] and j['five_hour_resets_at'] == '2026-10-23T14:00:00Z'"
run 0 shares --json
check "all(r['effective_pct'] == 0.0 for r in j['lanes'] if r['group'] == 'claude')" "claude lanes kept weight under the pause"
check "abs(sum(r['effective_pct'] for r in j['lanes']) - 100) < 0.1"
# R3 work only a claude lane may do waits, with the reset time.
run 3 assign --class impl --risk R3 --seed p --no-log --json
check "j['result'] == 'defer' and j['defer_until'] == '2026-10-23T14:00:00Z'" "R3 under pause was not deferred"
run 3 assign --class impl --risk R3 --seed p
grep -q "^result: defer" "$out" || fail "defer TOON has no result" "$(cat "$out")"
grep -q "^defer_until: " "$out" || fail "defer TOON has no reset time" "$(cat "$out")"
run 3 assign --class impl --risk R2 --seed p --no-log --json
check "j['result'] == 'defer'" "R2 under pause was not deferred"
# R0 and R1 work goes to free lanes, whatever the seed.
for s in $(seq 1 25); do
    run 0 assign --class impl --risk R1 --seed "pause$s" --no-log --json
    check "j['result'] == 'assigned' and not j['lane'].startswith('claude-')" "R1 went to a claude lane under the pause"
    run 0 assign --class docs --risk R0 --seed "pause$s" --no-log --json
    check "not j['lane'].startswith('claude-')" "R0 went to a claude lane under the pause"
done
run 0 ladder --class impl --risk R1 --json
check "not any(r['lane'].startswith('claude-') for r in j['ladder'])" "ladder offers a paused claude lane"
# Below the threshold nothing pauses; a past reset means the reading is about an old window.
quota 1 84 2 20 3.5
run 0 status --json
check "not j['five_hour_paused']"
quota 1 90 -1 20 3.5
run 0 status --json
check "not j['five_hour_paused']" "a reset window still pauses"

# ── Stale reading: flagged, baseline shares ──
# Usage cannot fall before its window resets, so an old five-hour reading at the
# threshold keeps the pause while the reset is still ahead.
quota 45 99 2 0 3.5
run 0 status --json
check "j['stale'] and j['state'] == 'stale' and j['claude_multiplier'] == 1.0" "stale seven-day reading paced"
check "j['five_hour_stale'] and j['five_hour_paused']" "a stale five-hour reading at the threshold lifted the pause"
run 0 shares --json
check "{r['lane']: r['effective_pct'] for r in j['lanes']}['claude-sonnet'] == 0.0" "a stale paused reading left claude weight"
# A stale reading below the threshold proves nothing, so it does not pause.
quota 45 50 2 0 3.5
run 0 status --json
check "j['five_hour_stale'] and not j['five_hour_paused']" "a stale reading below the threshold paused"
run 0 shares --json
check "{r['lane']: r['effective_pct'] for r in j['lanes']}['claude-sonnet'] == 40.0" "stale reading moved the shares"
# A stale reading at the threshold whose window has reset no longer pauses.
quota 45 99 -1 0 3.5
run 0 status --json
check "j['five_hour_stale'] and not j['five_hour_paused']" "a stale reading from a reset window paused"
quota 29 10 3 0 3.5
run 0 status --json
check "not j['stale'] and j['claude_multiplier'] == 2.0" "a 29 minute reading was called stale"

# ── A seven-day window that has already reset ──
quota 1 10 3 20 -0.5
run 0 status --json
check "j['state'] == 'rolled' and j['claude_multiplier'] == 1.0 and j['gap_pct'] is None" "a reset seven-day window still paced"
check "'baseline' in j['recommendation']"
run 0 shares --json
check "{r['lane']: r['effective_pct'] for r in j['lanes']}['claude-sonnet'] == 40.0" "a reset seven-day window moved the shares"
run 0 status
grep -q "^state: rolled" "$out" || fail "rolled TOON has no state" "$(cat "$out")"

# ── Bad quota data is skipped and counted, never fatal ──
good_line() {
    printf '{"at": %s, "five_hour_pct": 10, "five_hour_resets_at": %s, "seven_day_pct": 27.5, "seven_day_resets_at": %s}\n' \
        "$((now_epoch - 60))" "$((now_epoch + 10800))" "$((now_epoch + 302400))"
}
{
    good_line
    echo '{"at": 1e20, "seven_day_pct": 50, "seven_day_resets_at": 1e20}'
    echo '{"at": 1000000000, "seven_day_pct": 50}'
    echo '{"at": 5000000000, "seven_day_pct": 50}'
    echo '{"at": NaN, "seven_day_pct": 50}'
    echo "{\"at\": $((now_epoch - 30)), \"seven_day_pct\": NaN, \"seven_day_resets_at\": $((now_epoch + 302400))}"
    echo "{\"at\": $((now_epoch - 30)), \"seven_day_pct\": Infinity}"
    echo "{\"at\": $((now_epoch - 30)), \"seven_day_pct\": 140, \"seven_day_resets_at\": $((now_epoch + 302400))}"
    echo "{\"at\": $((now_epoch - 30)), \"five_hour_pct\": -5}"
    echo "{\"at\": $((now_epoch - 30)), \"seven_day_pct\": 50, \"seven_day_resets_at\": 1e20}"
    echo "{\"at\": $((now_epoch - 30)), \"seven_day_pct\": 50, \"seven_day_resets_at\": \"nan\"}"
    echo 'not json at all'
    printf '\xff\xfe{"at": 1}\n'
} >"$AGENT_PACE_QUOTA"
run 0 status --json
check "j['quota_skipped'] == 12" "skipped quota lines are miscounted"
check "j['state'] == 'under' and j['used_pct'] == 27.5 and j['claude_multiplier'] == 1.632" "a bad line displaced the good reading"
run 0 status
grep -q "^quota_skipped: 12" "$out" || fail "status TOON has no quota_skipped" "$(cat "$out")"
# Invalid UTF-8 beside a good line is survivable; the lone bad line is counted.
{ printf '\xff\xfe\n'; good_line; } >"$AGENT_PACE_QUOTA"
run 0 status --json
check "j['quota_skipped'] == 1 and j['state'] == 'under'" "invalid UTF-8 in the quota file broke status"
# Nothing usable at all is no-data, still not an error.
printf '{"at": NaN}\n{"seven_day_pct": 10}\n' >"$AGENT_PACE_QUOTA"
run 0 status --json
check "j['state'] == 'no-data' and j['quota_skipped'] == 2 and j['claude_multiplier'] == 1.0" "unusable quota did not fall back to baseline"
quota 1 10 3 0 3.5
run 0 status --json
check "j['quota_skipped'] == 0" "a clean quota file reported skipped lines"

# ── Lanes drop out ──
quota 1 10 3 47 3.5
weights '{"lanes": {}}'
# unavailable_until in the future
run 0 ladder --class review --risk R1 --json
check "'codex-luna' not in [r['lane'] for r in j['ladder']]" "future unavailable_until kept codex-luna"
run 0 shares --json
check "{r['lane']: r for r in j['lanes']}['codex-luna']['note'].startswith('unavailable until 2026-11-17')"
AGENT_PACE_NOW="2026-11-18T00:00:00Z" run 0 ladder --class review --risk R1 --json
check "'codex-luna' in [r['lane'] for r in j['ladder']]" "codex-luna still out after unavailable_until"
# a cooldown from the weights JSON
weights '{"lanes": {"opencode-glm-flash-free": {"impl": {"n": 9, "quality_mean": 0.8, "quality_lb": 0.5,
  "infra_rate": 1.0, "median_s": 60, "cooldown_until": "2026-10-23T13:00:00Z"}}}}'
run 0 ladder --class impl --risk R1 --json
check "'opencode-glm-flash-free' not in [r['lane'] for r in j['ladder']]" "cooldown kept the lane"
run 0 shares --json
check "{r['lane']: r for r in j['lanes']}['opencode-glm-flash-free']['effective_pct'] == 0.0"
weights '{"lanes": {"opencode-glm-flash-free": {"impl": {"n": 9, "quality_mean": 0.8, "quality_lb": 0.5,
  "infra_rate": 1.0, "median_s": 60, "cooldown_until": "2026-10-23T11:00:00Z"}}}}'
run 0 ladder --class impl --risk R1 --json
check "'opencode-glm-flash-free' in [r['lane'] for r in j['ladder']]" "an expired cooldown still excludes"
weights '{"lanes": {}}'
# the class is missing from a lane, and max_risk is too low
run 0 ladder --class summarize --risk R0 --json
check "'claude-opus' not in [r['lane'] for r in j['ladder']] and 'claude-haiku' not in [r['lane'] for r in j['ladder']]" \
    "opus does not list summarize but is on the ladder"
run 0 ladder --class docs --risk R2 --json
check "[r['lane'] for r in j['ladder']] == ['claude-sonnet']" "a low max_risk lane stayed on an R2 ladder"
run 0 ladder --class impl --risk R3 --json
check "[r['lane'] for r in j['ladder']] == ['claude-sonnet', 'claude-opus']" "R3 impl ladder is not sonnet, opus"
# --exclude
run 0 ladder --class impl --risk R1 --exclude claude-sonnet,opencode-nim-glm --json
check "not {'claude-sonnet', 'opencode-nim-glm'} & {r['lane'] for r in j['ladder']}" "--exclude ignored"

# ── Explore lanes receive only R0 ──
run 0 ladder --class docs --risk R0 --json
check "'opencode-nemotron-ultra-free' in [r['lane'] for r in j['ladder']]" "explore lane missing at R0"
run 0 ladder --class docs --risk R1 --json
check "not any(r['lane'] in ('opencode-nemotron-ultra-free', 'opencode-big-pickle', 'opencode-flint-free')
  for r in j['ladder'])" "explore lane on an R1 ladder"
for s in $(seq 1 40); do
    run 0 assign --class docs --risk R1 --seed "ex$s" --no-log --json
    check "j['lane'] not in ('opencode-nemotron-ultra-free', 'opencode-big-pickle', 'opencode-flint-free')" \
        "an explore lane was assigned R1 work"
done

# ── Concurrency cap: unfinished assignments younger than 4 hours ──
rm -rf "$tmp/eval"
mkdir -p "$tmp/eval"
ledger() { # ID LANE AGE_H
    python3 - "$tmp/eval/assignments.jsonl" "$now_epoch" "$@" <<'PY'
import datetime as dt, json, sys
path, now, aid, lane, age = sys.argv[1:]
at = dt.datetime.fromtimestamp(int(now) - float(age) * 3600, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "a") as f:
    f.write(json.dumps({"id": aid, "at": at, "lane": lane, "provider": "grok", "model": "grok-4.7", "class": "review",
                        "risk": "R1", "ticket": None, "pace": {}, "implementer": None}) + "\n")
PY
}
run 0 ladder --class research --risk R1 --json
check "'grok-4-7' in [r['lane'] for r in j['ladder']]" "grok missing with an empty ledger"
ledger a-young grok-4-7 1
run 0 ladder --class research --risk R1 --json
check "'grok-4-7' not in [r['lane'] for r in j['ladder']]" "an unfinished assignment did not count against concurrency"
echo '{"id": "a-young", "lane": "grok-4-7", "status": "completed"}' >"$tmp/eval/outcomes.jsonl"
run 0 ladder --class research --risk R1 --json
check "'grok-4-7' in [r['lane'] for r in j['ladder']]" "a finished assignment still counted"
rm "$tmp/eval/outcomes.jsonl" "$tmp/eval/assignments.jsonl"
ledger a-old grok-4-7 5
run 0 ladder --class research --risk R1 --json
check "'grok-4-7' in [r['lane'] for r in j['ladder']]" "an assignment older than 4 hours counted"
ledger a-old2 grok-4-7 3.9
run 0 ladder --class research --risk R1 --json
check "'grok-4-7' not in [r['lane'] for r in j['ladder']]" "a 3.9 hour assignment did not count"
rm "$tmp/eval/assignments.jsonl"

# ── Seeded choice ──
first=""
for _ in 1 2 3 4 5; do
    run 0 assign --class impl --risk R1 --seed fixed --no-log --json
    lane="$(python3 -c "import json; print(json.load(open('$out'))['lane'])")"
    [ -z "$first" ] && first="$lane"
    [ "$lane" = "$first" ] || fail "the same seed chose $lane, then $first"
done
seen=""
for s in $(seq 1 40); do
    run 0 assign --class impl --risk R1 --seed "s$s" --no-log --json
    seen="$seen $(python3 -c "import json; print(json.load(open('$out'))['lane'])")"
done
[ "$(printf '%s\n' "$seen" | tr ' ' '\n' | sort -u | grep -c .)" -gt 3 ] || fail "forty seeds chose fewer than four lanes: $seen"
run 0 assign --class impl --risk R1 --ticket JDW-9 --no-log --json
a="$(python3 -c "import json; print(json.load(open('$out'))['lane'])")"
run 0 assign --class impl --risk R1 --ticket JDW-9 --no-log --json
check "j['lane'] == '$a'" "the ticket key does not seed the choice"

# ── Logging ──
run 0 assign --class impl --risk R1 --seed x --no-log
[ ! -e "$tmp/eval/assignments.jsonl" ] || fail "--no-log wrote the ledger"
grep -q "^logged: false" "$out" || fail "--no-log output does not say it was not logged"
grep -q "^assignment: a-20261023-1200-" "$out" || fail "assignment id has the wrong shape" "$(cat "$out")"
grep -q "^fallback\[" "$out" || fail "assignment has no fallback" "$(cat "$out")"
quota 1 10 3 27.5 3.5
run 0 assign --class impl --risk R1 --seed x --ticket JDW-77
[ "$(wc -l <"$tmp/eval/assignments.jsonl")" = 1 ] || fail "a real assignment did not append exactly one line"
python3 -I - "$tmp/eval/assignments.jsonl" "$out" <<'PY' || fail "ledger line is wrong" "$(cat "$tmp/eval/assignments.jsonl")"
import json, re, sys
rec = json.loads(open(sys.argv[1]).read())
assert set(rec) == {"id", "at", "lane", "provider", "model", "class", "risk", "ticket", "pace", "implementer"}, set(rec)
assert re.fullmatch(r"a-20261023-1200-[0-9a-f]{3}", rec["id"]), rec["id"]
assert rec["at"] == "2026-10-23T12:00:00Z"
assert rec["class"] == "impl" and rec["risk"] == "R1" and rec["ticket"] == "JDW-77" and rec["implementer"] is None
assert set(rec["pace"]) == {"used", "line", "multiplier"}
assert rec["pace"] == {"used": 27.5, "line": 47.5, "multiplier": 1.632}, rec["pace"]
assert f"assignment: {rec['id']}" in open(sys.argv[2]).read()
PY
run 0 assign --class impl --risk R1 --seed y
[ "$(wc -l <"$tmp/eval/assignments.jsonl")" = 2 ] || fail "second assignment did not append"
[ "$(python3 -c "
import json
ids = [json.loads(l)['id'] for l in open('$tmp/eval/assignments.jsonl')]
print(len(set(ids)))")" = 2 ] || fail "assignment ids collided"
grep -qiE 'prompt|token|secret' "$tmp/eval/assignments.jsonl" && fail "ledger carries suspicious text" || true
rm "$tmp/eval/assignments.jsonl"

# ── Reviewer by tier ──
run 0 assign --class impl --risk R3 --seed r --no-log --json
check "j['review_lane'] == 'claude-opus'" "R3 reviewer is not opus"
run 0 assign --class impl --risk R2 --seed r --no-log --json
check "j['review_lane'] == 'claude-sonnet'" "R2 reviewer is not sonnet"
run 0 assign --class docs --risk R0 --seed r --no-log --json
check "j['review_lane'] is None" "R0 has a reviewer"
run 0 assign --class impl --risk R1 --seed r --no-log --json
check "j['review_lane'] is not None and j['review_lane'] != j['lane']"
# review of R1 prefers a family other than the implementer's
for s in $(seq 1 25); do
    run 0 assign --class review-fix --risk R1 --implementer opencode-glm-flash-free --seed "f$s" --no-log --json
    check "j['lane'] not in ('opencode-glm-flash-free', 'opencode-nim-glm')" "review-fix went to the implementer's family"
done

# ── Evidence: ladder order, factor, floor ──
weights '{"lanes": {
  "opencode-deepseek-flash-free": {"impl": {"n": 200, "success": 0, "quality_mean": 0.0, "quality_lb": 0.0, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "opencode-mimo-free": {"impl": {"n": 40, "success": 38, "quality_mean": 0.95, "quality_lb": 0.9, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "opencode-glm-flash-free": {"impl": {"n": 40, "success": 24, "quality_mean": 0.60, "quality_lb": 0.5, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}}
}}'
run 0 ladder --class impl --risk R1 --json
check "[r['lane'] for r in j['ladder']][:4] == ['opencode-mimo-free', 'opencode-glm-flash-free', 'opencode-nim-glm',
  'opencode-deepseek-flash-free']" \
    "free lanes are not ordered by evidence"
check "[r['lane'] for r in j['ladder']][-2:] == ['claude-sonnet', 'claude-opus']" "ladder does not end sonnet, opus"
check "[r['group'] for r in j['ladder']] == sorted([r['group'] for r in j['ladder']], key=lambda g: g != 'free')" \
    "a free lane follows a claude lane"
found=""
for s in $(seq 1 200); do
    run 0 assign --class impl --risk R1 --seed "ev$s" --no-log
    if grep -q "^lane: opencode-deepseek-flash-free" "$out"; then found=1; break; fi
done
[ -n "$found" ] || fail "deepseek was never chosen in 200 seeds"
grep -q "evidence x0.20" "$out" || fail "evidence factor is not floored at 0.2" "$(cat "$out")"

# ── The prior counts once ──
# glm-flash has prior 0.78 and prior_weight 6: 10 of 10 successes is (6*0.78 + 10) / 16.
weights '{"lanes": {"opencode-glm-flash-free": {"impl": {"n": 10, "success": 10, "quality_mean": 0.9175,
  "quality_lb": 0.7, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}}}}'
run 0 ladder --class impl --risk R1 --json
check "abs({r['lane']: r['evidence'] for r in j['ladder']}['opencode-glm-flash-free'] - 0.9175) < 0.001" \
    "10 of 10 successes did not give 0.9175"
# Without success, quality_mean is already the posterior and is not shrunk again.
weights '{"lanes": {"opencode-glm-flash-free": {"impl": {"n": 10, "quality_mean": 0.64,
  "quality_lb": 0.4, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}}}}'
run 0 ladder --class impl --risk R1 --json
check "abs({r['lane']: r['evidence'] for r in j['ladder']}['opencode-glm-flash-free'] - 0.64) < 0.001" \
    "quality_mean was shrunk toward the prior a second time"
# No judged outcomes: the lane's prior.
weights '{"lanes": {"opencode-glm-flash-free": {"impl": {"n": 0, "success": 0, "quality_mean": 0.5,
  "quality_lb": 0.0, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}}}}'
run 0 ladder --class impl --risk R1 --json
check "abs({r['lane']: r['evidence'] for r in j['ladder']}['opencode-glm-flash-free'] - 0.78) < 0.001" \
    "a lane with no outcomes is not at its prior"

# ── Exploration: under-sampled lanes on R0/R1 only ──
weights '{"lanes": {
  "claude-sonnet": {"docs": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null},
                    "impl": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "claude-opus": {"impl": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "opencode-glm-flash-free": {"docs": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "opencode-deepseek-flash-free": {"docs": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "opencode-mimo-free": {"docs": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}},
  "claude-haiku": {"docs": {"n": 30, "quality_mean": 0.9, "quality_lb": 0.8, "infra_rate": 0.0, "median_s": 90, "cooldown_until": null}}
}}'
found=""
for s in $(seq 1 300); do
    run 0 assign --class docs --risk R0 --seed "xp$s" --no-log
    if grep -q "^lane: opencode-nemotron-ultra-free" "$out"; then found=1; break; fi
done
[ -n "$found" ] || fail "the under-sampled explore lane never got R0 work"
grep -qE "explore x([2-9]|1[0-9])\.|explore x1\.[1-9]" "$out" || fail "an under-sampled lane got no exploration boost" "$(cat "$out")"
# R2 never explores.
for s in $(seq 1 20); do
    run 0 assign --class impl --risk R2 --seed "r2$s" --no-log
    grep -q "explore x1.00" "$out" || fail "R2 work explored" "$(cat "$out")"
done

# ── Missing, empty or failing agent-eval: evidence factor 1, said so ──
for bad in "$tmp/no-such-eval" "" "$tmp/failing-eval"; do
    printf '#!/bin/sh\nexit 7\n' >"$tmp/failing-eval"
    chmod +x "$tmp/failing-eval"
    AGENT_PACE_EVAL="$bad" run 0 assign --class impl --risk R1 --seed e --no-log
    grep -q "evidence x1.00" "$out" || fail "no evidence did not give factor 1 (EVAL='$bad')" "$(cat "$out")"
    grep -q "agent-eval" "$out" || fail "the reason does not say agent-eval was missing (EVAL='$bad')" "$(cat "$out")"
done
printf '#!/bin/sh\necho not-json\n' >"$tmp/garbage-eval"
chmod +x "$tmp/garbage-eval"
AGENT_PACE_EVAL="$tmp/garbage-eval" run 0 assign --class impl --risk R1 --seed e --no-log
grep -q "evidence x1.00" "$out" || fail "unreadable agent-eval output did not give factor 1" "$(cat "$out")"

# ── Nothing eligible says so ──
run 3 assign --class summarize --risk R3 --seed n --no-log
grep -q "^result: none" "$out" || fail "work no lane can take is not reported as none" "$(cat "$out")"
grep -q "^reason: " "$out" || fail "none has no reason" "$(cat "$out")"

echo "ok: agent-pace"
