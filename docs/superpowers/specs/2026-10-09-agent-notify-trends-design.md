# agent-notify and agent-trends

Date: 2026-10-09. Part of piece 2 of the workflow audit loop; consumes the
flags and reports `agent-report` writes.

## Contract consumed

`<state>/flags.json` (only after a daily report with flags) and
`reports/<date>-<window>.json` in the store. Every key under `current`,
`delivery` and `audit` is treated as optional.

## Decisions

- **Acknowledgement is per date**, in `acked.json` as a date list. A new day
  raises the marker again; an old acknowledgement never hides it.
- **Shell nudge is two-stage.** The rc file stats `flags.json` in shell
  before starting Python, and `agent-notify shell` answers without loading
  `agent-metrics` or touching network or git (about 20 ms when it prints).
  It lives in `functions.sh`, which both rc files already source.
- **At most one comment per date.** `send` takes a lock around check,
  comment and record, records the date first, rolls it back on a definite
  `gh` failure and keeps it on a timeout (loud exit 1, `--force` to repost).
  A crash between record and post loses that day's comment rather than
  risking a duplicate.
- **Issue memory** is `{repo, number}` in `notify-issue`; another repo's value
  is ignored. A closed or deleted remembered issue is replaced once, on a
  failed comment, through search-or-create.
- **State files are untrusted**: opened non-blocking and read only if they
  are small regular files, so a FIFO or device cannot hang or flood a shell.
- **Repo derivation** accepts GitHub SSH and HTTPS remotes only; any other
  remote exits 2 unless `AGENT_NOTIFY_REPO` is set. The brief did not say.
- **`gh` runs with the full environment**, not `agent-metrics`'s
  credential-stripped one, because `gh` may authenticate through a token
  variable. Comments go through stdin, not argv.
- **Flag text is untrusted.** Ids are identifier-only (else `_invalid`),
  messages drop control, format and separator characters, and every value
  in the comment is inline code with backticks removed. The report location
  is a plain path, not a link.
- **Status line**: the marker joins line 2, or line 1 when line 2 is empty,
  so it never adds a line. In the compact layout it is `⚑N` placed last and
  is the first thing dropped for width. A malformed or oversized file, or a
  malformed ack file, means no marker (and an unreadable ack shows the flag
  rather than hiding it).
- **Trends reads strictly.** A bad line in sessions, quota or reports, or a
  non-numeric cost, fails the build with exit 2 naming the file; the
  collector's lenient reader is not used because a skipped line is an
  undercount.
- **Windows.** Tiles use rolling 7-day windows ending at the generation
  time; charts bucket by UTC date and Monday-start week, with the current day
  and week partial. Cost per linked PR is spend over distinct
  `(repo, number)` pairs linked in the window.
- **Quota chart** shows each day's highest reading, not hourly points, to keep
  90 days legible.
- **Rates in reports are fractions** (0.25 is 25%), as in the store's
  `cache_read_share`; the brief did not state the unit.
- **Population** values other than `interactive` count as `scripted`.
- **Page content is limited to numbers, dates, model ids, repo, pipeline and
  flag ids.** Flag messages are free text and stay out of the page; they are
  in the daily report and the issue. A model-id, repo and pipeline table was
  added so those identifiers have a place.
- **Colours** are the validated reference palette, categorical slots 1 to 4
  in fixed order (validated light and dark); model family and population keep
  one colour each. Every chart has a legend, hover details and a data table,
  which discharges the low-contrast relief rule for aqua and yellow.
- **Publishing** pulls fast-forward only, then builds and pushes under the
  collector's lock, staging only `site/` through `publish(dirs=...)`.
- **`--days` is 1 to 180** so daily bars keep a width; the 30-day tables load
  their own history regardless of the range.
- **Serving is not part of this change.** The owner runs `tailscale serve`
  (see `agent-trends.md`).
- One trigger, `run_onchange_55-enable-agent-notify.sh.tmpl`, enables both
  timers, ordered 07:00 report, 07:20 notify, 07:30 trends.
