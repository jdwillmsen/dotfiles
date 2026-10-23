# Autonomous delivery

How work flows when the owner brings ideas and agents do the rest: classify by
risk, route each task to a model lane by rule, spend the weekly plan quota on
purpose, and measure every model so the choice improves. The design and its
reasoning are in `docs/superpowers/specs/2026-10-23-autonomous-delivery-design.md`;
the options considered and the data behind them are in
[`ticket-driven-agent-workflow.md`](ticket-driven-agent-workflow.md).

## The pieces

| Piece | What it does | Where |
|---|---|---|
| `change-class` | Classifies a plan, ticket, diff or PR as R0–R3 with tags. No model call. | `~/.local/bin/change-class`, policy `~/.config/agents/change-risk.toml` |
| `agent-pace` | Reads the plan-quota log, works out where the week should be, and picks a lane for each task. | `~/.local/bin/agent-pace`, lanes `~/.config/agents/lanes.toml` |
| `agent-eval` | Keeps the assignment and outcome ledgers, collects T3 delegated-task history, scores each lane per task class, advises keep, probation or promote. | `~/.local/bin/agent-eval`, ledgers `~/.local/state/agent-eval/` |
| `models` report section | Puts the scoreboard and pace in the daily to yearly agent reports. | `agent-report` |
| Rules and skills | Risk tiers, stuck protocol, ticket-per-thread, dispatch. | shared `AGENTS.md`, skills `jira-followup`, `task-dispatch` |

## Risk tiers

| Tier | Merge gate | Human |
|---|---|---|
| R0 trivial | green CI | no |
| R1 low | one agent review from another model family | no |
| R2 medium | Sonnet-or-better review, bot findings resolved | no |
| R3 critical | Opus review | interview before work, approval before merge |

Highest tier wins and a rule can only raise it. R3 covers production config and
promotion, infrastructure that gets applied, auth and secrets, data and
migrations, network policy, the agent rules themselves, repository governance
and game servers. Size alone lifts a change to at most R2.

Tuning: a false R3 is a rule to narrow (add an `exclude`, tighten a glob), not a
reason to lower the tier. A missed R3 is a rule to add, and that is a
rules-file change, which is itself R3.

## Pacing the week

`agent-pace status` shows where the 7-day window should be by now. Under the
line, more tasks go to Sonnet and Opus until the quota is used by the end of
the window; over it, work shifts to free lanes. At 85% of the five-hour window
Claude lanes pause until it resets. Opus is capped at 20% of dispatches.
Targets, gain and caps are in `lanes.toml` under `[pacing]`.

## Choosing a lane

Eligibility first: the lane lists the task class, may implement the tier, is
available, not cooled down and under its concurrency cap. Then weight:
`share × pacing × evidence × exploration`. Evidence is the lane's quality
record for that class, shrunk toward its prior until it has enough samples.
Under-sampled lanes get a small boost on R0 and R1 work only, which is how new
models are tried without risking anything that matters. Free lanes implement
up to R1; the scoreboard can advise allowing R2, and the owner accepts that by
editing `max_risk` in `lanes.toml`.

## Review cadence

All of these come from `agent-report` once the `models` section is in.

| Cadence | Look at | Decide |
|---|---|---|
| Daily | pace gap, cooldowns, dispatch mix, unmapped models | nothing, unless a lane is stuck in cooldown |
| Weekly | scoreboard per lane and class, completion, quality, cost | whether the share mix moved the right way |
| Biweekly | verdicts, promotion advice, retry and escalation rates | promote or demote a lane's `max_risk` or class list |
| Monthly | fitness per lane over the month, R3 interview rate, false-positive notes on the rules | keep, probation or drop a lane; retune baseline shares and `change-risk.toml` |

A lane's quality score counts only capability: quota, rate-limit, timeout and
retired-model failures are availability and are tracked separately, so a
free model is not marked down for a provider outage.

## Adding a model

Add a `[[lane]]` to `lanes.toml` with `status = "explore"`, `max_risk = "R0"` and
a low share. It receives only R0 work. When the scoreboard has enough samples,
`agent-eval verdicts` says keep, probation or drop; to widen it, change
`status` to `active` and raise `max_risk` one step at a time.

## Not built yet

- The merge captain: a loop that classifies open PRs, runs the tier's reviewer
  lane, and merges R0–R2 when the gate is met.
- GitHub labels and rulesets keyed to the risk tier, and a Jira field for it.
- Mirroring the ledgers into the metrics store.
- A weekday-weighted pace curve; the line is linear for now.
