# agent-label design note

Builds on the metrics store (`2026-10-09-agent-metrics-store-design.md`) and
its privacy rule: nothing free-form reaches the store. Labels are three
validated enum values per session; the free-text reasoning behind them is never
requested.

## Decisions

- Conversation text is the only input. Tool inputs and results, thinking,
  attachments, system and meta records, compaction summaries, synthetic API
  errors and subagent files are excluded because that is where code and
  credentials live and the conversation carries the intent. The harness also
  writes user text for task notifications, shell output and reminders; a user
  text counts as a prompt only if it does not open with `<` (the metrics row
  builder's rule), and a slash command is sent as name plus arguments, never
  its expanded body.
- Redact, then truncate to the budget. Cutting first could leave half a
  credential that no pattern matches. The one earlier cut, at ten times the
  budget, only bounds the work: it falls on whitespace and each side is
  redacted alone. Unbroken runs of 120+ token characters are replaced before
  the patterns run, which keeps every pattern's leading class linear.
- Safety rests on structure, not on the prompt. The prompt says to ignore
  instructions in the data, but the schema constrains the reply, a strict
  validator re-checks it, and only the three values survive.
- Private addresses are checked on the literal host. Names are refused
  because DNS can point anywhere, `.local` ones included on this box; only
  `localhost` is trusted by name.
  Proxies and redirects are disabled so the check holds for the connection made.
- Unreachable means a refused or failed connection, or two sessions in a row
  timing out. The first ends the run at once; a single timeout is treated as one
  slow or oversized conversation. Either way `run` exits 0 with the pending count.
  An HTTP error status is a labeller error for that session, not a down server.
- A session with no readable conversation text is skipped and counted
  separately (`skipped_empty`); it stays pending.
- Existing labels are never rewritten; a second writer's label for the same
  session loses to the one already stored.
- Labels are not de-duplicated across a pull: the store is pulled fast-forward
  under the lock just before writing, so a long labelling pass never holds the
  lock.
- `verify` defaults to last month, batches five sessions per call at 24,000
  characters each to bound cost, and sizes its cap at $0.10 per sampled session
  up to $3.00. The model replies with a JSON array keyed by position, not by
  session id, so the verifier never echoes identifiers. A fenced array is
  accepted; any other wrapping is not. Items are validated one by one and bad
  ones are dropped, so one malformed item does not void a batch.
- Agreement is computed over verified sessions only, and written only when at
  least one verdict was usable. A call that reports no cost is charged at its cap.
- The verifier gets an allowlisted environment (PATH, HOME, locale, terminal,
  `CLAUDE_CONFIG_DIR`); Claude logs in from its credentials file, confirmed with
  one real call.
- Output is written in batches of 20 labels with a 20-minute clock, so a run
  killed anywhere keeps what was answered. Repeated HTTP client errors stop the
  run and fail it.
- `verify` records each call's cost at once and without the store lock.
- `verify --dry-run` spends nothing; `run --dry-run` does call the labeller
  because that costs nothing and shows the real distribution.

## Not decided here

Monthly scheduling of `verify`, and what consumes labels and agreement.
