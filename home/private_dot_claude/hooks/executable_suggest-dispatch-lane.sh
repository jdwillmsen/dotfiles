#!/usr/bin/env bash
# PreToolUse hook on Agent, Task and the T3 delegate_task tool: asks `agent-pace assign` which lane the delegated work
# belongs to and adds the answer as context, so the Dispatch rule in the shared AGENTS.md is applied by the harness
# instead of left to memory. Class, risk and ticket are inferred from the call; what is not stated falls back to impl
# and R1. It asks with --no-log: the guess is advice, and only a dispatch the agent actually makes belongs in the
# assignment log that agent-eval and the pace reports read.
#
# Advisory only: it never sets a permission decision, and a missing agent-pace, a timeout or any fault exits 0 with
# no output, so a broken hook never stops a delegation.
set -u
trap 'exit 0' ERR

IFS= read -r -d '' input || true

# The settings matcher is anchored, but a tool whose name merely contains one of these (TaskStop, TaskList) must still
# get nothing, whatever matcher a machine ends up with.
[[ $input =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || exit 0
case ${BASH_REMATCH[1]} in
    Agent | Task | mcp__t3-code__delegate_task) ;;
    *) exit 0 ;;
esac

command -v agent-pace >/dev/null 2>&1 || exit 0
PY=python3
"$PY" -c "" >/dev/null 2>&1 || PY=python
# shellcheck disable=SC2016  # the single-quoted block is python source, not shell
printf '%s' "$input" | "$PY" -I -c '
import json, os, re, subprocess, sys

# agent-pace answers in about 0.1s; the cap keeps a stuck quota read from stalling every delegation.
TIMEOUT_S = 1.0

SUBAGENT_CLASS = {"explore": "research", "plan": "plan", "claude-code-guide": "research", "web-fetch": "research"}
ROLE_CLASS = {"implementation": "impl", "research": "research", "review": "review", "test": "test", "design": "plan"}
TEXT_CLASS = [
    ("review-fix", r"\b(address|fix|resolve|apply)\b[^.\n]{0,40}\b(review|findings?)\b"),
    ("review", r"\b(review|audit)\b"),
    ("test", r"\b(write|add|extend)\b[^.\n]{0,20}\btests?\b"),
    ("summarize", r"\b(summari[sz]e|summary|read the logs?)\b"),
    ("research", r"\b(research|investigate|find out|look up|explore|search)\b"),
    ("docs", r"\b(document|docs|readme|write-?up)\b"),
    ("ops", r"\b(deploy|roll ?out|restart|kubectl)\b"),
]
RISK = re.compile(r"\b(?:risk|tier)[^A-Za-z0-9\n]{0,3}R([0-3])\b|\bR([0-3])\b[^A-Za-z0-9\n]{0,3}(?:risk|tier)\b", re.I)


def ticket_keys():
    try:
        with open(os.path.expanduser("~/.config/streams.json")) as f:
            streams = json.load(f)["streams"].values()
        keys = {s["jira"] for s in streams}
        keys |= {v for s in streams for v in (s.get("repoOverrides") or {}).values()}
        return sorted(keys, key=len, reverse=True)
    except Exception:
        return []


def infer(tool, ti):
    text = " ".join(str(ti.get(k) or "") for k in ("description", "title", "prompt", "task"))[:4000]
    how = "a default"
    cls = None
    if tool == "mcp__t3-code__delegate_task":
        cls = ROLE_CLASS.get(str(ti.get("role") or ""))
        how = "the role" if cls else how
    else:
        cls = SUBAGENT_CLASS.get(str(ti.get("subagent_type") or "").lower())
        how = "the agent type" if cls else how
    if not cls:
        low = text.lower()
        cls = next((c for c, rx in TEXT_CLASS if re.search(rx, low)), None)
        how = "the brief" if cls else how
    m = RISK.search(text)
    risk = "R" + (m.group(1) or m.group(2)) if m else None
    keys = ticket_keys()
    t = re.search(r"\b(?:%s)-[0-9]+\b" % "|".join(map(re.escape, keys)), text) if keys else None
    return cls or "impl", how, risk or "R1", bool(risk), t.group(0) if t else None


def main():
    data = json.loads(sys.stdin.read())
    tool = data.get("tool_name") or ""
    ti = data.get("tool_input") or {}
    cls, how, risk, risk_stated, ticket = infer(tool, ti)
    # The seed makes the pick repeatable: the logged command below gets the same lane this advice names.
    seed = str(data.get("tool_use_id") or data.get("session_id") or "")
    cmd = ["agent-pace", "assign", "--class", cls, "--risk", risk, "--no-log", "--json"]
    if ticket:
        cmd += ["--ticket", ticket]
    if seed:
        cmd += ["--seed", seed]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S)
    a = json.loads(p.stdout)
    if tool == "mcp__t3-code__delegate_task":
        running = str((ti.get("target") or {}).get("model") or "")
    else:
        running = str(ti.get("model") or os.environ.get("CLAUDE_CODE_SUBAGENT_MODEL") or "")
    basis = f"class {cls} (from {how}), risk {risk}"
    ticket_arg = ticket or "<KEY>"
    risk_arg = risk if risk_stated else "<tier>"
    redo = f"agent-pace assign --class {cls} --risk {risk_arg} --ticket {ticket_arg}" + (f" --seed {seed}" if seed else "")
    result, reason, lane, model = a.get("result"), a.get("reason") or "", a.get("lane") or "", a.get("model")
    fallback = ", ".join(a.get("fallback") or []) or "none"
    if result != "assigned":
        msg = (f"agent-pace has no lane now for {basis}: result {result}, {reason}. "
               "Queue the work rather than hand it to a lane the tier does not allow.")
    elif not risk_stated:
        # An unstated tier is not R1: a lane picked for R1 may be one a higher tier forbids, so it is not offered as
        # the answer.
        msg = (f"No risk tier is stated, so agent-pace was asked for R1: lane {lane} ({model}) for class {cls} "
               f"(from {how}) is valid for R1 only; state the tier (classify up when unsure) and re-run.")
    else:
        msg = f"agent-pace suggests lane {lane} ({model}) for {basis} (stated); fallback {fallback}. "
        if not running:
            msg += "This call runs on the inherited model; check that it is that lane."
        elif lane.startswith("claude-") and lane[len("claude-"):] in running.lower():
            msg += f"This call runs on {running}, which matches."
        else:
            msg += (f"This call runs on {running}, not that lane. If the lane fits the work, dispatch there instead "
                    "(task-dispatch skill).")
    msg += f" To log a real assignment: {redo}, then agent-eval record the outcome."
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                             "additionalContext": "dispatch-lane: " + msg}}))


try:
    main()
except Exception:
    pass
' || true
exit 0
