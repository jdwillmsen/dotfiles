# merge-captain

Classifies open pull requests by risk, has the lane `agent-pace` picks review
them where the tier needs it, and rebase-merges what passes the repository's own
gates. R3 is never merged; it is labelled `needs-human` and left for the owner.
Design: `docs/superpowers/specs/2026-10-23-merge-captain-design.md`.

## What a run does

`merge-captain.timer` fires every 15 minutes and runs `merge-captain run`. For
each open pull request in a configured repository, in order, and ending at the
first step that fails:

1. Skip drafts, `hold` / `no-agent-merge` labels, authors outside the allow-list,
   a base that is not the default branch, and anything past a cap.
2. Classify with `change-class`; a failed classification skips the PR.
3. `live` repos only: create and set the `risk/Rn` and `tag/*` labels.
4. Above the repo's `max_tier` (R3 always): `needs-human` label plus one comment
   per head commit.
5. Gates on the current head: mergeable and clean, checks green (none pending),
   no changes requested, no unresolved threads, no open code-scanning alerts, not
   updated in the last 2 minutes.
6. R1 and up: a review comment for this exact head from this tool's own identity,
   or a fresh headless review (see below). Findings of severity high or medium
   turn an approval into `changes`.
7. `gh pr merge --rebase --match-head-commit <sha>`. Never `--admin`, never another
   merge style, never `--delete-branch`.

A review that times out, exits non-zero or cannot be parsed is never an approval:
the next lane gets one try, then the PR waits as `review-unavailable`.

## Config

`~/.config/agents/merge-captain.toml` (source `home/dot_config/agents/merge-captain.toml`).
`[limits]` holds the caps (PRs per run, reviews per run, merges per hour, review
timeout, largest diff read). `[authors] allow` lists the logins it will touch; a
`[bot]` entry matches only a bot account. Each `[[repo]]` has `mode`
(`live`, `dry-run`, `off`) and `max_tier` (`R0`..`R2`). A repo not listed is ignored.
A malformed file stops the run with an error, never a default.

## Kill switch

```
merge-captain pause --reason "release freeze"   # creates ~/.local/state/merge-captain/PAUSED
merge-captain resume
```

While it exists a run makes no GitHub call at all, and a run already in flight
re-checks it before every write and before starting a review. `status` shows it.

## Flipping a repo to live

1. Read its dry-run decisions for a few days (below); the table should match what
   you would have done by hand.
2. Change `mode = "dry-run"` to `"live"` in the chezmoi source file, keep
   `max_tier` at `R2` unless you want it stricter, and `chezmoi apply`.
3. Try one pull request first: `merge-captain explain O/R#N`, then
   `merge-captain run --repo O/R --pr N`.

Flipping back is the same edit; the next run obeys it.

## Reading the log

`~/.local/state/merge-captain/log.jsonl`: one line per decision with `at, run,
repo, pr, head, tier, action, reason, mode, lane`, plus one `action: run` line per
run. It never holds diff text, comment bodies or credentials.

```
tail -n 20 ~/.local/state/merge-captain/log.jsonl
merge-captain status          # caps used this hour, last five runs, paused?
merge-captain explain O/R#N   # what a run would do for one PR, no side effects
journalctl --user -u merge-captain -n 50
```

Actions: `merged`, `would-merge` (dry-run), `waiting` (try again next run),
`blocked` (needs the author or owner), `needs-human`, `skipped`, `error`.
A `waiting` for `quota` or `review-unavailable` costs nothing; `blocked` with
`merge refused:` carries GitHub's own reason, for example a required approval.

## Things to know

- Reviews are `claude -p` (tools off, one turn, empty directory) or `opencode run`
  (tools denied), with the prompt on stdin and a fixed command line. Pull request
  text is data and cannot change what runs.
- A review comment counts only if this tool's identity (`gh api user`) wrote it.
  Run the timer as the account that should author reviews.
- If the repository's ruleset requires an approving review, the merge is refused
  and shows as `blocked`; the captain does not approve its own reviews.
- Each review is an `agent-eval` data point (`class review`), so the scoreboard
  and the daily `agent-eval-collect` timer see them.
