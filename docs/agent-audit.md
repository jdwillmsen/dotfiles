# Agent usage audit

`~/.local/bin/agent-audit` measures how the coding agents on this box are
used: what they cost, which plugins, skills and MCP servers earn their place,
how big the always-loaded instruction files have grown, and whether PRs and
commits follow the attribution rules. It runs on systemd user timers and files
each report as a Jira task, so the trend is reviewed rather than just
collected.

## What a run does

1. Streams every Claude Code transcript under `~/.claude/projects` touched
   since the start of the *previous* window (files older than that are skipped
   by mtime) and attributes each record by its own timestamp to the current
   or previous window.
2. Reads `~/.claude/settings.json`, the installed plugins' manifests (skills,
   commands, agents, hooks, `.mcp.json`) and `~/.claude.json` to know what is
   enabled, so it can list what went unused.
3. Measures the instruction files and the sets each agent loads together.
4. Searches GitHub (`gh search prs` and `gh search commits`) across the
   `jdwillmsen` and `jdwlabs` owners for PR body length, "Generated with"
   footers, and AI-co-authored default-branch commits missing an
   `Assisted-by:` trailer. GitHub search returns at most 1000 results and
   does not say when it stops. A one-request count therefore comes first. Any
   range over 1000 is halved, on counts alone, until every piece fits, and
   only then fetched. If a single day is still over 1000, the report marks the
   counts as truncated. Search allows 30 requests a minute, and `gh` spends
   one request per 100 results, so requests are spaced per page. If GitHub
   still answers 403/429, the run waits for the search reset, up to 5 minutes
   in total. A section that still fails is marked **Errored** and is never
   shown as zero. A real quarterly dry run took 5 minutes.
5. Makes **one** `claude -p` call (Sonnet, no tools, `--max-turns 1`,
   `--max-budget-usd 0.50`, 240 s timeout, no session persistence) that reads
   the metrics JSON and returns at most 250 words of trends, anomalies and
   suggested cuts. A failure or timeout is recorded in the report and the run
   carries on.
6. Writes `~/.local/share/agent-audit/reports/<date>-<window>.md` and the
   matching `.json`, then creates a Jira Task in `JDWLABS` labelled
   `agent-audit`, parented under the epic "Agent tooling usage audits". The
   epic is looked up (or created) once, and its key is kept in
   `~/.local/share/agent-audit/epic-key`.

`<date>` is the last day inside the window. A window that already has a Jira
key in its JSON is a no-op on re-run, and `--force` files it again. Runs of
the same window take a lock. A second run waits up to 10 minutes for the first
to finish, then checks again, so a timer firing during a manual run ends as a
no-op instead of a duplicate. A Jira create that times out is never sent
again. Jira search can lag behind a create, so the script looks for the issue
by summary for about a minute, with growing waits between tries. If the issue
still does not appear, the run stops with the report saved and marked
pending. The next run then searches for the issue before it creates one. A `--no-insights` retry keeps the commentary already saved in
the stored JSON.

## Windows

| Window | Covers | Previous | Timer |
|---|---|---|---|
| `weekly` | last full Mon–Sun week | the week before | Mon 08:00 |
| `biweekly` | last full fortnight on a fixed grid | the fortnight before | Mon 08:15 |
| `monthly` | last full calendar month | the month before | 1st, 08:30 |
| `quarterly` | last full calendar quarter | the quarter before | 1 Jan/Apr/Jul/Oct, 09:00 |

Times are the box's local time, which is UTC on the devbox. Windows snap to
Mondays, month starts and quarter starts. A run that `Persistent=true` catches
up late therefore audits the same window the missed run would have.

Fortnights are counted every two weeks from Monday 1970-01-05, not by ISO week
parity, because a 53-week year such as 2026 puts two odd weeks back to back
and parity would skip a fortnight. `OnCalendar` has no "every other week", so
the biweekly timer fires every Monday. A run in the off week, regular or
catch-up, targets the most recent complete fortnight. That fortnight is a
no-op if it was already filed, and is audited if the run that should have
filed it was missed.

## Previous-window data and history

Claude Code deletes transcripts after `cleanupPeriodDays` (90 here). A
quarterly run's previous window reaches back six months, past that limit. Each
run therefore saves its metrics JSON, and when a stored run covers exactly the
previous window, its numbers are used instead of the partly deleted
transcripts. The report says which source it used. The JSON history also feeds
the trend line (up to six earlier runs of the same window).

## Reading the numbers

- **Cost** is an estimate at API list prices from the `PRICING` table at the
  top of the script, which carries a date. It is not a bill. Update the table
  when prices change. A model missing from it is listed under "Unpriced
  models" and left out of the total.
- **Output split**: the visible text and tool-call JSON are measured in
  characters and divided by 4. Transcripts store thinking blocks empty, so
  thinking shows up only as the remainder of `output_tokens`.
- **Hooks**: injected bytes are attributed to a plugin by matching the hook
  command (or its `statusMessage`) against the plugin manifests. Some context
  arrives with no hook record that names its source, such as caveman's
  per-prompt reminder. That context is listed as `unattributed:` followed by
  its first 40 characters.
- **Disable candidates** count *invoked* use only: Skill calls, slash commands,
  subagent types and MCP calls. If a plugin shows only hooks there, it
  injected context but nobody ever invoked it. That is the main thing to look
  for.

## Running it by hand

```sh
agent-audit                                        # recent reports, epic key
agent-audit --window weekly --dry-run --no-jira    # preview; writes to a temp dir only
agent-audit --window monthly --no-insights         # write and file, skip the model call
agent-audit --window quarterly --end 2026-10-01    # audit the quarter ending before that date
```

`--dry-run` puts the report, the JSON and the Jira payload it would have sent
(`jira-payload.json`) in a temp dir and makes no Jira calls.

## Jira credentials

The script reads `JIRA_URL`, `JIRA_USERNAME` and `JIRA_API_TOKEN` from the
environment. When they are unset, it reads them from the `ai-sre-relay`
secret in the `ai-sre` namespace through `kubectl`, at runtime. The
credentials stay in process memory: they are never printed or written to
disk. Child processes (`gh`, `kubectl`, `claude`) get an environment with
`JIRA_*` and any other credential-like variable removed. Each keeps only its
own auth variable. The credentials authenticate as the owner's own Jira
account, not a bot.

## Scheduling and linger

The units are `agent-audit@.service` (a template, `%i` is the window) and
`agent-audit-{weekly,biweekly,monthly,quarterly}.timer` in
`home/dot_config/systemd/user/`. `run_onchange_52-enable-agent-audit.sh.tmpl`
reloads systemd and enables the four timers on a home apply. It does not start
an audit, because every run files a ticket. The first report arrives at the
next calendar slot.

Timers run without a login session only when linger is on. Check it with
`loginctl show-user "$USER" -p Linger`. If it says `no`, run the root step
once from a human terminal:

```sh
sudo scripts/provision-persistence.sh
```

Inspect the timers with:

```sh
systemctl --user list-timers 'agent-audit-*'
journalctl --user -u 'agent-audit@*' -n 50
```

## Caps

Each run makes at most one model call, capped by turns, dollars and wall
time. The service's `TimeoutStartSec=20min` bounds the whole run, and it runs
with `NoNewPrivileges=yes` and `PrivateTmp=yes`. The only repetition is
bounded: the GitHub range split stops at single days, and a timed-out Jira
create is never re-sent; the run only polls search for it. The weekly scan of about 600 transcript files took
under 30 s on the devbox, most of it in the GitHub searches.
