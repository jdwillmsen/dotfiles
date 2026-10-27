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
7. Where the ruleset wants one approving review and everything above is met, the
   approver step (below) submits it as the App on this exact head.
8. `gh pr merge --rebase --match-head-commit <sha>`. Never `--admin`, never another
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
merges per hour (6), approvals per hour (4), review timeout (300 s), largest diff read. The PR caps count
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
optionally `allow_no_checks`, `require_token` and `approver` (booleans, default `false`). A repo
not listed is ignored. A malformed file stops the run with an error, never a default.

`require_token = true` holds a repository until its owner has a token file: with
none, the repository is never touched (no `gh` call, not even a listing) and gets
one `waiting` `token-required` row per run, live or dry-run, which does not make
the run exit 1. `status` lists it under `token_required` with `require_token: yes`
and the owner's identity, and warns `<owner>: token required but missing`. Save the
owner's token (below) and the next run processes the repository, with no config
edit. The option only withholds: an insecure or expired token keeps its own
`insecure-token-file` / `token-expired` row, and a repository without it behaves as
before, on the default login.

## Rollout verification (stage 1: observe)

Design: `docs/superpowers/specs/2026-10-27-captain-rollback-design.md`. `[rollback]
stage` is `0` (off, the shipped default: no row, no check, no alert) or `1` (observe).
`2` and `3` (reverts) are not built: either runs as `1` and `status` warns. Stage 1
never re-runs, reverts, freezes, dispatches or applies anything, and does not change
how a pull request is merged. Turn it on with `stage = 1` in the chezmoi source and
`chezmoi apply`; turn it off again with `stage = 0` or pause the captain.

Each `[[repo]]` has `rollout` (default `none`), set in the shipped config from each
repository's workflow triggers:

| Kind | Window | Signal on the landed head |
|---|---|---|
| `none` | - | none; the row closes `no-signal` |
| `ci-only` | 30 min | its push checks on the default branch |
| `release-workflow` | 60 min | the run of `rollout_workflow` (a file name, e.g. `semantic-release.yml`) |
| `gitops` | 90 min | its CI run, then the `health_check` run in `rollout_target` (same owner) its `dispatch-e2e` job started |

`rollout_window_m` overrides the window. A missing required key, or a key that does
not go with the kind, is a config error. `[limits] max_verifies_per_run` (10) caps the
rows checked per run; `max_reverts_per_day` is read but unused until stage 2.

After each merge the captain appends a `pending` row to `rollouts.jsonl` (repo, PR,
tier, kind, merged time, deadline, landed head and base, commit count, fingerprint).
Rebase merge rewrites SHAs, so the landed head is the PR's `mergeCommit` and the base
its ancestor N first-parent steps down (N the PR's commit count); the range's diff is
compared with the PR's ignoring hunk positions and whitespace (`match`, `mismatch` or
`unknown`; only the verdict is kept). Rows hold no diff text and no credential.

Every non-dry run then checks the open rows of live repositories, least recently
checked first, skipping rows merged in the last two minutes. Signals come from the
Actions runs API:

- Blame-eligible: a `push` run on the default branch for the landed head, the
  `rollout_workflow` run, or the matched `health_check` run. Never: `schedule` or
  `workflow_dispatch` runs (so a canary never counts), pull-request and other
  `repository_dispatch` or `workflow_run` runs, and workflows named `codeql`,
  `prd-drift`, `promote-prd`, `update-pages`, `model-audit` or `audit-admin-bypass`.
  Only conclusion `failure` counts; `cancelled`, `timed_out`, `startup_failure` and
  `stale` are never blame.
- A failing push run is blame only with a green baseline: the same workflow passed on
  the base commit or, if it did not run there, on its latest push run on the default
  branch before the merge within 7 days. Red there is `preexisting-red`, none is
  `no-baseline`; both are noted in the row and never blamed. A `workflow_run` release
  or an `E2E` dispatch run that fails is blame as it stands.
- `gitops`: if `dispatch-e2e` was skipped (nothing released) the row is live on CI
  alone. Otherwise the signal is the first `repository_dispatch` `health_check` run in
  the target created after that job finished, unless another release's
  `dispatch-e2e` also finished before it was created; then there is no E2E signal and
  the row ends `unknown`. The API does not show the dispatch type, so `apps-deployed`
  is not checked.
- A release workflow or delivery that never started (path-filtered, nothing to
  release) leaves the push checks as the signal once nothing has moved for 10 minutes;
  a `ci-only` row with no eligible run at all by then is `no-signal`.

States: `live` (the signal succeeded), `no-signal`, `suspect` (one blame failure),
`failed` (two failures that are two signals: the same run failing again in a later
attempt, or a rollout signal failing in a run other than another failure's; one run
never counts twice, and two different checks failing on one push stay `suspect`),
`unknown` (the window passed without a signal, or passed while paused). `suspect`
stays open until the deadline so a second failure is still seen; the rest close.

On `suspect` and on `failed` the original PR gets the `needs-human` label and one
comment each, linking the failing runs. `unknown`, `live` and `no-signal` are only
logged. Log actions: `live`, `no-signal`, `rollout-suspect`, `rollout-failed`,
`rollout-unknown`. The run prints a `rollouts` table for the rows it checked;
`status` shows `rollouts` (the stage, each repository's kind, counts for the last 7
days, and the rows still pending or alerting). The design's Jira ticket on an alert is
not filed: the captain holds no Jira credential.

`merge-captain pause` stops verification with everything else.

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
3. **Repository access**: All repositories. The captain acts only on repositories
   listed in `merge-captain.toml`, so a repository added there needs no new token.
   The trade-off is that a leaked token reaches every repository the owner can write
   to; choose Only select repositories (the ones under `repos` in `merge-captain
   status`) if that matters more than not reissuing.
4. **Expiration**: the longest GitHub allows for that owner. An organization policy
   can require an expiration (366 days by default for fine-grained tokens) or a
   shorter one, so pick whatever the policy permits, and rotate before
   `merge-captain status` warns.
5. **Repository permissions**, and nothing else (no Administration, no Workflows
   write):
   - Contents: Read and write
   - Pull requests: Read and write
   - Issues: Read and write
   - Metadata: Read
   - Commit statuses: Read
   - Checks: Read
   - Actions: Read
   - Code scanning alerts: Read

   Check state comes from `statusCheckRollup`, which combines check runs (Checks),
   commit statuses (Commit statuses) and Actions runs (Actions); the captain needs
   all three to read it completely.
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

## The approver App

The org rulesets on `jdwlabs/apps`, `jdwlabs/infrastructure` and `jdwlabs/platform`
require one approving review, so R2 PRs there stop at `merge state BLOCKED`. A
separate GitHub App, `merge-captain-approver` (Pull requests: Read and write, nothing
else, installed on those three repositories), approves them. It authors nothing and
is not `jdwlabs-agent-bot`, so revoking one never disables the other. Design:
`docs/superpowers/specs/2026-10-26-captain-approver-design.md`.

A repository opts in with `approver = true` (default `false`; the shipped config sets it
on `jdwlabs/apps`, `jdwlabs/infrastructure` and `jdwlabs/platform`, the repositories that
require an approving review); `[limits] max_approvals_per_hour`
(default 4) caps approvals. The step runs only when the merge gate is otherwise met,
GitHub reports `REVIEW_REQUIRED` with merge state `BLOCKED`, and the repository is
`live`. Then, in order:

1. Not paused, tier R2 or below, author on the allow-list, and not the App itself
   (`approver-authored`). Rows for this head in `approvals.jsonl` decide what is left:
   a `confirmed` row means it was approved and GitHub still wants a review
   (`approval-not-accepted`); a `withdrawn` row means it was taken back
   (`approval-withdrawn`); either way the head is never approved again, so a held PR
   is not approved in a loop. A head with only an `attempted` row is looked up in step
   7. The hourly cap (`approval-cap`) counts attempts.
2. The head is read again and must be the reviewed one (`head moved before approval`).
3. The App's files must be usable, else `waiting` `approver-missing` and nothing else
   is called.
4. The base branch's rules (`rules/branches/<base>`) must include a `pull_request`
   rule with `dismiss_stale_reviews_on_push` true, else `waiting`
   `approver-no-stale-dismissal`. Without it an approval would survive a push and the
   merge could land code nobody reviewed. Unreadable rules count as not set, and
   classic branch protection is not consulted: a repository that dismisses stale
   approvals only through classic protection is refused here too.
5. No CODEOWNERS requirement over the changed paths: a pending code-owner review
   request on the PR, or a CODEOWNERS file on the base branch (`.github/`, root,
   `docs/`) with a line that owns a changed path (last match wins; a line with no
   owner releases the path). A hit labels the PR `needs-human`
   (`codeowners-required`). A file is concluded absent only from a base-tree listing
   that succeeded, never from a bare 404. Matching is a bounded per-segment glob (no
   backtracking regex): a pattern covers the file it names and everything below a
   directory it names, a trailing `**` covers everything below, and a wildcard in the
   last segment of a pattern with a slash matches that one level (`/docs/*` owns
   `docs/a.md`, not `docs/sub/a.md`). Anything that cannot be judged is `waiting`
   `codeowners-unknown`: no approval. That covers failed reads, 100 or more changed
   files, a file that is not base64 text, sections, character classes, escapes,
   negation, a wildcard-only directory pattern such as `a/*/`, and patterns or paths
   past the size caps.
6. The head is read once more, immediately before the token is minted.
7. If the head has an unconfirmed attempt, the PR's reviews are listed: a review by
   the App on this head is recorded as `confirmed` (`resumed`) and not posted again;
   none means the post never arrived and it is retried (within the cap); a list that
   cannot be read is `waiting` `approval-unverified`.
8. A fresh installation token is minted for this one approval, limited to the one
   repository and the `pull_requests: write` permission: an RS256 JWT (`iat` now-60 s,
   `exp` now+540 s, `iss` the App ID) signed with `openssl dgst -sha256 -sign`
   through the key file's checked descriptor (`/dev/fd/N`, not its path), exchanged at
   `POST /app/installations/<id>/access_tokens` by the captain itself over HTTPS, so
   the JWT is never on a command line. The token lives in memory only and is revoked
   with `DELETE /installation/token` as soon as it has been used, on error paths too.
9. An `attempted` row is written to `approvals.jsonl`, then the `APPROVE` review is
   submitted on that head (`commit_id`), body "merge-captain approval: tier T, reviewer
   lane L, sha S" (R0: "no review required (R0)"), then a `confirmed` row. If a
   deadline or crash comes after the post went out, the `confirmed` row is still
   written.
10. The usual `--match-head-commit` merge, as the owner's identity. If it does not
    happen, the approval is taken back (the App's own review is dismissed and a
    `withdrawn` row written; `withdraw-failed` if GitHub refuses) only when the head
    changed, the host refused the merge for a lasting reason (a policy, a required
    check, a conflict), the run hit its hard deadline between the post and the merge
    result, or something unexpected failed. A pause, the hourly merge cap, a network
    error, a 5xx or a "try again" refusal leaves the approval standing, and the next
    run merges on it.

R0 PRs are approved too: that has not been settled with the owner and may change.

A push after the approval dismisses it, which is what step 4 verifies; the next run
starts again at step 1 on the new head, and a PR is never merged on an approval for
another commit. `merge-captain pause` stops approvals as it stops merges (withdrawing
an approval still goes ahead). `status` shows `approver` (state, repositories,
approvals this hour) and warns when a repository wants an approver that is missing or
unsafe. Key text, JWT and installation token join the captain's list of secrets, so
nothing prints or logs them.

Provisioning (yours, outside any agent session; agents may drive the App registration
form but never read the generated key):

1. Register the App under the `jdwlabs` organization with only Pull requests: Read
   and write, webhooks off, and install it on `jdwlabs/apps`, `jdwlabs/infrastructure`
   and `jdwlabs/platform`. Note the App ID and the installation ID (the number in
   the installation's settings URL). Generate a private key. Make sure the three
   rulesets dismiss stale approvals on push.
2. In a normal terminal: `merge-captain auth-app --key-file ~/Downloads/<key>.pem`
   and type the two ids at the prompts (they are public numbers, shown as typed). The key file must be a plain file of
   yours with mode 0600. The command refuses without a terminal, inside an agent
   session (`CLAUDECODE` set) and under `script`, `expect` and similar wrappers; that
   last check is best effort, a pty made some other way (for example Python's
   `pty.spawn`) cannot be told from a person's and is not stopped. It checks that the
   key can sign, copies it into the token directory as `approver.key` (0600, with
   `approver.json` for the ids; the guard hook covers both like the tokens) and prints
   only the two ids. Then delete the source file it names (it says nothing of the
   kind when you point it at the saved key itself).
3. `merge-captain status` shows `approver: state: ready`. Set `approver = true` on the
   repositories that should use it in the chezmoi source of `merge-captain.toml` and
   `chezmoi apply`; then try one PR with `merge-captain explain O/R#N`.

A key file that is a symlink, belongs to someone else or is readable by group or
others is not used (`approver-missing`; `status` names the reason).

How a real run protects what it holds, and what that does not do:

- The command starts as `/usr/bin/python3 -IE`. `gh` and `openssl`, the only programs
  that see an owner token or the App key, are found in `/usr/bin`, `/usr/local/bin`
  and `/bin` only and run with that PATH, whatever the caller's PATH or
  `~/.local/bin` holds. Certificate, proxy, Python, loader (`LD_*`, `OPENSSL_*`),
  `GH_*`, `GITHUB_*` and `GIT_*` variables are dropped from the process and every
  child, so a default login that depended on `GH_TOKEN` in the environment no longer
  works in a real run; use `gh auth login`.
- Any `MERGE_CAPTAIN_` variable (a prefix rule, so a future one is covered),
  `AGENT_EVAL_STATE`, `AGENT_PACE_LANES`, a moved `XDG_CONFIG_HOME` or
  `XDG_STATE_HOME`, or a changed `HOME` is an override. While one is set no owner
  token and no App key is loaded (`insecure-token-file`, approver `insecure`), and
  `auth` and `auth-app` refuse to save. The tests honour overrides only for a copy of
  the tool that is not `~/.local/bin/merge-captain` and whose tokens and state resolve
  under `/tmp` or `/var/tmp`; no environment variable turns this on. The guard hook
  refuses any command that assigns a `MERGE_CAPTAIN_` variable (inline, `export`,
  `env`, `declare`, or from Python, perl, ruby or node) but allows reading one.
- These checks do not stop an agent running as the same unix account. It can change
  `PATH`, set a proxy or CA bundle for a program the captain does not scrub, replace a
  file in `~/.local/bin`, add a systemd drop-in for the captain's unit, or read the
  key file directly. The override rule defends credentials only against a run that
  was started with an override in its environment, by mistake or by a prompt-injected
  shell command; it is not a boundary.
- The existing `jdwlabs-agent-bot` key already lives where agents on this account can
  read it, and with it they can already approve PRs it did not author. The approver
  App therefore adds no new capability for an agent, and removes none. The real fix is
  to run the captain, its state and its tokens as a separate unix account (tracked as
  JDW-209). Until then going live rests on the owner accepting that limit.

Rollback: `merge-captain pause`, then uninstall the App from the organization, or set
`approver = false` (those PRs go back to `blocked`), or `merge-captain auth-app
--remove` (they wait as `approver-missing`).

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
- `rollouts.jsonl`: one line per rollout check, the last line per repo and PR is
  the row's state (see "Rollout verification").
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
  `merge-captain auth`, `auth-app` or `merge-captain status`. A line is split at newlines, `;`,
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
- If the repository's ruleset requires an approving review and the repository has no
  `approver = true`, the merge is refused and shows as `blocked`; the captain never
  approves as the owner or as its own `gh` identity (see "The approver App").
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
