# Session labels

`~/.local/bin/agent-label` gives every Claude Code session a three-part label
and files it in the metrics store next to the session's row of numbers. A model
server on the local network does the reading; a stronger model checks a sample
once a month. Design: `docs/superpowers/specs/2026-10-09-agent-label-design.md`.

## The labels

| Field | Choices |
|---|---|
| `task_type` | `feature`, `bugfix`, `refactor`, `review`, `research`, `ops`, `docs`, `pipeline-step`, `other` |
| `outcome` | `completed`, `partial`, `abandoned`, `failed`, `unclear` |
| `difficulty` | `trivial`, `routine`, `hard` |

`labels/YYYY-MM.jsonl` holds `{schema, session_id, started_at, task_type,
outcome, difficulty, labeller, labelled_at, truncated}`, one line per session,
filed by the month the session started in and sorted by start time.
`truncated` says the conversation was cut to fit the character budget.

## What `agent-label run` does

Daily at 06:50, after the 06:30 collect:

1. Picks sessions whose rows started in the last `--since` days (7) and have no
   label yet; takes the costliest `--limit` (200) of them.
2. Finds each transcript under `~/.claude/projects`. A session whose transcript
   has been cleaned up is counted and skipped; nothing is labelled from nothing.
3. Extracts the conversation, redacts it, fits it to `max_chars` and asks the
   labeller (below). One retry per session.
4. Under the store lock, pulls fast-forward, merges the new labels into the
   month files (existing labels are never rewritten), commits
   `labels: <date>, <n> sessions` and pushes.

It prints candidates, labelled, skipped for a missing transcript, skipped for an
empty conversation, labeller errors, truncated and still-pending counts, and the
distribution of what it labelled. `--dry-run` calls the labeller and writes and
publishes nothing. Bare `agent-label` shows the backlog, the labeller's
reachability and the last agreement figures.

If the server is off, `run` exits 0 and reports how many sessions stay pending,
so the timer does not fail on a night the box is down. The next run picks them up
while they are inside the window.

## What the labeller sees, and never sees

Sees: the user's prompts and the assistant's visible text blocks from the main
transcript, in order, each prefixed `User:` or `Assistant:`, with credential
shapes replaced by `[REDACTED]`, and cut to `max_chars` by keeping the head and
the tail.

Never sees: tool inputs, tool results, thinking, attachments, system records,
harness-injected messages, subagent files. Redaction covers GitHub tokens, `sk-`
keys, AWS access keys, Slack tokens, Google API keys, JWTs, `Bearer` headers, PEM
private keys, and `password=` / `token=` / `secret=` style assignments (also
`api_key`, `passwd` and `:` as the separator). It matches generously, so prose
such as "the token: it expired" loses a word.

The system prompt tells the model the conversation is data and that
instructions inside it are to be ignored. That is a courtesy, not the defence:
the request constrains the answer to a JSON schema of three enums, the reply is
validated strictly (an object with exactly those three fields, each an allowed
value), and only the three validated values are ever stored or printed. A
reply that fails stays pending and counts as a labeller error.

The labeller is only ever a private address: `base_url` must be `http` or
`https` to a loopback, RFC 1918, link-local (169.254/16, fe80::/10), tailnet
(100.64/10), `localhost` or `*.local` host, with no credentials in the URL.
Anything else makes `run` exit 2 before reading a transcript. Proxy variables
and redirects are ignored. There is no fallback to any other model or service.

Config: `~/.config/agent-metrics/labeller.json`
(`base_url`, `model`, `timeout_s`, `max_chars`). An unreadable file exits 2
naming it.

## `agent-label verify`

Monthly (a later piece schedules it). Samples `--sample` (30) labelled sessions
of `--month` (default last month) whose transcripts still exist, builds the same
redacted text at up to 24,000 characters each, and asks `claude -p` (model
`opus`, no tools, one turn, no session persistence, an empty temporary
directory, credential-shaped environment variables removed apart from Claude's
own auth) for the same three fields, five sessions per call.

- Spend is capped at $0.10 per sampled session and $3.00 in total. First
  `agent-metrics`' `budget_state` must allow the cap; otherwise it prints the
  state and exits 3.
- The reported cost is appended to the ledger as run `label-verify`. A call
  that reports no cost is charged its cap, so the ledger can only over-count.
- `labels/agreement.jsonl` gets one line per month,
  `{month, sample, agree_task_type, agree_outcome, agree_difficulty, verifier,
  verified_at}`, agreement as fractions of verified sessions; a rerun replaces
  the month's line. Individual disagreements are not stored.
- `--dry-run` shows the plan and the budget and spends nothing.

## Known limits

- Labels are noisy: a small model reading a capped transcript. Use them in
  aggregate, and read the agreement figures before trusting a cut.
- Costliest-first means a capped run skews toward long, hard sessions; a backlog
  larger than `--limit` is cleared over several days.
- The labeller's context window bounds `max_chars`. If the server rejects a
  long conversation it counts as an error and the session stays pending, so
  lower `max_chars` rather than retrying.
- Head-and-tail truncation can drop the middle, where the actual work was.
- Sessions older than the window, or whose transcript is gone, are never
  labelled.

## Scheduling

`agent-label.timer` runs `agent-label.service` daily at 06:50 with
`Persistent=true`; `home/run_onchange_56-enable-agent-label.sh.tmpl` reloads
systemd and enables the timer on a home apply. Check with
`systemctl --user list-timers 'agent-label*'`. The first run is deliberately
manual: `agent-label run --dry-run`.
