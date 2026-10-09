# Agent metrics store, daily collector and budget ledger

Date: 2026-10-09. Piece 1 of 5 of the workflow audit loop.

## Where this fits

`agent-audit` reports on agent usage per window and stops at a Jira ticket.
The agreed direction is a loop that changes the workflow: measure every
session, show trends, and open reviewable PRs against this repo. It is built
in five pieces, each with its own spec and plan:

1. **Metrics store, daily collector, budget ledger and quota log** (this spec).
2. Reports for daily, weekly, biweekly, monthly, quarterly and yearly
   windows, notifications, and a trends page served on the tailnet.
3. The PR author: one open PR at a time, one atomic commit per finding,
   gated by free CI checks.
4. Session labelling on the LAN model server, and the provider section.
5. An agent-run task suite for instruction and model-routing changes.

Decisions that bind every piece:

- The store is a private GitHub repo, `jdwillmsen/agent-metrics`. It holds
  numbers and fixed-choice identifiers only: no prompts, code, tool output
  or transcripts.
- The audit's own model spend is planned at 1% of trailing-30-day estimated
  usage and stops at 5%. Model work is also held while the weekly plan quota
  is at or above 85% used.
- Dollar figures are estimates at API list prices. On a subscription they
  are an index of relative consumption, not a bill; the quota percentages
  are the real constraint.
- Scripted sessions (pipeline-launched) and interactive sessions are always
  reported separately. In the 30 days before this spec, 535 of 614 main
  sessions were scripted.
- Jira is not used by this system.

## Goal of this piece

After this piece, one row per Claude Code session lands in the store every
day, the plan quota is logged as a time series, and any later piece can ask
"may I spend $X on a model call?" and get a yes or no with the reason.
Nothing in this piece calls a model.

## Non-goals

- No reports, notifications or trends page (piece 2).
- No session labels (piece 4). Rows carry a schema version so label fields
  can be added without rewriting history.
- No Codex, opencode or Gemini parsing.
- No change to `agent-audit`. It keeps running as it does today; piece 2
  moves its reports onto the store. This also keeps the work independent of
  the open PR that changes where `agent-audit` files its reports.
- No snapshot of instruction-file sizes. `agent-audit` already measures
  them per window, and piece 2 carries that over.

## Components

### 1. `agent-metrics` CLI

`home/dot_local/bin/executable_agent-metrics`: Python 3, standard library
only, one file, following the AXI conventions `agent-audit` already uses
(TOON on stdout, logs on stderr, a home view when run bare, usage errors
that name the fix).

| Command | Does |
|---|---|
| `agent-metrics` | Home view: store path and last commit, sessions collected, last quota reading, budget state |
| `agent-metrics init` | Clones the store repo into place if it is missing |
| `agent-metrics collect [--since DAYS] [--dry-run] [--no-push]` | Builds rows for sessions whose transcripts changed in the last `DAYS` (default 3), upserts them, rolls up the quota log, commits and pushes |
| `agent-metrics budget` | Budget state with the numbers behind it |
| `agent-metrics budget check --need USD [--critical]` | Exit 0 if the spend is allowed, 3 if not; prints the state and reason either way |
| `agent-metrics budget record --usd USD --run NAME [--critical]` | Appends one entry to the ledger |

Paths, all overridable by environment variable so tests run against a
fixture home:

| Path | Purpose |
|---|---|
| `~/.local/share/agent-metrics/store` | Clone of the store repo |
| `~/.local/state/agent-metrics/quota.jsonl` | Local quota log written by the status line |
| `~/.config/agent-metrics/config.json` | Store remote URL |
| `~/.config/agent-metrics/budget.json` | Budget percentages and quota cut-off |
| `~/.config/agent-metrics/pricing.json` | List prices with their as-of date |

### 2. Store layout

```
sessions/YYYY-MM.jsonl   one row per main session, filed by start month
quota/YYYY-MM.jsonl      quota readings rolled up from the local log
ledger/YYYY-MM.jsonl     the audit's own model spend
README.md                schema reference, written by `init` when absent
```

Rows are written with sorted keys, one per line, ordered by
`(started_at, session_id)`, so a re-collect of an unchanged session produces
no diff and a changed session produces a one-line diff.

The collector commits straight to the store's `main`. This is a deliberate
exception to the PR-only rule: the store is machine-written data with no
reviewable change, and a daily PR would be noise. The dotfiles repo keeps
its ruleset.

### 3. Session row (schema 1)

One row per main session, with its subagent transcripts rolled in.

| Group | Field | Source | Exact |
|---|---|---|---|
| Identity | `schema`, `session_id`, `entrypoint`, `cli_version` | record fields | yes |
| | `started_at`, `ended_at` | first and last record timestamp | yes |
| | `population` | `interactive` when the entrypoint is `cli` or `sdk-ts` (T3 Code), otherwise `scripted` | yes |
| | `pipeline` | `no-mistakes` or `agent-audit` when the working directory matches their known roots, else null | yes |
| | `repo` | `owner/repo` when the working directory is under `~/projects` or `~/worktrees`, else null | yes |
| | `cwd_hash` | first 12 hex of SHA-256 of the first working directory | yes |
| Effort | `wall_s` | last minus first timestamp | yes |
| | `active_s` | sum of gaps between consecutive records of 300 s or less | estimate |
| | `idle_s` | sum of gaps over 300 s | estimate |
| | `wait_human_s` | sum of gaps over 300 s that end in a human prompt | estimate, upper bound |
| | `prompts`, `interrupts` | user records | yes; interrupts may undercount |
| Usage | `models` | per model: calls, input, output, cache read, cache write 5 m and 1 h, cost; split into `main` and `subagent` | yes |
| | `cost_usd` | from `models` and the pricing file | estimate |
| | `unpriced_models` | models missing from the pricing file | yes |
| | `subagent_runs`, `subagent_types`, `skills`, `tools`, `mcp` | tool-use blocks | yes |
| Cache | `cache_read_share` | cache read over cache read plus cache write plus input | yes |
| | `model_switches` | changes of model between consecutive main-session calls | yes |
| | `compactions` | compaction boundary records | yes |
| Friction | `tool_errors`, `denials`, `rate_limits`, `api_errors` | result and error records | yes |
| Output | `commits`, `pushes`, `prs_created` | Bash commands that match and did not return an error | yes |
| | `pr_links` | `{repo, number}` from PR-link records | yes |
| Quality | `bad_lines` | transcript lines that did not parse | yes |

Rules that make the row safe to store:

- No field holds free text. Skill names, tool names, MCP server names,
  subagent types and model ids are identifiers. A value with any character
  outside `[A-Za-z0-9:_.@/-]` is stored as `_invalid`, one shaped like a
  common credential as `_redacted`, and the rest are cut to 64 characters,
  so a prompt fragment or token that ended up in one of those fields is
  not stored, even partly.
- `session_id` is the transcript's file name, which is unique per file, not
  the `sessionId` of its first record.
- Token counts are accepted only as whole, non-negative integers; anything
  else counts as zero, so a non-finite number cannot reach a cost.
- Bash commands are matched for `git commit`, `git push` and `gh pr create`
  and counted. The command text is never stored.
- Token usage is counted once per message id across the main and subagent
  files, taking the largest usage seen for that id, because one message is
  split over several records.
- Cost is computed from token usage. Claude Code's own cost record is
  present in only about 60% of sessions, so it is not used.
- A model with no price contributes no cost and is named in
  `unpriced_models`; it is never priced as zero silently.

Known limits, stated in the store README: forked or resumed sessions are
not de-duplicated; a session resumed across days keeps its original start
month; effort level is not recorded because transcripts do not carry it
reliably.

### 4. Collector behaviour

1. Take an exclusive lock so a timer firing during a manual run waits
   instead of racing. Refuse a store with changes outside `sessions/`,
   `quota/` and `ledger/`; uncommitted changes inside them are leftovers of
   a run that died, and this run commits them.
2. `git pull --ff-only` in the store when it has a remote.
3. Find main transcripts where the file or any of its subagent files was
   modified within `--since` days. Stream each line by line.
4. Build rows and upsert by `session_id` into the month file of
   `started_at`. Rows for sessions not rescanned are left untouched, so
   history outlives Claude Code's 90-day transcript cleanup.
5. Roll up the local quota log: append readings not yet in the store,
   keeping at most one reading per hour per window, and drop local entries
   older than 35 days.
6. Commit when anything changed, then push.

`--since 90` is the one-time backfill. The daily default of 3 covers a
missed day without rescanning everything.

Failure handling:

| Failure | Behaviour |
|---|---|
| Store missing | Exit 2 naming `agent-metrics init` |
| Pull fails or is not fast-forward | Exit 1 before writing anything |
| A transcript cannot be read, or building its row fails | Skip it, count it, log the error type, continue |
| A line does not parse | Count in `bad_lines`, continue |
| Push fails | Rows stay committed locally, exit 1; the next run pushes them |

Every exit prints counts: files scanned, sessions written, sessions
unchanged, files skipped, quota readings added, and whether it pushed.

### 5. Quota log

`claude-status` already receives `rate_limits.five_hour` and
`rate_limits.seven_day` on every status-line refresh. It gains one side
effect: when the payload carries rate limits, append one JSON line with the
time, both used percentages and both reset times to the local quota log.

- It writes at most once per 5 minutes, decided by the log file's
  modification time, because the status line refreshes every 10 seconds in
  every open session.
- Each append is a single short write in append mode, so concurrent
  sessions cannot interleave lines.
- Any error is ignored. The status line must never fail or slow down
  because of the log.

Readings exist only while an interactive session is open; that gap is
handled in the budget rules below.

### 6. Budget

`budget.json`, deployed by chezmoi:

```json
{"plan_pct": 1, "hard_pct": 5, "weekly_quota_cutoff_pct": 85}
```

- **Base:** the sum of `cost_usd` over sessions in the store that started
  in the trailing 30 days.
- **Plan** is `plan_pct` of the base and **hard stop** is `hard_pct` of it.
- **Spent** is the sum of ledger entries in the current calendar month.
  Nothing carries over between months.

`budget check --need X` returns one state:

| State | Condition | Exit |
|---|---|---|
| `ok` | spent plus X is within the plan | 0 |
| `critical-only` | over the plan, within the hard stop | 0 with `--critical`, otherwise 3 |
| `stopped` | spent plus X would pass the hard stop | 3 |
| `quota-hold` | the newest reading that carries a weekly percentage is at or above the cut-off, and its reset time is in the future or, when unusable, the reading is under 7 days old | 3 |
| `no-baseline` | the store has no sessions in the trailing 30 days | 3 |

A stored cost or ledger amount that is not a finite, non-negative number
exits 2 naming the file. A missing quota reading does not block: the dollar caps still
apply, and the output says the quota is unknown and how old the last
reading is. Blocking on a missing reading would stop the audit whenever no
interactive session had been open.

`budget record` appends `{at, run, usd, critical}` to the ledger and
commits it with the next collect. Callers record the cost a headless run
reports; the ledger is the only thing later pieces may write to the budget.
`budget.json` is in the set of paths the PR author may never change.

### 7. Pricing

`pricing.json` carries the same per-model list prices as the table in
`agent-audit`, with an `as_of` date. Two tables is a temporary duplication:
a test fails if they disagree, and piece 2 makes `agent-audit` read the
file.

### 8. Scheduling

`agent-metrics-collect.service` and `.timer` in
`home/dot_config/systemd/user/`, daily at 06:30 local time, before the
08:00 audits, with `Persistent=true` and the same hardening as the
`agent-audit` units. A `run_onchange` script enables the timer on apply
and does not start a run.

## Testing

`tests/scripts/test_agent_metrics_script.sh`, in the style of the
`agent-audit` test, against a fixture home and a local bare repo as the
store remote:

- A synthetic main transcript with a subagent produces the expected row:
  usage de-duplicated by message id, cost from the pricing file, cache
  share, model switch, tool error, interruption, commit and PR link.
- A scripted and an interactive session get the right `population`.
- A planted credential and a planted prompt sentence in the fixture appear
  nowhere in the store. An over-long skill name with unsafe characters is
  cut and cleaned.
- A second collect with no changes makes no commit. Changing one transcript
  changes one line.
- A session outside `--since` keeps its existing row.
- Quota roll-up keeps one reading per hour and does not duplicate on
  re-run.
- Each budget state is reached with a constructed store and ledger, with
  the documented exit code.
- A failed push exits 1 with the commit kept; an unparseable line is
  counted, not fatal.
- The pricing file matches the table in `agent-audit`.

`scripts/claude-status/main_test.go` gains cases for the quota log: a
payload with rate limits appends one line, a second call inside 5 minutes
does not, a payload without rate limits writes nothing, and an unwritable
path does not change the rendered output.

## Rollout

1. Create the private repo `jdwillmsen/agent-metrics`.
2. Merge this piece, `chezmoi apply`, run `agent-metrics init`.
3. Run `agent-metrics collect --since 90` once and read the counts.
4. Confirm the timer is listed and the status line is appending quota
   readings.

## Documentation

`docs/agent-metrics.md` describes the store, the row, the budget states and
the commands, and `docs/agent-audit.md` gains a pointer to it.
