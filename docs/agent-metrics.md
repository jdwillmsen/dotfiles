# Agent metrics store

`~/.local/bin/agent-metrics` keeps one row of numbers per Claude Code session
in a private git repo, logs the plan quota as a time series, and answers
whether the audit may spend on a model call. It calls no model itself.

It is the first piece of the workflow audit loop: reports, the PR author and
session labelling all read from this store. The design is in
`docs/superpowers/specs/2026-10-09-agent-metrics-store-design.md`.

## What a run does

`agent-metrics collect` runs daily at 06:30 from a systemd user timer:

1. Takes a lock, so a timer firing during a manual run waits for it.
2. Refuses a store with changes it did not make, then pulls fast-forward
   only.
3. Finds main transcripts under `~/.claude/projects` where the file or any of
   its subagent files changed in the last 3 days (`--since`), and builds one
   row for each.
4. Upserts rows by session id into `sessions/YYYY-MM.jsonl`. A session that
   is not rescanned keeps its row, which is how history outlives Claude
   Code's 90-day transcript cleanup.
5. Folds finished hours of the quota log into `quota/YYYY-MM.jsonl`.
6. Commits when anything changed and pushes.

A failed push exits 1 with the commit kept; the next run delivers it. The
collector commits straight to the store's `main`. That is a deliberate
exception to the PR-only rule: the store is machine-written data with
nothing to review.

## What a row holds

Numbers and identifiers only. No prompt, code, tool output, command text or
transcript reaches the store.

| Group | Fields |
|---|---|
| Identity | `session_id`, `entrypoint`, `cli_version`, `started_at`, `ended_at`, `population`, `pipeline`, `repo`, `cwd_hash` |
| Effort | `wall_s`, `active_s`, `idle_s`, `wait_human_s`, `prompts`, `interrupts` |
| Usage | `models` (per model, split into `main` and `subagent`), `cost_usd`, `unpriced_models`, `subagent_runs`, `subagent_types`, `skills`, `tools`, `mcp` |
| Cache | `cache_read_share`, `model_switches`, `compactions` |
| Friction | `tool_errors`, `denials`, `rate_limits`, `api_errors` |
| Output | `commits`, `pushes`, `prs_created`, `pr_links` |
| Quality | `bad_lines` |

Reading the numbers:

- **`population`** is `interactive` for sessions started from the terminal
  or T3 Code (entrypoints `cli` and `sdk-ts`) and `scripted` for everything
  a pipeline launched. Most sessions are
  scripted, so averages across both mean little; always split them.
- **`cost_usd`** is an estimate at the list prices in
  `~/.config/agent-metrics/pricing.json`. On a subscription it is an index
  of relative use, not a bill. A model missing from the file is named in
  `unpriced_models` and left out of the total.
- **`active_s`** sums gaps of five minutes or less between records;
  **`idle_s`** sums the longer ones. **`wait_human_s`** is the idle time that
  ended in a prompt. It includes sessions left open overnight, so it is an
  upper bound.
- **`interrupts`** matches one message format and probably undercounts.
- **Identifier fields** (skill, tool, MCP server, subagent type, model) are
  cut to 64 characters and stripped of anything outside
  `[A-Za-z0-9:_.@/-]`.
- **Not handled:** forked or resumed sessions are not de-duplicated, and a
  session resumed across months stays in the month it started.

## Quota log

The dollar figures cannot say how close the plan is to its limit. The status
line can: Claude Code hands `claude-status` the five-hour and seven-day used
percentages on every refresh, and it appends them to
`~/.local/state/agent-metrics/quota.jsonl` at most once every five minutes.
Readings exist only while an interactive session is open.

## Budget

The audit's own model spend is capped by `~/.config/agent-metrics/budget.json`:

| Key | Default | Meaning |
|---|---|---|
| `plan_pct` | 1 | Planned spend, as a share of the trailing 30 days of estimated usage |
| `hard_pct` | 5 | Hard stop, same base |
| `weekly_quota_cutoff_pct` | 85 | Hold model work while the weekly plan quota is at or above this |

The base floats, so the allowance shrinks as usage does. Spend is counted
per calendar month from `ledger/YYYY-MM.jsonl` and never carries over.

| State | Meaning | `budget check` exit |
|---|---|---|
| `ok` | Within the plan | 0 |
| `critical-only` | Over the plan, within the hard stop | 0 with `--critical`, else 3 |
| `stopped` | Would pass the hard stop | 3 |
| `quota-hold` | Weekly quota at or above the cut-off and not yet reset | 3 |
| `no-baseline` | No priced sessions in the last 30 days | 3 |

An unknown quota does not block, because readings stop when no interactive
session is open; the dollar caps still apply and the output says the quota is
unknown. A ledger or config file that cannot be read exits 2: it is never
treated as an allowance.

Anything that spends on a model runs `budget check` first and
`budget record` after. `budget.json` is not for agents to edit.

## Running it by hand

```sh
agent-metrics                               # store, last commit, latest quota
agent-metrics collect --dry-run             # counts only; writes nothing
agent-metrics collect --since 90            # one-time backfill
agent-metrics budget                        # state and the numbers behind it
agent-metrics budget check --need 5         # exit 0 when $5 may be spent
agent-metrics budget record --usd 3.2 --run weekly
agent-metrics row <transcript.jsonl>        # the row one transcript produces
```

Exit codes: 0 success, 1 runtime failure, 2 usage or setup error, 3 budget
denied.

## First-time setup

```sh
gh repo create jdwillmsen/agent-metrics --private
agent-metrics init
agent-metrics collect --since 90
```

`init` clones the repo named in `~/.config/agent-metrics/config.json` to
`~/.local/share/agent-metrics/store`. Until it has run, the daily timer fails
with a message naming it.

## Scheduling

`agent-metrics-collect.service` and `.timer` live in
`home/dot_config/systemd/user/`, and
`run_onchange_53-enable-agent-metrics.sh.tmpl` enables the timer on a home
apply without starting a run. Like the audit timers, it needs linger to run
without a login session.

```sh
systemctl --user list-timers 'agent-metrics-*'
journalctl --user -u agent-metrics-collect -n 50
```
