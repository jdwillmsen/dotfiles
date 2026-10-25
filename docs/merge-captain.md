# merge-captain

Classifies open pull requests by risk, has the lane `agent-pace` picks review
them where the tier needs it, and rebase-merges what passes the repository's own
gates. R3 is never merged; it is labelled `needs-human` and left for the owner.
Design: `docs/superpowers/specs/2026-10-23-merge-captain-design.md`.

## What a run does

`merge-captain.timer` fires every 15 minutes and runs `merge-captain run`. Every `gh`
call for a repository uses its owner's saved token, or the default `gh` login when
that owner has none (see "Giving the captain its own tokens"); an owner whose token
file is unsafe or expired is skipped or waits before any call is made. Before
anything else a run reads `gh api rate_limit` (free) for each owner; an owner with
under 500 REST or GraphQL calls left is skipped as `skipped` `api-budget` (logged
once), and a run in which every owner is low does nothing. An answer the captain
cannot read (any shape other than the documented one) counts as unknown, not low:
the run goes ahead and logs one line to say so.

Repositories are walked live first, then dry-run, each group starting where the
last run left off (see "Fair rotation"). For each open pull request in a
configured repository, ending at the first step that fails:

1. Skip drafts, `hold` / `no-agent-merge` labels, authors outside the allow-list
   and a base that is not the default branch. This runs on the list data alone,
   before any per-PR call, and costs no cap. Anything past a cap or the run
   deadline waits too (`run-cap`, `dry-cap`, `repo-cap`, `deadline`).
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
   higher, in the captain's own record that the ledgers back (below), or a fresh
   headless review. Findings of severity high or medium turn an approval into
   `changes`. The reviewer is never a lane that wrote the change: the lane comes
   from the commits' `Assisted-by:` and `Co-Authored-By:` trailers (mapped through
   `model` in `lanes.toml`), is passed to `agent-pace assign` as `--implementer`,
   and with any other implementer lane is also excluded. With no usable trailer the
   review runs as before and its comment says "implementer unknown". Trailers are
   whatever the commit author wrote.
7. `gh pr merge --rebase --match-head-commit <sha>`. Never `--admin`, never another
   merge style, never `--delete-branch`.

The review comment is posted before the review is recorded. If it cannot be
posted nothing is recorded and the PR waits as `comment-failed`; if `agent-eval`
refuses the outcome it waits as `ledger-unavailable`. Either way the next run
reviews again.

A review that times out, exits non-zero or cannot be parsed is never an approval:
the next lane gets one try, then the PR waits as `review-unavailable`. A head that
has failed two reviews in the last 6 hours waits as `review-backoff`. These
attempts are recorded in `agent-eval` as `interrupted`, never as an infra
failure, because a failure kind feeds the lane cooldown that all dispatch shares.

## Config

`~/.config/agents/merge-captain.toml` (source `home/dot_config/agents/merge-captain.toml`).
`[limits]` holds the caps: PRs per run (`max_prs_per_run`, 20), dry-run PRs per run
(`max_dry_prs_per_run`, 8), PRs per repository per run (`max_prs_per_repo`, 4, and a
`[[repo]]` may set its own), reviewer calls per run (2, failed calls included),
merges per hour (6), review timeout (300 s), largest diff read. The PR caps count
only pull requests that went through classification, gates, review or merge, so a
draft or a held PR never uses them; the run cap counts live repositories only and
the dry cap dry-run ones, so reporting on dry-run repositories cannot starve live
work. Under `--dry-run` everything is dry and `--max-prs` (default
`max_prs_per_run`) is its one budget.
After 20 minutes a run starts no reviewer call, label write, merge or new PR
(`deadline`; a review that finished is still commented and recorded, and merged
next run). At 25 minutes an alarm ends the run: the running child is killed, the
PR in flight is logged as `waiting` `hard-deadline` (check whether it merged),
the final `run` line is written and the lock is released. `gh` and tool calls time
out at 60 s. `MERGE_CAPTAIN_DEADLINE_S` and `MERGE_CAPTAIN_HARD_DEADLINE_S` override
the two limits for tests.
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

## Giving the captain its own tokens

Until you do this, every `gh` call runs as your own `gh` login, a full-scope token.
GitHub binds a fine-grained token to one resource owner, and the captain works across
three (`jdwillmsen`, a user; `jdwlabs` and `dotablaze-tech`, organizations), so it
gets one token per owner. These steps are yours: the captain, and any agent, never
sees or handles a token.

For each of the three owners:

1. On GitHub: Settings > Developer settings > Personal access tokens > Fine-grained
   tokens > Generate new token.
2. **Resource owner**: that owner (your user for `jdwillmsen`, the organization for
   the others). A token can name only one.
3. **Repository access**: Only select repositories, and pick exactly the repositories
   listed for that owner in `merge-captain.toml` (`merge-captain status` lists them
   under `repos`), whatever their mode.
4. **Expiration**: 90 days.
5. **Repository permissions**, and nothing else (no Administration, no Workflows
   write):
   - Contents: Read and write
   - Pull requests: Read and write
   - Issues: Read and write
   - Metadata: Read
   - Checks: Read
   - Commit statuses: Read
   - Actions: Read
   - Code scanning alerts: Read
6. Generate it. An organization can require an owner to approve a fine-grained token
   before it works; if the organization asks for that, approve it under the
   organization's Settings > Personal access tokens.
7. In a normal terminal **outside any agent session** (a separate SSH login, a tmux
   pane), run `merge-captain auth <owner>` and paste the token at the hidden prompt.
   It must be a terminal: the command refuses to run otherwise. It checks the token
   with GitHub, saves it, and prints only `owner`, `login` and `expires`. If GitHub
   does not report the expiry, add `--expires YYYY-MM-DD`.
8. `merge-captain status` lists each owner as `identity: token` with its login and
   days to expiry. Repeat for the other owners; one owner can be done at a time, and
   an owner without a token keeps using the default login.

Rules the captain enforces:

- Tokens live in `~/.config/merge-captain/tokens/` (`MERGE_CAPTAIN_TOKENS`): the
  directory 0700, one file per owner named by the owner in lower case (`jdwillmsen`,
  `jdwlabs`, `dotablaze-tech`) at 0600, plus `<owner>.meta` with the login and
  expiry. `auth` creates them that way. GitHub owner names are case-insensitive, so
  `auth Acme` saves `acme` and a config owner `Acme` finds it; a hand-made file whose
  name differs only by case is never used, and `status` warns about it by name.
- A token file or directory that is a symlink, belongs to someone else, is
  readable by group or others, or cannot be read as text is **not used and does not
  fall back** (`status` names the reason, never the file's content): that owner's
  repositories show `skipped insecure-token-file` in the run and `status` shows
  `identity: insecure`. Fix the mode (`chmod 700` the directory, `chmod 600` the
  file) or save the token again. A loose directory stops every owner.
- The token is passed to `gh` for that owner's repositories and to nothing else; it
  is never in a log, state file, comment or message.
- `change-class` still reads pull request diffs with the default `gh` login, so keep
  that login signed in for now; it only reads.

Rotating: make a new token for the owner as above, run `merge-captain auth <owner>`
again (it replaces the file), then delete the old token on GitHub. `status` starts
warning 14 days before expiry (`warnings`); at expiry the owner's repositories show
`waiting token-expired` rather than falling back to the default login, so rotate in
time.

Removing: `merge-captain auth <owner> --remove` (also needs a terminal) deletes the
file and its metadata, and refuses when the directory or either file is a symlink;
revoke the token on GitHub as well. The owner then goes back
to the default login. To stop the captain for that owner instead, set its repositories
to `mode = "off"` or `merge-captain pause`.

## Flipping a repo to live

1. Read its dry-run decisions for a few days (below); the table should match what
   you would have done by hand.
2. Change `mode = "dry-run"` to `"live"` in the chezmoi source file, keep
   `max_tier` at `R2` unless you want it stricter, and `chezmoi apply`.
3. Try one pull request first: `merge-captain explain O/R#N`, then
   `merge-captain run --repo O/R --pr N`.

Flipping back is the same edit; the next run obeys it.

## Fair rotation

A cap alone favours whatever comes first in the config, so the walk rotates.
`rotation.json` in the state directory keeps, per group (live, dry-run), the
repository the next run starts at; the walk wraps round the list and the cursor
ends on the first repository that still had work the run could not reach and got
none of it (one stopped by its own `max_prs_per_repo`, or cut short by the run cap
after some of it was served, has had its turn and is passed over; the
repository's cap is checked before the run's, so a repository that used its share
exactly as the run budget ran out is not counted as left behind).
Inside a repository, pull requests are taken least-recently-examined first, from
`examined.json` (`repo#number` to the time the captain last spent a decision on it,
oldest first for PRs it has never seen), so an old PR is not starved by newer ones.
Entries are dropped when a PR closes, when its repository leaves the config, and
past 2000 entries. A time that is not a finite, readable moment drops its entry, and
one dated in the future is read as now, so a damaged or hand-edited file can neither
hide a PR for ever nor stop a run; unreadable or absurdly nested state reads as empty.
`merge-captain run --dry-run`, `--repo` and `--pr` read both
files but never write them, so a manual run does not disturb the schedule.

Pull requests the run did not get to are listed in its output as `skipped` with the
cap that held them and counted in `deferred:`, but are not written to the log; the
final `run` line carries the count. `merge-captain status` shows the cursors
(`rotation`), the per-repository caps (`repo_caps`) and the deferred count of the
last run.

## Reading the log

`~/.local/state/merge-captain/log.jsonl`: one line per decision with `at, run,
repo, pr, head, tier, action, reason, mode, lane`, plus one `action: run` line per
run. It never holds diff text, comment bodies or credentials. At 5 MB it is
renamed to `log.jsonl.1` (one previous file is kept); the hourly caps read both.

Other files in the state directory, all written by the captain only:

- `reviews.jsonl`: `repo, pr, head, tier, verdict, lane, assignment, at`, appended
  with fsync after a real review. This is the only thing a merge trusts, and only
  together with the ledgers (below).
- `attempts.jsonl`: failed review calls, for the 6-hour backoff.
- `human.jsonl`: which `needs-human` comments were posted, so each head gets one.
- `rotation.json` and `examined.json`: the fair-rotation cursors and examination
  times above; each is replaced whole and kept 0600. Deleting either only resets the
  rotation.

```
tail -n 20 ~/.local/state/merge-captain/log.jsonl
merge-captain status          # caps used this hour, last five runs, paused?, each owner's token
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
  comments.
- A line in `reviews.jsonl` is not enough on its own. An `approve` counts only if
  its `assignment` id is in agent-pace's `assignments.jsonl` and the latest
  `outcomes.jsonl` row for that id (agent-eval, under `AGENT_EVAL_STATE`, default
  `~/.local/state/agent-eval`) is a `completed` `review` on the same lane at or
  above the PR's tier, with `source: record`. The files are read directly, not
  through the tools. A missing ledger or any mismatch means the PR is reviewed
  again. A `changes` line blocks regardless, since a forged one only stops a
  merge. The state directory is created 0700 with 0600 files and tightened if it
  was looser.
- `~/.claude/hooks/guard-delivery-state.sh` (a PreToolUse hook on `Write|Edit|MultiEdit|Bash`
  and, as a second entry, `Read|Grep|Glob`, both enforced in `settings.json`) refuses
  Claude Code tool calls that write the captain's state, the agent-eval ledgers or the
  deployed `change-risk.toml`, `lanes.toml` and `merge-captain.toml`: Write/Edit on
  those paths, and shell redirects, `tee`, `sed -i`, `cp`, `mv`, `rm` and similar
  aimed at them. It also refuses Read, Write, Edit, Grep and Glob on the token
  directory (`~/.config/merge-captain`, `MERGE_CAPTAIN_TOKENS`, and `XDG_CONFIG_HOME`
  where set), and any Bash command that mentions the directory in any way (`cat`,
  `cp`, `ls`, `grep`, `tar`, `find`, `echo >` ...), except a plain
  `merge-captain auth` or `merge-captain status`. A line is split at newlines, `;`,
  `&&`, `||`, `|`, `|&` and a lone `&` before each part is judged, so a backgrounded
  `status & cat <token>` is refused; `&>`, `>&` and `2>&1` stay redirects. Paths are
  resolved through symlinks before they are judged, so a link into the token directory
  or the state directory does not hide it.
- The same hook also refuses anything that would search *into* the token directory
  without naming it: a recursive Bash command (`grep -r|-R`, `rg`, `ag`, `fd`, `find`,
  `du`, `tree`, `ls -R`, `cp -r`, `rsync -r`, `zip -r`, `tar` when creating) whose
  target is `~/.config`, the token directory, `~`, a parent of `~` or `/`, whether
  spelled out, as a wildcard that could match one of them (`~/.c*`, `~/.config/*`) or
  implied by running from there with no path (also after a `cd`). Grep and Glob are
  treated the same way: no `path`, or a `path` of `~`, `$HOME` or any parent of the
  token directory, is refused unless the call's `glob` (Grep) or `pattern` (Glob) starts
  with a literal directory that stays inside a project (`projects/**/*.ts`). The
  trade-off is that a Grep or Glob with a bare `*.ts` glob cannot start at `~`; give it
  the project directory instead. Plain `grep -r foo ./src` and a search rooted in any
  project directory are untouched. It reads command text, so it stops accidents and
  prompt-injected shortcuts inside Claude Code only. It does not stop a determined
  process running as the same user (a script, another tool, a variable or command
  substitution that hides the path), and nothing in these files can: a separate unix
  account for the captain, its state and its tokens is the real fix (JDW-209). Pause
  and resume go through `merge-captain pause|resume`, which the hook allows.
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
