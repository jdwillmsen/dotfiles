#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# agent-trends renders the store into one static page and pushes it, so the
# tests build against a fixture store cloned from a local bare repo.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
trends="$here/home/dot_local/bin/executable_agent-trends"
units="$here/home/dot_config/systemd/user"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$trends" ] || fail "agent-trends missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$trends" || fail "agent-trends does not parse"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "chmod -R u+w '$tmp' 2>/dev/null; rm -rf '$tmp'" EXIT
remote="$tmp/remote.git"
store="$tmp/store"
git init -q --bare -b main "$remote"
git clone -q "$remote" "$store" 2>/dev/null

export HOME="$tmp/home"
export AGENT_METRICS_STORE="$store"
export AGENT_METRICS_STATE="$tmp/state"
export AGENT_METRICS_CONFIG="$tmp/config"
export AGENT_METRICS_NOW="2026-10-09T12:00:00+00:00"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME" "$tmp/config"
git -C "$store" commit -q --allow-empty -m init
git -C "$store" push -q -u origin HEAD:main

out="$tmp/out"
err="$tmp/err"
run() {
    local want="$1" got=0
    shift
    "$trends" "$@" >"$out" 2>"$err" || got=$?
    [ "$got" = "$want" ] || fail "agent-trends $* exited $got, want $want" "$(cat "$out" "$err")"
}

run 0 --help
grep -q "build" "$out" || fail "--help does not list build" "$(cat "$out")"
run 0
grep -q "^store:" "$out" || fail "home view does not report the store" "$(cat "$out")"
run 2 frobnicate
grep -q "^error:" "$out" || fail "an unknown command does not print a structured error" "$(cat "$out")"

# ── An empty store renders plain no-data states ──
run 0 build --out "$tmp/empty"
python3 - "$tmp/empty/index.html" <<'PY' || fail "the empty-store page is wrong"
import sys
page = open(sys.argv[1]).read()
assert page.count("No data") >= 6, page.count("No data")
assert "<svg" not in page, "drew a chart with no data"
assert "list-price estimates" in page
PY

# ── Fixture store ──
# Last 7 days = (10-02 12:00, 10-09 12:00]; the 7 before = (09-25 12:00, 10-02 12:00].
mkdir -p "$store/sessions" "$store/quota" "$store/reports"
python3 - "$store" <<'PY'
import json, sys
store = sys.argv[1]
def model(cost, i=0, o=0, cr=0, cw=0):
    return {"calls": 1, "input": i, "output": o, "cache_read": cr, "cache_write_5m": cw, "cache_write_1h": 0, "cost_usd": cost}
def row(sid, start, pop, cost, main, sub=None, repo=None, pipeline=None, prs=()):
    return {"schema": 1, "session_id": sid, "started_at": start, "population": pop, "cost_usd": cost, "repo": repo,
            "pipeline": pipeline, "models": {"main": main, "subagent": sub or {}},
            "pr_links": [{"repo": r, "number": n} for r, n in prs]}
evil = "acme/<script>alert(1)</script>"
rows = {
    "2026-10": [
        row("s1", "2026-10-08T10:00:00Z", "interactive", 10.0,
            {"claude-opus-5": model(6.0, i=100, cr=800, cw=100), "claude-sonnet-5": model(4.0)}, repo=evil,
            prs=[("acme/app", 7), ("acme/app", 8)]),
        row("s2", "2026-10-07T09:00:00Z", "scripted", 5.0, {"claude-sonnet-5": model(4.0)},
            {"claude-haiku-4-5": model(1.0)}, repo="acme/app", pipeline="no-mistakes", prs=[("acme/app", 7)]),
        row("s3", "2026-10-05T00:00:00Z", "scripted", 2.5, {"claude-opus-5": model(2.5)}, pipeline="agent-audit"),
        row("s4", "2026-10-01T08:00:00Z", "interactive", 7.0, {"claude-sonnet-5": model(7.0)}, repo="acme/app",
            prs=[("acme/app", 5)]),
    ],
    "2026-09": [
        row("s5", "2026-09-28T08:00:00Z", "scripted", 1.0, {"claude-haiku-4-5": model(1.0)}),
    ],
    "2026-08": [row("s6", "2026-08-20T08:00:00Z", "interactive", 3.0, {"mystery-9": model(3.0)})],
    "2026-06": [row("s7", "2026-06-01T08:00:00Z", "interactive", 400.0, {"claude-opus-5": model(400.0)})],
}
for month, rs in rows.items():
    with open(f"{store}/sessions/{month}.jsonl", "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in rs))
with open(f"{store}/quota/2026-10.jsonl", "w") as f:
    for hour, five, seven in (("2026-10-08T10:00:00Z", 40, 55), ("2026-10-08T11:00:00Z", 20, 62), ("2026-10-03T10:00:00Z", None, 71)):
        r = {"hour": hour, "readings": 1, "seven_day_pct": seven}
        if five is not None:
            r["five_hour_pct"] = five
        f.write(json.dumps(r) + "\n")
with open(f"{store}/quota/2026-09.jsonl", "w") as f:
    f.write(json.dumps({"hour": "2026-09-30T10:00:00Z", "readings": 1, "five_hour_pct": 5, "seven_day_pct": 48}) + "\n")
def report(window, label, **kw):
    r = {"schema": 1, "window": window, "label_date": label, "current": {}, "previous": {}, "flags": [], "delivery": None}
    r.update(kw)
    json.dump(r, open(f"{store}/reports/{label}-{window}.json", "w"))
report("weekly", "2026-09-21", delivery={"error": "gh unavailable"})
report("weekly", "2026-09-28", delivery=None)
report("weekly", "2026-10-05", delivery={"followup_fix_rate_7d": 0.25, "followup_fix_rate_14d": 0.4,
                                         "failed_check_share": 0.125, "no_mistakes": {"first_pass_rate": 0.8}})
report("weekly", "2026-10-02", delivery={"merged_prs": 3})
report("daily", "2026-10-08", flags=[
    {"id": "spend-spike", "severity": "critical", "metric": "daily_cost", "message": "CANARY_MESSAGE", "value": 91.5, "baseline": 29.4},
    {"id": "cache-drop", "severity": "warn", "metric": "cache_read_share", "message": "x", "value": 0.41, "baseline": None}])
report("daily", "2026-10-07")
PY
git -C "$store" add -A && git -C "$store" commit -q -m fixture && git -C "$store" push -q origin HEAD:main

# ── Page structure ──
run 0 build --out "$tmp/page"
cat >"$tmp/check.py" <<'PY'
import sys
from html.parser import HTMLParser

page = open(sys.argv[1]).read()
VOID = {"meta", "br", "hr", "img", "input", "link", "col"}

class Balanced(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append(tag)
    def handle_endtag(self, tag):
        assert self.stack and self.stack[-1] == tag, f"unbalanced </{tag}> over {self.stack[-3:]}"
        self.stack.pop()

p = Balanced()
p.feed(page)
p.close()
assert not p.stack, f"unclosed {p.stack}"

for bad in ("http://", "https://", "src=", "<link", "@import", "url(", "<img", "<iframe"):
    assert bad not in page, f"external reference {bad!r}"
assert page.count("<script") == 1, "only the one hover script is allowed"
assert "<script>alert(1)" not in page and "&lt;script&gt;alert(1)&lt;/script&gt;" in page, "repo name not escaped"
assert "prefers-color-scheme: dark" in page

def has(*needles):
    for n in needles:
        assert n in page, f"missing {n!r}"

# Tiles: 10+5+2.5 = 17.50 over 3 sessions and PRs {7, 8}; before: 7+1 = 8.00, 2 sessions, PR {5}.
has("$17.50", "$8.00", "$8.75", ">3<", "71%", "before: 48%")
has("+119%")
# Daily chart table: stacked by population on 10-08.
has("2026-10-08", "10.00", "2026-10-07")
# Weekly spend by family, week of Monday 10-05: opus 8.50, sonnet 8.00, haiku 1.00.
has("2026-10-05", "8.50", "8.00")
# Cache read share that week: 800 / (100 + 800 + 100) tokens.
has("80.0%")
# Delivery trend and the flagged day.
has("25.0%", "40.0%", "12.5%")
has("spend-spike", "critical", "91.5", "29.4", "cache-drop", "warn")
assert "CANARY_MESSAGE" not in page, "free-text flag message reached the page"
has("acme/app", "no-mistakes", "agent-audit", "claude-opus-5")
assert "400.00" not in page, "a session outside the window was counted"
has("list-price estimates", "not a bill", "2026-10-09T12:00:00Z")
PY
python3 "$tmp/check.py" "$tmp/page/index.html" || fail "page assertions failed"
[ "$(git -C "$store" rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "--out must not publish"
[ ! -e "$store/site" ] || fail "--out wrote into the store"

# ── Sections without data say so ──
rm -f "$store/reports/"*weekly.json
run 0 build --out "$tmp/page2"
python3 - "$tmp/page2/index.html" <<'PY' || fail "a missing delivery series should give a no-data note"
import sys
page = open(sys.argv[1]).read()
assert "No data" in page and "No weekly reports" in page
PY
git -C "$store" checkout -q -- reports

# ── Dry run writes elsewhere and prints the path ──
run 0 build --dry-run
path="$(sed -n 's/^path: //p' "$out")"
[ -f "$path" ] && [ "$path" != "$store/site/index.html" ] || fail "--dry-run should write to a temp dir" "$(cat "$out")"
[ ! -e "$store/site" ] || fail "--dry-run wrote into the store"

# ── Default build publishes under the store, and only the page ──
echo '{}' >"$store/reports/inflight.json"
run 0 build
[ "$(git -C "$store" show --name-only --format= HEAD)" = "site/index.html" ] || fail "build committed more than the page" "$(git -C "$store" show --name-only --format= HEAD)"
git -C "$store" status --porcelain | grep -q "reports/inflight.json" || fail "build swept up another tool's in-progress file"
rm "$store/reports/inflight.json"
[ -f "$store/site/index.html" ] || fail "build did not write site/index.html"
[ "$(git -C "$store" log -1 --format=%s)" = "site: 2026-10-09" ] || fail "commit message" "$(git -C "$store" log -1 --format=%s)"
[ "$(git -C "$store" rev-parse HEAD)" = "$(git -C "$remote" rev-parse main)" ] || fail "build did not push"
before="$(git -C "$store" rev-list --count HEAD)"
run 0 build
[ "$(git -C "$store" rev-list --count HEAD)" = "$before" ] || fail "an unchanged rebuild committed again"
run 0 build --days 30 --out "$tmp/page30"
grep -q "2026-09-09" "$tmp/page30/index.html" && fail "--days 30 still charts September 9"

# ── Unreadable store data is named, never zero ──
echo '{nope' >>"$store/sessions/2026-10.jsonl"
run 2 build --out "$tmp/bad"
grep -q "sessions/2026-10.jsonl" "$out" || fail "a bad session line is not named" "$(cat "$out")"
git -C "$store" checkout -q -- sessions
python3 - "$store/sessions/2026-10.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
rows[0]["cost_usd"] = "lots"
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
run 2 build --out "$tmp/bad"
grep -q "sessions/2026-10.jsonl" "$out" || fail "a non-numeric cost is not named" "$(cat "$out")"
git -C "$store" checkout -q -- sessions
echo '{nope' >"$store/quota/2026-10.jsonl"
run 2 build --out "$tmp/bad"
grep -q "quota/2026-10.jsonl" "$out" || fail "a bad quota file is not named" "$(cat "$out")"
git -C "$store" checkout -q -- quota
echo '{nope' >"$store/reports/2026-10-08-daily.json"
run 2 build --out "$tmp/bad"
grep -q "reports/2026-10-08-daily.json" "$out" || fail "a bad report is not named" "$(cat "$out")"
git -C "$store" checkout -q -- reports

# ── Chart range ──
run 0 build --days 180 --out "$tmp/page180"
python3 - "$tmp/page180/index.html" <<'PY' || fail "a long range draws bars with no width"
import re, sys
page = open(sys.argv[1]).read()
widths = [float(w) for w in re.findall(r'<rect class="s\d"[^>]* width="([0-9.]+)"', page)]
assert widths and min(widths) >= 1, (len(widths), min(widths, default=None))
PY
run 2 build --days 181 --out "$tmp/page181"
grep -q "days" "$out" || fail "--days past the chart's limit should be refused" "$(cat "$out")"
run 2 build --days 0 --out "$tmp/page0"

# ── The 30-day tables do not depend on the chart range ──
AGENT_METRICS_NOW="2026-10-25T12:00:00+00:00" run 0 build --days 7 --out "$tmp/page7"
grep -qF "<td>claude-haiku-4-5</td><td>2</td><td>\$2.00</td>" "$tmp/page7/index.html" || fail "a short --days dropped sessions from the 30-day tables" \
    "$(grep -o '<td>claude-haiku[^/]*/td><td>[^/]*/td><td>[^/]*/td>' "$tmp/page7/index.html")"

# ── Values that would crash the renderer are named and write no page ──
bad_store() {  # $1: python statement editing rows
    python3 - "$store/sessions/2026-10.jsonl" "$1" <<'PY'
import json, sys
path, edit = sys.argv[1:]
rows = [json.loads(l) for l in open(path)]
exec(edit)
open(path, "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
}
bad_store 'rows[0]["cost_usd"] = 1e308; rows[1]["cost_usd"] = 1e308'
rm -rf "$tmp/ovf"
run 2 build --out "$tmp/ovf"
grep -q "sessions/2026-10.jsonl" "$out" && [ ! -e "$tmp/ovf/index.html" ] || fail "overflowing costs must exit 2 naming the file and write no page" "$(cat "$out" "$err")"
git -C "$store" checkout -q -- sessions
bad_store 'rows[0]["pr_links"] = [{"repo": "a/b", "number": [1]}]'
run 2 build --out "$tmp/ovf"
grep -q "sessions/2026-10.jsonl" "$out" && [ ! -e "$tmp/ovf/index.html" ] || fail "a list-valued PR number must exit 2 naming the file" "$(cat "$out" "$err")"
git -C "$store" checkout -q -- sessions
python3 - "$store/reports/2026-10-05-weekly.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["delivery"]["failed_check_share"] = 1.7e308
json.dump(d, open(sys.argv[1], "w"))
PY
run 0 build --out "$tmp/huge"
git -C "$store" checkout -q -- reports

# A report whose name has non-ASCII digits is not a report.
echo '{nope' >"$store/reports/٢٠٢٦-١٠-٠٨-daily.json"
run 0 build --out "$tmp/arabic"
rm "$store/reports/٢٠٢٦-١٠-٠٨-daily.json"

# ── A failed pull reads as text ──
other="$tmp/other"
git clone -q "$remote" "$other" 2>/dev/null
git -C "$other" commit -q --allow-empty -m remote-only && git -C "$other" push -q origin HEAD:main
git -C "$store" commit -q --allow-empty -m local-only
run 1 build
grep -q "pull failed" "$out" || fail "a failed pull is not reported" "$(cat "$out")"
if grep -q "\['" "$out"; then fail "a failed pull printed a Python list" "$(cat "$out")"; fi

# ── Units ──
svc="$units/agent-trends.service"
timer="$units/agent-trends.timer"
grep -qx 'ExecStart=%h/.local/bin/agent-trends build' "$svc" || fail "service ExecStart"
grep -qx 'NoNewPrivileges=yes' "$svc" && grep -qx 'PrivateTmp=yes' "$svc" || fail "service hardening missing"
grep -q '^TimeoutStartSec=' "$svc" || fail "service needs a hard timeout"
grep -q '^Environment=PATH=' "$svc" || fail "service needs a PATH: a user manager starts with a bare one"
grep -qxF "OnCalendar=*-*-* 07:30:00" "$timer" || fail "timer calendar"
grep -qx "Unit=agent-trends.service" "$timer" || fail "timer target"
grep -qx "Persistent=true" "$timer" || fail "timer must catch up after downtime"

echo "test_agent_trends_script: OK"
