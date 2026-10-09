# Agent report

`~/.local/bin/agent-report` turns the [agent-metrics store](agent-metrics.md)
into a report per window: a daily, weekly, biweekly, monthly, quarterly or
yearly JSON file and a Markdown rendering of it, committed back to the store.
It reads numbers and identifiers only; it never reads a prompt or transcript.
The design is in
`docs/superpowers/specs/2026-10-09-agent-report-design.md`.

## What a run does

1. Computes the window and an equal previous one, all in UTC (below).
2. Reads session rows by `started_at`, quota readings and ledger entries for
   both windows, and summarises them per population, `interactive` and
   `scripted`, never blended.
3. Daily only: raises flags from `~/.config/agent-metrics/thresholds.json`.
4. Weekly and longer: measures delivery (GitHub merged PRs, no-mistakes runs).
5. Weekly, biweekly, monthly and quarterly: embeds the audit's config
   inventory when its JSON exists.
6. Weekly and monthly: one capped model call for commentary, after the budget
   gate. Its actual cost goes to the ledger as `report-<window>`.
7. Under the store lock, writes `reports/<label_date>-<window>.json` and
   `.md`, commits them with any ledger entry, and pushes.

A failed push exits 1 with the commit kept. Re-running a window overwrites its
report; with no new data the files are byte-identical (the clock is the only
input that changes) and nothing is committed. A re-run does call the model
again unless `--no-insights` is given.

## Windows

`--end` is the day the run is anchored to (default today, UTC). The window is
the last complete one before it, end exclusive; `label_date` is its last day.

| Window | Covers | Previous |
|---|---|---|
| `daily` | the day before `--end` | the day before that |
| `weekly` | the last full Monday to Sunday | the week before |
| `biweekly` | the last full fortnight on the fixed grid `agent-audit` uses | the fortnight before |
| `monthly`, `quarterly`, `yearly` | the last full calendar month, quarter, year | the one before |

## Commands

```sh
agent-report                                   # recent reports and the store path
agent-report --window daily --dry-run          # preview; writes to a temp dir
agent-report --window weekly                   # write, commit and push
agent-report --window weekly --end 2026-10-05  # the week before that Monday
agent-report --window monthly --no-github      # skip GitHub delivery metrics
agent-report --window weekly --no-insights     # no model call
```

`--dry-run` prints the paths of both files in a temp directory. It touches
neither the store, nor `flags.json`, nor the ledger, and makes no model call.
Exit codes: 0 success, 1 runtime failure (including a failed push or a lock
timeout), 2 usage or setup error (an unreadable config, row or report is
named, never read as zero).

## The JSON

Top level: `schema` (1), `window`, `start`, `end` (exclusive), `label_date`,
`generated_at`, `current`, `previous`, `trend`, `flags`, `delivery`, `audit`,
`insights`.

- **`current`, `previous`**: `populations.{interactive,scripted}` each with
  `sessions`, `cost_usd`, `cost_by_pipeline` (`none` for unattributed),
  `models` (calls and cost, main and subagent), `cache_read_share`
  (token-weighted), `friction`, `output` (commits, pushes, PRs created,
  distinct linked PRs), `linked_pr_cost` (cost per linked PR and the share of
  spend it covers), `time` (active, idle, waiting on a human) and `top`
  skills, tools, MCP servers and subagent types. Also `unpriced_models`,
  `quota` (peak five-hour and weekly percentage, reading count) and `ledger`
  (the audit's own spend). `previous` also carries its own `start` and `end`.
  Daily `current` adds `budget`, the budget state when the report was made;
  monthly `current` adds `thresholds_review`.
- **`trend`**: sessions and cost per population for up to six earlier reports
  of the same window, oldest first.
- **`flags`**: see below. Empty for every window but daily.
- **`delivery`**: `{"skipped": "daily window"}`, or `github` and
  `no_mistakes`. A section that failed is `{"errored": true, "reason": ...}`,
  and a skipped one `{"skipped": ...}`; a failure is never shown as zero.
- **`audit`**: the audit report's `hooks`, `disable_candidates` and
  `instructions`, or null when the audit has not written that window's JSON.
  Strings that are not identifiers are replaced by `_invalid`.
- **`insights`**: `{"text", "cost_usd"}`, `{"skipped": "budget", "state": ...}`,
  `{"skipped": "window" | "--no-insights" | "dry-run"}` or `{"error": reason}`.

Dollar figures are list-price estimates, not bills.

## Delivery metrics

GitHub, via batched `gh api graphql` pages, for PRs authored by the logged-in
user and merged in the window across every owner in `~/.config/streams.json`:
merged count, open-to-merge hours (median, p90), lines changed per PR
(median), the share of merged PRs with any failed-check commit and with a red
head commit, and the follow-up fix rate at 7 and 14 days. A follow-up is a
later merged `fix/` or `revert` PR in the same repo touching at least half of
the PR's files, ignoring lockfiles and Markdown. Only PRs merged long enough
ago count in each rate's denominator (`eligible`).

Search returns at most 1000 results and says nothing when it stops, so a range
whose count exceeds that is halved until it fits; a single day over it sets
`truncated`. A run spends at most 60 requests and 300 seconds, spaced against
the 30-a-minute limit. Environment overrides: `AGENT_REPORT_GH_MAX_REQUESTS`,
`AGENT_REPORT_GH_MAX_SECONDS`, `AGENT_REPORT_GH_GAP`, `AGENT_REPORT_GH_PAGE`.

no-mistakes numbers come from `~/.no-mistakes/state.sqlite`, opened read-only
(`AGENT_REPORT_NM_DB` overrides): runs created in the window, the completed,
failed and cancelled split, and the first-pass rate, which is completed runs
with no `auto_fix` round over finished runs. Runs still going are counted
separately and left out of the rate.

## Flags and thresholds

`thresholds.json` (deployed beside `budget.json`) holds the daily thresholds:

| Key | Default | Flag |
|---|---|---|
| `spend_warn_multiple` | 1.5 | `day-spend`, warn: day spend above this multiple of the trailing 7-day daily average |
| `spend_critical_multiple` | 3 | the same flag at critical |
| `session_warn_usd` | 50 | `session-cost:<id>`, warn |
| `runaway_session_usd` | 100 | `runaway-cost:<id>`, critical |
| `runaway_session_calls` | 500 | `runaway-calls:<id>`, critical |
| `weekly_quota_warn_pct` | 85 | `weekly-quota`, warn: peak weekly percentage at or above |

A flag is `{id, severity, metric, message, value, baseline}`; the message is
built only from numbers and store identifiers. No flag is raised for spend
when the trailing week had none, since there is no average to multiply.

The daily run writes `~/.local/state/agent-metrics/flags.json` as
`{"date": "<label_date>", "window": "daily", "flags": [...]}` and removes it
when there are none. Other tools read that file.

The monthly report ends with a thresholds review: every threshold in
`thresholds.json` and `budget.json` with how often it fired, counted from the
month's stored daily reports (budget thresholds from each report's budget
state). With no daily report in the month the count is null, not zero.

## Insights

One `claude -p` call: model sonnet, no tools, one turn, at most $0.50, a
240-second timeout (`AGENT_REPORT_INSIGHTS_TIMEOUT`), JSON output, no persisted
session, run in an empty temp directory with credential-shaped environment
variables removed, so claude must be logged in by itself. The prompt forbids
reporting hours saved or any other self-estimated time saving. It runs only
for weekly and monthly reports, and only if `agent-metrics budget check`
would allow $0.50. A failure or timeout is recorded and the run goes on.

## Scheduling

`agent-report@.service` (the window is the instance) and six timers live in
`home/dot_config/systemd/user/`; `run_onchange_54-enable-agent-report.sh.tmpl`
enables the timers on a home apply without running a report.

| Timer | Fires |
|---|---|
| daily | every day 07:00 |
| weekly | Monday 08:40 |
| biweekly | every Monday 08:50 (the tool picks the last complete fortnight) |
| monthly | the 1st, 09:10 |
| quarterly | 1 Jan, Apr, Jul, Oct, 09:20 |
| yearly | 1 Jan, 09:30 |

All are `Persistent=true`. They sit after the 06:30 collect and the audit
timers. Like the others they need linger to run without a login session.

```sh
systemctl --user list-timers 'agent-report-*'
journalctl --user -u 'agent-report@*' -n 50
```
