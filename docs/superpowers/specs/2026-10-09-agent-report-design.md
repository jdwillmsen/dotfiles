# Agent report: periodic reports from the metrics store

Date: 2026-10-09. Piece 2 of 5 of the workflow audit loop (reports, flags and
delivery metrics; notifications and the trends page come later).

## Goal

Turn the store into a report per window that shows spend and behaviour split
by population, flags the days that went wrong, measures what shipped, and
suggests changes, without sending any prompt or transcript text anywhere.
Usage is in `docs/agent-report.md`.

## Decisions taken from the brief

- One stdlib file, `agent-report`, loading `agent-metrics` as a library for
  the store, lock, publish, budget gate and TOON output.
- All windows in UTC, end exclusive, `label_date` the last day inside.
  Biweekly uses `agent-audit`'s fixed fortnight grid.
- Scripted and interactive are separate everywhere; there is no blended total.
- Flags are deterministic, from `thresholds.json`, and daily only.
  `flags.json` has the exact shape other tools read.
- One model call, for weekly and monthly only, behind the budget gate; the
  actual cost goes to the ledger the way `budget record` writes it.
- Failed sections are `errored` with a reason; unknown counts are null.
- Jira is retired from the old audit by changing only its unit's `ExecStart`.

## Decisions the brief left open

- **The `end` field** is exclusive, matching `agent-audit`; `label_date`
  gives the inclusive last day. The previous window's dates live inside
  `previous`, because the top-level key set is fixed.
- **Multi-level flags emit one flag per metric and session.** A session above
  the runaway cost emits only the critical flag, not a warn as well. Runaway
  calls is its own flag, so a session can raise cost and calls flags together.
  Flag ids end in the session id so the monthly review can count them.
- **No spend flag without a baseline.** A trailing week with no spend gives no
  average to multiply, so none is raised.
- **Delivery covers the current window only.** Previous-window GitHub numbers
  would double the request count; trends come from stored reports.
- **`--no-github` skips GitHub but not no-mistakes**, which is a local
  read-only query. The brief tied delivery to GitHub only loosely.
- **First-pass rate excludes runs still going** from its denominator; they
  are reported as `in_progress`. The brief said "over all runs", but a run
  that has not finished cannot have passed first time, and counting it would
  understate the rate until it ends.
- **Follow-up eligibility.** A PR counts in a follow-up rate only once it has
  been merged for that many days, so a recent window shows a null or small
  14-day denominator instead of a falsely low rate. A PR whose files are all
  lockfiles or Markdown has no files to overlap and is not counted.
- **Open-to-merge** runs from PR creation to merge; draft time is included.
- **"Failed-check commit"** is any commit whose combined status is `FAILURE`
  or `ERROR`; "red head" is the same for the last commit. A PR over 100
  commits or files is measured on the first 100 and counted as incomplete.
- **Credential variables are all removed** from the model call's environment
  (the audit kept the model's own auth variables). The box logs in through
  `~/.claude/.credentials.json`, which still works; an environment-only login
  would show up as a recorded insights error.
- **Audit inventory strings are scrubbed.** Hook names in the audit JSON can
  be fragments of injected text, so only identifier-shaped strings (and `~/`
  paths) survive; the rest become `_invalid`, and `unattributed: ...` becomes
  `unattributed`.
- **Thresholds review for budget keys** uses each daily report's stored
  budget state (`plan_pct`: critical-only or stopped; `hard_pct`: stopped;
  `weekly_quota_cutoff_pct`: quota-hold), recorded when the report was made.
  It sits in the monthly `current.thresholds_review`.
- **Re-runs re-spend** on insights. Overwriting is the contract, so a second
  weekly run asks the model again; `--no-insights` avoids it.
- **A stored report that cannot be read** while building the trend or the
  thresholds review stops the run with exit 2 naming the file.

## Not covered

- Notifications and the trends page.
- Previous-window delivery deltas.
- The model call has no retry; one failure leaves that report without
  commentary until it is re-run.
