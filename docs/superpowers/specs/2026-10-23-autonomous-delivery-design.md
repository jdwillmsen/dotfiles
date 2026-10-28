# Autonomous delivery: classify, pace, assign, evaluate

Date: 2026-10-23. Status: approved in chat by the owner; building.

## Intent

The owner supplies ideas and judgement; agents do the rest, including review
and merge. A human looks at a change only when it is critical. To make that
safe, every piece of work is classified by risk, every dispatch is routed to a
model lane by a rule rather than by habit, and the whole week's plan quota is
spent on purpose. Every dispatch also becomes a data point, so the daily,
weekly, biweekly and monthly reports can say which models are fit for which
work and whether to keep going.

## Goals

- A deterministic risk classifier for plans and diffs: tier R0–R3 plus tags.
- A rule that sends only R3 work to a human (an interview before it starts, an
  approval before it merges).
- A pacing tool that turns plan-quota use into a dispatch mix so the 7-day
  window ends near the target instead of unused or exhausted.
- An assignment tool that picks a lane (provider, model) for a task by risk,
  class, health, pacing and evidence, and logs the decision.
- An evaluation ledger and scoreboard per lane and task class, fed by T3
  delegated-task history and by explicit outcome records, with keep, probation
  and promotion advice.
- A models section in the existing agent reports.
- Shared rules and skills that make agents file tickets when stuck, work one
  ticket per thread, and use all of the above.

## Non-goals and anti-goals

- No model call inside the classifier, pacer or scoreboard. They are
  arithmetic and rules, so they are cheap, testable and cannot be argued with.
- Evidence never lowers a risk tier and never lets a lane implement above its
  `max_risk`. Promotion is advice a human accepts by editing `lanes.toml`.
- No auto-disable of a lane above R1 work. A bad model costs a retry, not a
  breach.
- No secrets, tokens or prompt text in any ledger.
- Not building the merge captain (the loop that merges PRs by tier) or the
  GitHub-side labels and rulesets here. They follow once these are measured.

## Risk tiers

Policy: `home/dot_config/agents/change-risk.toml` (deployed to
`~/.config/agents/change-risk.toml`). Highest matching tier wins.

| Tier | Meaning | Merge | Reviewer | Human |
|---|---|---|---|---|
| R0 | docs, tests, comments | auto on green CI | none | no |
| R1 | ordinary code, deps | after one agent review from another model family | `review@other-family` | no |
| R2 | CI, deploy config, non-prd rollout, large changes | after a Sonnet-or-better review and no open bot findings | `review@sonnet+` | no |
| R3 | prd, infra apply, auth and secrets, data and migrations, network, agent rules, governance, game server | never automatic | `review@opus` | interview before work, approval before merge |

Rules match on file paths, on changed-line content (secrets, destructive
commands) and on plan text (irreversible, secrets, people impact, exposure).
Size lifts R0/R1 up to R2 at 25 files or 800 changed lines. A per-repo floor
raises the minimum for deployment and infrastructure repos. A path that
matches no rule is R1.

## `change-class`

`home/dot_local/bin/executable_change-class`, Python 3 standard library only
(`tomllib`, `fnmatch`-style glob with `**`, `re`, `subprocess`). Agent-facing
CLI per the AXI rules: stdout is TOON, diagnostics on stderr, structured
errors on stdout, no prompts.

```
change-class                          # diff of HEAD against the merge base with origin/main, in cwd
change-class --base REF               # another base
change-class --pr N [--repo O/R]      # gh pr diff of that PR
change-class --files -                # newline-separated paths on stdin (no content rules)
change-class --plan FILE|-            # plan, ticket or PR text (plan rules only)
change-class --rules FILE             # default ~/.config/agents/change-risk.toml
change-class --fail-at R3             # exit 3 when the tier is at or above this
change-class --explain                # every matched rule, not just the deciding ones
```

The classifier fails closed: renames contribute both paths, untracked files
count as added, a path that is not valid UTF-8 is R3, and without a merge base
(no `origin/main`, more than one commit) it exits 1 asking for `--base` rather
than guessing one. An unknown repo prints `warnings[1]: repo unknown, floors matched on directory name` (or `floors skipped` when even that is unavailable).

Inputs combine: a diff plus a plan classifies as the higher of the two.
Output fields (TOON, field names fixed):

```
tier: R2
tags[3]: ci,deploy,docs
merge: agent-review
reviewer: review@sonnet+
human: false
interview: false
labels[3]: risk/R2,tag/ci,tag/deploy
reasons[2]{rule,tier,where}:
  ci-workflows,R2,.github/workflows/ci.yml
  deploy floor,R2,repo deployments
files: 4
lines: 120
```

Exit codes: 0 classified, 1 runtime failure, 2 usage error, 3 `--fail-at` hit.
An empty change is R0. Unreadable rules fail closed with exit 1, never a low
tier. A diff over a size cap for content scanning is classified on paths and
size only, and says `content_scanned: false`.

## Lanes and pacing

Config: `home/dot_config/agents/lanes.toml`. Baseline shares: Sonnet 40,
Opus 10, free lanes about 50 (including exploration lanes), Haiku 3.

`agent-pace` reads the plan-quota log `~/.local/state/agent-metrics/quota.jsonl`
(lines with `at`, `five_hour_pct`, `five_hour_resets_at`, `seven_day_pct`,
`seven_day_resets_at`; either window can be absent). The newest reading wins.

```
agent-pace status [--json]            # window, elapsed, used, pace line, gap, hours left, recommendation
agent-pace curve [--json]             # hour-of-week weights the pace line follows
agent-pace shares [--json]            # effective share per lane after pacing
agent-pace assign --class C --risk R [--exclude lane,...] [--ticket KEY] [--seed S] [--no-log]
agent-pace ladder --class C --risk R  # the escalation order for this class and risk
```

Pacing rules (the contract for the tests):

- Window start = `seven_day_resets_at` minus 7 days. Elapsed fraction `f` =
  (now − start) / 7 days, clamped to [0, 1]. Pace line = `target_end_pct × F`,
  where `F` is the share of the window's weighted time gone by now under the
  hour-of-week curve (`F = f` when the curve is flat). The curve is
  hour-of-day × weekday rates of the weekly-percent rise over the last
  `curve_history_days` (only rises above the window's running high count,
  spread back to the last reading that set or freshly confirmed it; a reading
  without a five-hour value is stale and counts only as a new high; a window
  whose opening is out of range starts from its first fresh reading), each shrunk toward the average rate, the hour-of-day
  profile smoothed over ±2 hours, blended toward flat so no hour is below
  `curve_floor` of an average hour. Fewer than `curve_min_history_h` hours of
  history (which must be above 0), `curve = "flat"`, or any error while
  learning the curve gives a flat curve.
  Gap = pace line − used. A stale reading (older than 30 minutes) is reported
  as stale, and pacing falls back to baseline shares.
  A window whose `seven_day_resets_at` has passed is `rolled` and also paces at
  baseline. Readings with non-finite numbers, percentages outside 0..100 or
  epochs outside 2020..2100 are skipped and counted as `quota_skipped`.
- Within `band_pct` of the line: baseline shares.
- Under the line: the `claude` group weight multiplier is
  `clamp(1 + gain × gap / max(pace_line, 25), min, max)`; over the line the same
  formula with a negative gap shrinks it. Free-group weights are unchanged and
  all weights are renormalised. Near the end of the window (f > 0.85) with
  headroom left, the multiplier is at least 1.
- Opus never exceeds `opus_share_cap` of the total, whatever the multiplier.
- `five_hour_pct ≥ five_hour_pause_pct`: `claude` lanes get weight 0 until
  `five_hour_resets_at`, even when the reading is older than 30 minutes (usage
  cannot fall before the reset); work that only a claude lane may do (see below) is
  reported as `defer` with the reset time, not silently given to a free lane.
- Lanes with `unavailable_until` in the future, a cooldown (below) or status
  `paused` get weight 0. Status `explore` lanes only receive R0 work.

Eligibility for `assign`, applied before weights: the lane lists the class;
its `max_risk` is at or above the task risk; it is not excluded; it is under
its `concurrency` cap (count of unfinished assignments in the ledger younger
than 4 hours). R3 work is eligible only for lanes that may implement R3
(claude-opus, claude-sonnet).

Reviewers follow the tier rule, in `assign --class review`, in the `review_lane`
field of every other class and in `ladder --class review`; `--implementer LANE`
supplies the lane that wrote the change. The implementer's own lane is never
its reviewer.

- R0: no reviewer (`review_lane: null`); a direct R0 review request may use any
  eligible lane.
- R1: a lane of a different model family than the implementer. With no such
  lane available `assign` returns `result: none` with a reason; it never falls
  back to the same family.
- R2: `claude-sonnet` or `claude-opus`, other than the implementer, so a Sonnet
  implementation is reviewed by Opus.
- R3: `claude-opus` only. When Opus is the implementer, `assign --class review`
  returns `result: none` ("no independent R3 reviewer"), `review_lane` is null,
  and the human review that R3 requires applies anyway.

An unknown implementer applies the tier rule without the exclusion. Class
`review-fix` at R1 only prefers a different family.

Weight of an eligible lane = share × pacing multiplier × evidence factor ×
exploration boost:

- Evidence factor comes from `agent-eval weights --json`: the quality posterior
  `(prior_weight × prior + successes) / (prior_weight + n)` for that lane and
  class (`successes` is the `success` count in the weights JSON; when it is absent
  `quality_mean` is taken as the posterior as it stands), divided by the best
  eligible lane's value, floored at 0.2. With no
  `agent-eval` available it is 1.
- Exploration boost: on R0/R1 work a lane with fewer than `min_samples`
  judged outcomes in that class gets an extra weight so that about
  `explore_fraction` of such tasks go to under-sampled lanes. R2 and R3 work
  never explores.

`assign` picks by weighted choice using `--seed` (default: ticket key or the
clock) so a test can fix the result. Output (TOON):

```
assignment: a-20261023-1642-7f3
lane: opencode-glm-flash-free
provider: opencode
model: opencode/glm-5.3-flash-free
class: impl
risk: R1
reason: weight 0.14 (share 12, pace x1.2, evidence x0.9, explore x1.0)
review_lane: claude-sonnet
fallback[3]: opencode-deepseek-flash-free,claude-sonnet,claude-opus
```

The fallback ladder runs free lanes by evidence, then `claude-sonnet`, then
`claude-opus`, filtered by eligibility. Every non-`--no-log` assignment is
appended to `assignments.jsonl`.

## Ledgers

State dir `~/.local/state/agent-eval/` (override `AGENT_EVAL_STATE`). Append-only
JSON lines, one object per line, no prompt or code text.

`assignments.jsonl`: `id`, `at` (ISO 8601 UTC), `lane`, `provider`, `model`,
`class`, `risk`, `ticket` (or null), `pace` (used, line, multiplier),
`implementer` (for reviews).

`outcomes.jsonl`: `id` (assignment id, or `t3:<hash of the thread id>` for
collected history; early collects wrote `t3:<threadId>`, which stays readable
and is matched by thread, never duplicated), `at`, `lane`, `provider`, `model`, `class` and `class_source`
(`assigned`, `heuristic`), `risk`, `ticket`, `status` (`completed`, `failed`,
`interrupted`), `failure_kind` (`none`, `infra`, `quota`, `timeout`,
`quality`), `duration_s`, `items`, `attempt` (1 for a first try),
`escalated_from` (lane or null), `pr` (URL or null), `ci_first_pass`
(true/false/null), `review_findings` (int/null), `merged` (true/false/null),
`reverted` (true/false/null), `human_touch` (true/false/null),
`cost_usd` (estimate, null for free lanes), `source` (`t3`, `record`, `gh`).

A later record for the same `id` replaces an earlier one when read.

## `agent-eval`

`home/dot_local/bin/executable_agent-eval`, same conventions.

```
agent-eval record --id ID [--status S] [--failure-kind K] [--class C] [--pr URL] [--ci-first-pass BOOL] [--review-findings N] [--merged BOOL] [--reverted BOOL] [--human-touch BOOL] [--escalated-from LANE] [--attempt N] [--note TEXT]
agent-eval collect [--since DAYS] [--dry-run]       # T3 delegated-task history -> outcomes, idempotent
agent-eval enrich [--since DAYS]                    # join outcomes to PRs by ticket key via gh: merged, reverted
agent-eval scoreboard [--since DAYS] [--lane L] [--class C] [--json]
agent-eval weights --json [--class C]               # per lane and class: n, success, quality_mean, quality_lb, infra_rate, median_s, cooldown_until
agent-eval verdicts [--since DAYS]                  # keep, probation, drop-for-class, promote advice
agent-eval report --window daily|weekly|biweekly|monthly [--end YYYY-MM-DD] [--format md|json]
```

Definitions:

- A judged outcome is one with `failure_kind` other than `infra`, `quota` and
  `timeout` (availability, not capability) and a status other than
  `interrupted` (stopped, not graded). Interrupted runs still count as attempts.
- Quality success = completed and not reverted and, when known,
  `ci_first_pass` is true and `human_touch` is not true. Unknown fields do not
  count against a lane. The quality score is success / judged, with the Wilson
  lower bound for ranking (`z = 1.96`).
- Availability = completed / all attempts; `infra_rate` = infra, quota and
  timeout failures / all attempts.
- Cooldown is per lane, across all classes: the last `cooldown_failures` attempts of a lane are all
  infrastructure failures → cooldown until the newest of them plus
  `cooldown_hours`.
- Verdict per lane and class with n ≥ `min_samples`: `keep` if the lower bound
  ≥ `keep_lb`; `probation` if ≥ `probation_lb`; `drop-for-class` otherwise. A
  lane at `max_risk` R1 with n ≥ `promote_min_n` at risk R1 and lower bound ≥
  `promote_lb` gets `advise: allow R2`. Fewer samples: `insufficient data`.
- `collect` reads `~/.t3/userdata/statev2.sqlite` read-only (copy to a temp
  file first if locked) and never reads or prints anything from
  `~/.t3/userdata/secrets`. Delegated tasks are threads whose id contains
  `delegate-task`; lane from provider and model; status mapping from the last
  run; `duration_s` from timestamps; `items` from the item count; ticket from
  a `[A-Z]+-[0-9]+` key in the title; retry number from a `-rN` suffix in the
  id; class from title keywords with `class_source: heuristic`. Failure kind
  from the logged error text: `429`, `rate`, `usage limit` → `quota`; header
  `timed out`, `timeout` → `timeout`; `410`, `context` → `infra`; anything
  else on a failed run → `quality` only if a commit or PR exists, else
  `infra`.
- `record` needs `--status` for an id that has no row yet. `--ticket` must
  look like `JDW-123`, `--pr` like `https://github.com/<owner>/<repo>/pull/<n>`;
  `--note` is capped at 200 characters and credential shapes become
  `[redacted]`. `--lane` on a collected row marks it `source: record`, so the
  next `collect` keeps it. Durations below zero are stored as 0.
- `enrich` searches only the owners in `~/.config/streams.json` (override
  `AGENT_EVAL_STREAMS`), one `gh search prs --owner` call per owner; a missing
  or unreadable map is an error, never an unscoped search. It marks the one
  attempt already tied to a found PR, else the newest completed attempt.
- `--since` takes 1 to 3650 days. Unreadable ledger lines are skipped with a
  stderr note and counted in `skipped_lines` (report JSON and `scoreboard
  --json`); the Markdown report says `Partial`.
- `report` returns, for the window and the previous one: dispatch counts by
  lane and by class, completion and quality by lane, the pace summary, the
  verdicts, cooldown events and one-line observations. Markdown when `--format
  md`. It must work with an empty ledger and say so.

## Report integration

`agent-report` gains a `models` section (like its existing `delivery` and
`audit` sections) that calls `agent-eval report --window <w> --format json`,
renders the Markdown, and marks the section errored, never zero, if the call
fails. Daily, weekly, biweekly, monthly, quarterly and yearly reports all get
it; the daily one shows pace and cooldowns only.

## Rules and skills (written alongside)

- Shared rules (`~/.config/agents/AGENTS.md`): risk-tiered review and merge in
  place of "review every diff by hand"; the stuck protocol; ticket-per-thread;
  classify before dispatch; lanes decided by `agent-pace`.
- Skills: `jira-followup` (file without confirmation), `task-dispatch`
  (classify, assign, brief, record, escalate).
- Jira: labels `agent-filed`, `needs-human`, `blocked`, `risk-R0`..`risk-R3`.

## Testing

Each tool has a bash test in `tests/scripts/` in the style of the existing
ones, with fixtures built under a temp dir, no network and no real T3 data.
`tests/scripts/test_shell_script_coverage.sh` must keep passing. Properties to
test: a rule can only raise a tier; an unknown path is R1; an empty change is
R0; pacing on, under and over the line; the five-hour pause; opus cap; explore
lanes receive only R0; unavailable and cooled-down lanes get no work; `--seed`
makes assignment reproducible; ledgers survive a re-run of `collect`.

## Calls made for the owner

- Quota-log pacing started linear in time. The owner may sleep but agents do
  not, so the line now follows an hour-of-week curve learned from the quota
  history (JDW-195), falling back to linear when the history is thin.
- Free lanes top out at R1 until the scoreboard earns them R2.
- Ledgers are local state first; mirroring them into the metrics store is a
  follow-up so the existing store checks are not changed in this step.
- The classifier is conservative: it will over-ask on R3 at first, and each
  false positive is a rule to tune, not a reason to loosen the tier.
