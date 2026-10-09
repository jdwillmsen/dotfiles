# agent-label design note

Builds on the metrics store (`2026-10-09-agent-metrics-store-design.md`) and
its privacy rule: nothing free-form reaches the store. Labels are three
validated enum values per session; the free-text reasoning behind them is never
requested.

## Decisions

- Conversation text is the only input. Tool inputs and results, thinking,
  attachments, system and meta records, compaction summaries, synthetic API
  errors and subagent files are excluded because that is where code and
  credentials live and the conversation carries the intent.
- Redact the whole text, then truncate. Cutting first could leave half a
  credential that no pattern matches.
- Safety rests on structure, not on the prompt. The prompt says to ignore
  instructions in the data, but the schema constrains the reply, a strict
  validator re-checks it, and only the three values survive.
- Private addresses are checked on the literal host. Bare DNS names are refused
  because DNS can point anywhere; `*.local` and `localhost` are trusted by name.
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
- Claude's own auth variables are kept for the verifier call (as the audit
  does); every other credential-shaped variable is removed.
- `verify --dry-run` spends nothing; `run --dry-run` does call the labeller
  because that costs nothing and shows the real distribution.

## Not decided here

Monthly scheduling of `verify`, and what consumes labels and agreement.
