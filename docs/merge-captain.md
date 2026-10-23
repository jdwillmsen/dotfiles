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
   a base that is not the default branch, and anything past a cap or the run
   deadline.
2. Classify with `change-class`; a failed classification skips the PR. The head is
   read again afterwards and must be the one the gates evaluated, otherwise the PR
   waits (`head moved during classification`).
3. `live` repos only: create and set the `risk/Rn` and `tag/*` labels.
4. Above the repo's `max_tier` (R3 always): `needs-human` label plus one comment
   per head commit.
5. Gates on the current head: mergeable and clean, every check green (none
   pending, none failing, and at least one reported), no changes requested, no
   unresolved threads, no open code-scanning alerts, not updated in the last
   2 minutes. A failing check blocks whether or not it is required, unless its
   name is under `[checks] ignore`; a PR that reports no checks waits as
   `no-checks` unless its repo sets `allow_no_checks = true`.
6. R1 and up: an `approve` for this repo, PR and exact head, at this tier or
   higher, in the captain's own record (below), or a fresh headless review.
   Findings of severity high or medium turn an approval into `changes`.
7. `gh pr merge --rebase --match-head-commit <sha>`. Never `--admin`, never another
   merge style, never `--delete-branch`.

A review that times out, exits non-zero or cannot be parsed is never an approval:
the next lane gets one try, then the PR waits as `review-unavailable`. A head that
has failed two reviews in the last 6 hours waits as `review-backoff`. These
attempts are recorded in `agent-eval` as `interrupted`, never as an infra
failure, because a failure kind feeds the lane cooldown that all dispatch shares.

## Config

`~/.config/agents/merge-captain.toml` (source `home/dot_config/agents/merge-captain.toml`).
`[limits]` holds the caps: PRs per run (6), reviewer calls per run (2, failed
calls included), merges per hour (6), review timeout (300 s), largest diff read.
A run starts no reviewer call and no new PR after 20 minutes (`deadline`).
`[authors] allow` lists the logins it will touch. gh reports a bot as `app/name` or
`name[bot]`; both are compared as `name[bot]`, so write `jdwlabs-agent-bot[bot]`,
`renovate[bot]`; a name without the suffix matches a person only.
`[checks] ignore` names checks whose failure is tolerated (empty by default).
`[reviewers] providers` lists the providers a review may run on (`claudeAgent`
by default); every lane on another provider is passed to `agent-pace assign` as
`--exclude`, so the captain is never handed a lane it cannot run. If no
other-family lane is left for an R1 review it asks once more with
`--allow-same-family` and the comment says "same-family reviewer". Each
`[[repo]]` has `mode` (`live`, `dry-run`, `off`), `max_tier` (`R0`..`R2`) and
optionally `allow_no_checks`. A repo not listed is ignored. A malformed file
stops the run with an error, never a default.

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
run. It never holds diff text, comment bodies or credentials. At 5 MB it is
renamed to `log.jsonl.1` (one previous file is kept); the hourly caps read both.

Other files in the state directory, all written by the captain only:

- `reviews.jsonl`: `repo, pr, head, tier, verdict, lane, at`, appended with fsync
  after a real review. This is the only thing a merge trusts.
- `attempts.jsonl`: failed review calls, for the 6-hour backoff.
- `human.jsonl`: which `needs-human` comments were posted, so each head gets one.

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

- Reviews are `claude -p` (tools off, one turn, empty directory) with the prompt
  on stdin and a fixed command line. Pull request text is data and cannot change
  what runs. Credential-shaped strings (private key blocks, `ghp_`/`github_pat_`/
  `gho_` tokens, AWS keys, `xox` tokens, `secret|token|password = value`) are
  replaced with `[redacted]` in the title and diff before they reach a model.
- A comment on the pull request proves nothing. The owner's login also authors
  every agent comment, so the captain never reads a review or `needs-human`
  marker back from a PR: an approval exists only as a line in `reviews.jsonl`
  for that repo, PR and head. The comments are for people; model text in them
  has links, images, HTML and mentions stripped. This stops forged or edited
  comments, not a process that can write the state directory as the same user.
- If the repository's ruleset requires an approving review, the merge is refused
  and shows as `blocked`; the captain does not approve its own reviews.
- `opencode` reviewers are off by default. Findings, 2026-10-23: a plain
  `opencode run -m opencode/deepseek-v4.1-flash-free 'Reply OK'` works in a
  terminal-like environment, with a benign `OPENCODE_CONFIG_CONTENT`, and with the
  prompt as the message argument. It fails with "OpenCode's free tier can only be
  used from within OpenCode" as soon as the config turns tools off (the
  `permission`/`tools` lockdown), whether the prompt arrives on stdin or as a
  file, with the environment left as is. `opencode run --help`,
  `opencode agent` and `opencode --help` offer no flag to disable tools, so the
  only working invocation leaves tools on, which is not safe for an untrusted
  diff. Separately, the free tier answers "Free usage limit reached" and retries
  until the timeout when its quota is spent. `[reviewers] providers` can list
  `opencode` once that changes; the key for an `nvidia/...` model is passed only to
  that model, and nothing in a systemd user unit supplies it unless the unit's
  environment does.
- Each review is an `agent-eval` data point (`class review`), so the scoreboard
  and the daily `agent-eval-collect` timer see them.
