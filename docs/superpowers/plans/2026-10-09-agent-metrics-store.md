# Agent Metrics Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store one row per Claude Code session in a private git repo every day, log the plan quota from the status line, and answer whether a model spend is within budget.

**Architecture:** A single-file, stdlib-only Python CLI, `agent-metrics`, reads transcripts under `~/.claude/projects` and upserts rows into month files in a git clone of the store repo. The Go status line appends quota readings to a local log, which the collector rolls up into the store. Budget state is derived from the store, a ledger in the store and a small config file; nothing in this piece calls a model.

**Tech Stack:** Python 3 standard library, Go (existing `scripts/claude-status`), bash tests with `shellcheck`, systemd user units, chezmoi source layout under `home/`.

**Spec:** `docs/superpowers/specs/2026-10-09-agent-metrics-store-design.md`

## Global Constraints

- Python standard library only; no third-party imports.
- The store holds numbers and identifiers only: no prompts, code, tool output, command text or transcripts.
- Identifier fields are cut to 64 characters and characters outside `[A-Za-z0-9:_.@/-]` are replaced with `_`.
- Rows are JSON with sorted keys, one per line, ordered by `(started_at, session_id)`.
- All timestamps and month boundaries are UTC.
- Every path is overridable by environment variable: `CLAUDE_CONFIG_DIR`, `AGENT_METRICS_STORE`, `AGENT_METRICS_STATE`, `AGENT_METRICS_CONFIG`, plus `AGENT_METRICS_NOW` (ISO time) for tests.
- Exit codes: 0 success, 1 runtime failure, 2 usage or setup error, 3 budget denied.
- stdout is TOON for agents, stderr is logs, following `agent-audit`'s `toon`/`emit`/`usage_error` helpers. Invoke the `axi` skill before writing the CLI surface.
- `agent-audit` is not modified.
- Comments explain why, never what; no ticket ids or URLs in comments.
- Commits carry `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Assisted-by: Claude Code:claude-opus-5-5`.

## Review Focus

1. **A transcript with no timestamped records, or an empty file.** No row is written and the file is counted as skipped; the run does not crash.
2. **Only a subagent file changed inside the `--since` window.** The parent session is still rescanned, so subagent usage that arrives late is not lost.
3. **A store with uncommitted or diverged state.** The run exits 1 before writing rows; it never commits someone else's edits or forces a push.
4. **A malformed `budget.json`, `pricing.json` or ledger line.** `budget check` exits 2 naming the file; it never treats unreadable config as "allowed".
5. **Null or missing usage fields and a very large transcript.** `usage` values of `null` count as zero, and files are streamed line by line so a 200 MB transcript does not load into memory.

Each of these has a test in the task that owns the code.

## File Structure

| File | Responsibility |
|---|---|
| `home/dot_local/bin/executable_agent-metrics` | The CLI: paths, output helpers, row builder, collector, quota roll-up, budget |
| `home/dot_config/agent-metrics/pricing.json` | List prices with `as_of` |
| `home/dot_config/agent-metrics/budget.json` | `plan_pct`, `hard_pct`, `weekly_quota_cutoff_pct` |
| `home/dot_config/agent-metrics/config.json` | `store_remote` |
| `scripts/claude-status/quota.go`, `quota_test.go` | Quota log append with throttle |
| `scripts/claude-status/main.go` | One call to the quota logger |
| `home/dot_config/systemd/user/agent-metrics-collect.{service,timer}` | Daily run |
| `home/run_onchange_53-enable-agent-metrics.sh.tmpl` | Enables the timer on apply |
| `tests/scripts/test_agent_metrics_script.sh` | All CLI behaviour against a fixture home |
| `docs/agent-metrics.md`, `docs/agent-audit.md` | Reference and pointer |

The CLI stays one file, as `agent-audit` is, split into sections in this order: constants and paths, output helpers, pricing, row builder, store, quota, budget, commands, `main`.

---

### Task 1: CLI skeleton, config files and pricing

**Files:**
- Create: `home/dot_local/bin/executable_agent-metrics`, `home/dot_config/agent-metrics/{pricing,budget,config}.json`, `tests/scripts/test_agent_metrics_script.sh`

**Interfaces:**
- Produces: `load_config(name) -> dict` (exits 2 naming the file on missing or invalid JSON); `price_for(model) -> (input, output, cache_read) | None` (longest prefix wins); `cost_of(model, usage) -> float | None` where `usage` has keys `input`, `output`, `cache_read`, `cache_write_5m`, `cache_write_1h`; `now() -> datetime` honouring `AGENT_METRICS_NOW`; `toon(obj)`, `emit(obj)`, `usage_error(msg, help_line)`; `STORE`, `STATE`, `CONFIG`, `CLAUDE_DIR` paths.

- [ ] **Step 1:** Write the test scaffold: fixture home in a temp dir, `fail` helper, exports for the four path variables, a local bare repo cloned to `$AGENT_METRICS_STORE`. First assertions: the script is executable and parses; `agent-metrics --help` exits 0; bare `agent-metrics` exits 0 and prints `store:`; an unknown command exits 2; `pricing.json` equals `agent-audit`'s `PRICING`, `CACHE_W5M` and `CACHE_W1H`, read with `ast.literal_eval` from the script source; a broken `pricing.json` makes `agent-metrics budget` exit 2 naming the file.
- [ ] **Step 2:** Run `bash tests/scripts/test_agent_metrics_script.sh`; expect FAIL on the missing script.
- [ ] **Step 3:** Write the three JSON files. `pricing.json` is `{"as_of": "2026-10-01", "cache_write_5m": 1.25, "cache_write_1h": 2.0, "models": {"<prefix>": [input, output, cache_read], ...}}` with the ten entries from `agent-audit`. `config.json` is `{"store_remote": "git@github.com:jdwillmsen/agent-metrics.git"}`.
- [ ] **Step 4:** Write the skeleton: argparse with subcommands `init`, `collect`, `budget` (`check`, `record`), the helpers above, a home view that reports the store path, whether it exists, and its last commit subject and date.
- [ ] **Step 5:** Run the test; expect PASS. Commit `feat(agent-metrics): add the CLI skeleton, pricing and config`.

### Task 2: Session row builder

**Files:**
- Modify: `home/dot_local/bin/executable_agent-metrics`, `tests/scripts/test_agent_metrics_script.sh`

**Interfaces:**
- Consumes: `cost_of`, `price_for`.
- Produces: `clean_id(s) -> str`; `find_sessions(since_days) -> list[(main_path, [sub_paths])]`, selecting a session when the main file or any subagent file has an mtime inside the window; `build_row(main_path, sub_paths) -> dict | None` returning the schema-1 row or `None` when the files hold no timestamped record.

Row construction rules, beyond the spec table:
- Records of type `user`, `assistant`, `system` and `attachment` supply timestamps; identity fields come from the first such record of the main file.
- Usage is keyed by `message.id`; for each id keep the per-field maximum, and attribute it to `main` or `subagent` by the file that first showed it. `cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens` give the split; when absent, all of `cache_creation_input_tokens` counts as 5 m.
- A prompt is a `user` record with text content that is not meta, not a compaction summary, does not start with `[Request interrupted by user`, and either contains `<command-name>` or does not start with `<`. An interrupt is the `[Request interrupted by user` case.
- `tools` counts `tool_use` blocks by name once per block id; `mcp` counts names of the form `mcp__<server>__<tool>` by server; `skills` counts `Skill` calls by `input.skill`; `subagent_types` counts `Agent`/`Task` calls by `input.subagent_type` (default `general-purpose`); `subagent_runs` is the number of subagent files.
- `commits`, `pushes`, `prs_created` count Bash tool uses whose command matches `\bgit\b[^|;&\n]*\bcommit\b`, `\bgit\b[^|;&\n]*\bpush\b`, `\bgh\s+pr\s+create\b` and whose `tool_result` is not an error.
- `repo` is `<owner>/<repo>` from the first two path parts after `$HOME/projects/` or `$HOME/worktrees/`. `pipeline` is `no-mistakes` under `$HOME/.no-mistakes/`, `agent-audit` when the directory name starts with `agent-audit-insights-`.

- [ ] **Step 1:** Add fixture transcripts written by an inline Python block: (a) an interactive session in `~/projects/acme/app` with two models, one message id split across two records with growing usage, a subagent file contributing its own message, one tool error, one interruption, a successful `git commit`, a failed `gh pr create`, a `pr-link` record, a compaction boundary, a 429 API error, a 400 s gap before a human prompt, a `Skill` call whose name is 100 characters with spaces and a `$`, a prompt containing `ghp_` followed by 36 letters and the sentence `the launch codes are purple`; (b) a scripted `sdk-cli` session under `~/.no-mistakes/worktrees/x`; (c) an empty file; (d) a file whose records have no timestamps; (e) a session with `usage` fields set to `null` and one unpriced model.
- [ ] **Step 2:** Add assertions through a test-only command `agent-metrics row <main_path>` that prints the row as JSON: exact token totals and `cost_usd` for (a) computed by hand in the test, `cache_read_share`, `model_switches == 1`, `tool_errors == 1`, `interrupts == 1`, `commits == 1`, `prs_created == 0`, `pr_links`, `compactions == 1`, `rate_limits == 1`, `wait_human_s == 400`, `population`, `pipeline`, `repo == "acme/app"`; the skill key is 64 characters and matches `^[A-Za-z0-9:_.@/-]+$`; the JSON contains neither `ghp_` nor `purple`; (c) and (d) exit 0 printing `null`; (e) has zero tokens for the null fields and names the model in `unpriced_models`.
- [ ] **Step 3:** Run; expect FAIL on the missing `row` command.
- [ ] **Step 4:** Implement `clean_id`, `find_sessions`, `build_row` and the `row` command, streaming each file line by line.
- [ ] **Step 5:** Run; expect PASS. Commit `feat(agent-metrics): build one row per session from transcripts`.

### Task 3: Collector and store

**Files:**
- Modify: `home/dot_local/bin/executable_agent-metrics`, `tests/scripts/test_agent_metrics_script.sh`

**Interfaces:**
- Consumes: `find_sessions`, `build_row`.
- Produces: `read_month(path) -> dict[session_id, row]`; `write_month(path, rows)`; `upsert(rows) -> (written, unchanged)`; `git(*args, check=True)` running in the store with credential-shaped variables removed from the environment; `cmd_init`, `cmd_collect`; `iter_sessions(start, end) -> iterator[row]` over month files, used by Task 5.

Behaviour: `collect` takes an exclusive `flock` on `<STATE>/collect.lock` (wait up to 10 minutes), exits 2 naming `agent-metrics init` when the store is missing, exits 1 when `git status --porcelain` is non-empty before it starts or when `git pull --ff-only` fails, writes rows, commits `collect: <UTC date>, <n> sessions` when anything changed, and pushes unless `--no-push`. `--dry-run` prints the counts and writes nothing. `init` clones `store_remote` and writes `README.md` with the schema table when the clone has none.

- [ ] **Step 1:** Add assertions: `collect` with no store exits 2; after `init`, `collect --since 30` writes `sessions/<month>.jsonl` with one row per valid fixture session, sorted, pushed to the bare remote; a second run makes no new commit and reports every session unchanged; appending a record to one transcript changes exactly one line; touching only the subagent file causes its parent to be rescanned; a row whose transcript is deleted survives the next run; with an old mtime and `--since 1` the row is untouched; a dirty store exits 1 and leaves the dirty file alone; a remote that rejects the push (bare repo made read-only) exits 1 with the commit present locally; `--dry-run` leaves `git status` clean and the remote unchanged; `grep -r` for `ghp_` and `purple` in the store finds nothing.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement the store functions and both commands.
- [ ] **Step 4:** Run; expect PASS. Commit `feat(agent-metrics): collect session rows into the store repo`.

### Task 4: Quota log and roll-up

**Files:**
- Create: `scripts/claude-status/quota.go`, `scripts/claude-status/quota_test.go`
- Modify: `scripts/claude-status/main.go` (call after decoding the payload), `home/dot_local/bin/executable_agent-metrics`, `tests/scripts/test_agent_metrics_script.sh`

**Interfaces:**
- Produces (Go): `logQuota(p Payload, path string, now time.Time)`, writing `{"at": <unix>, "five_hour_pct": f, "five_hour_resets_at": n, "seven_day_pct": f, "seven_day_resets_at": n}` with absent windows omitted; `quotaLogPath() string` from `AGENT_METRICS_STATE` or `$XDG_STATE_HOME`/`~/.local/state` plus `agent-metrics/quota.jsonl`.
- Produces (Python): `rollup_quota() -> int` (readings added); `latest_quota() -> dict | None`, reading the store first and the local log second and returning the newest.

Go rules: return at once when `p.RateLimits` is nil or both windows are nil; skip when the file's mtime is less than 5 minutes before `now`; create the directory with mode 0700 and the file with 0600; one `Write` call on a file opened with `O_APPEND`; ignore every error.

Python rules: the roll-up keeps the highest-percentage reading per UTC hour, appends only hours not already in `quota/<month>.jsonl`, never rewrites the current hour once stored, and rewrites the local log without entries older than 35 days. Lines that do not parse are skipped.

- [ ] **Step 1:** Write `quota_test.go`: a payload with both windows appends one line with the five fields; a second call 60 s later appends nothing; a call 301 s later appends a second line; a payload with nil rate limits creates no file; a path under a non-directory does not panic.
- [ ] **Step 2:** Run `cd scripts/claude-status && go test ./...`; expect FAIL on undefined `logQuota`.
- [ ] **Step 3:** Implement `quota.go` and add the call in `main`. Run `gofmt -l .`, `go vet ./...`, `go test ./...`; expect clean and PASS.
- [ ] **Step 4:** Add bash assertions: a local log with three readings in one hour and one in the next rolls up to two lines; a re-run adds none; a 40-day-old entry is gone from the local log; a garbage line is skipped; the home view shows the latest weekly percentage.
- [ ] **Step 5:** Implement `rollup_quota`, `latest_quota`, call the roll-up from `collect`, show it in the home view. Run both suites; expect PASS. Commit `feat(agent-metrics): log plan quota from the status line`.

### Task 5: Budget

**Files:**
- Modify: `home/dot_local/bin/executable_agent-metrics`, `tests/scripts/test_agent_metrics_script.sh`

**Interfaces:**
- Consumes: `iter_sessions`, `latest_quota`, `load_config`, `now`.
- Produces: `budget_state(need=0.0, critical=False) -> dict` with keys `state`, `allowed`, `reason`, `base_usd`, `plan_usd`, `hard_usd`, `spent_usd`, `need_usd`, `quota` (`{seven_day_pct, age_s}` or `null`); `cmd_budget`, `cmd_budget_check`, `cmd_budget_record`.

Order of evaluation: invalid config or an unparseable ledger line exits 2; then `no-baseline`; then `quota-hold` (latest weekly reading at or above the cut-off with `seven_day_resets_at` later than `now`); then `stopped`; then `critical-only`; then `ok`. `record` rejects a negative or non-numeric amount with exit 2, appends `{"at", "run", "usd", "critical"}` to `ledger/<month>.jsonl`, and leaves the commit to the next `collect`, which must therefore tolerate ledger changes as its own (the dirty-store check ignores `ledger/`).

- [ ] **Step 1:** Add assertions, each with a constructed store and `AGENT_METRICS_NOW`: base $1,000 gives plan $10 and hard stop $50; `check --need 5` is `ok`, exit 0; with $8 in the ledger, `check --need 5` is `critical-only`, exit 3, and exit 0 with `--critical`; with $48 spent, `check --need 5 --critical` is `stopped`, exit 3; a ledger entry dated last month does not count; sessions older than 30 days do not count toward the base; an empty store is `no-baseline`, exit 3; a weekly reading of 90 with a future reset is `quota-hold`, exit 3; the same reading with a past reset does not hold; no reading at all is `ok` with `quota: null` in the output; `record --usd 2.5 --run weekly` then `budget` shows spent 2.5; `record --usd -1` exits 2; a ledger line of garbage makes `check` exit 2 naming the file; `collect` after `record` commits the ledger.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Implement the budget functions and commands; relax the dirty check for `ledger/`.
- [ ] **Step 4:** Run; expect PASS. Commit `feat(agent-metrics): gate model spend on a floating budget and plan quota`.

### Task 6: Scheduling and documentation

**Files:**
- Create: `home/dot_config/systemd/user/agent-metrics-collect.service`, `agent-metrics-collect.timer`, `home/run_onchange_53-enable-agent-metrics.sh.tmpl`, `docs/agent-metrics.md`
- Modify: `docs/agent-audit.md`, `tests/scripts/test_agent_metrics_script.sh`

- [ ] **Step 1:** Read `agent-audit@.service`, `agent-audit-weekly.timer`, `run_onchange_52-enable-agent-audit.sh.tmpl` and `tests/scripts/test_shell_script_coverage.sh` and mirror their conventions.
- [ ] **Step 2:** Add assertions: the service runs `%h/.local/bin/agent-metrics collect`, sets `PATH`, `NoNewPrivileges=yes`, `PrivateTmp=yes` and a start timeout; the timer has `OnCalendar=*-*-* 06:30:00` and `Persistent=true`; `systemd-analyze verify` passes when the tool is present; the trigger passes `shellcheck`, enables the timer and does not start the service.
- [ ] **Step 3:** Run; expect FAIL. Write the units and trigger. Run; expect PASS.
- [ ] **Step 4:** Write `docs/agent-metrics.md` (what a run does, the row, the budget states, the commands, the quota log, rollout steps, known limits) and add a pointer in `docs/agent-audit.md`.
- [ ] **Step 5:** Run every script test and the Go suite; expect PASS. Commit `feat(agent-metrics): run the collector daily and document the store`.

## After the tasks

- Run the collector against the real transcripts with `--dry-run --since 30` and compare the totals with the last `agent-audit` report.
- Request a review of the whole branch from a fresh reviewer on the most capable model before opening the PR.
