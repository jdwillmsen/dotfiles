# Merge captain rollout verification and rollback net

Status: proposed. R3 (the captain would write to `main` through revert PRs and change
how merges reach production). Owner decisions are recorded below; stage 1 is built
first and each later stage needs the owner's go-ahead.

## Intent

The captain merges R0–R2 PRs unattended in the 12 repositories of `merge-captain.toml`.
The shared rules say a change is done when it is live, yet after `gh pr merge` nothing
checks that `main` stayed green or that the rollout worked, and nothing undoes a bad
merge. This adds both, for captain merges only, within the same authors and repositories.

## Config (all keys new)

`[[repo]]`: `rollout` (`none` default, `release-workflow`, `gitops`),
`rollout_window_m` (default by kind: `none` 30, `release-workflow` 60, `gitops` 90),
`rollout_workflow` (file name, default `release.yml`), `rollout_target` (`owner/repo`,
`gitops` only) and `health_check` (check name on the target's `main`, `gitops` only).
A `gitops` repo without both target keys is a config error. `[limits]`:
`max_verifies_per_run` (10), `max_reverts_per_day` (2, all repos). `[rollback]`:
`stage` (`0` off, the default; `1` checks only; `2` held reverts; `3` reverts merge).

## Rollout kind per repository

| Kind | Repos (proposed) | "Live" means |
|---|---|---|
| `none` | `dotfiles`, `career`, `fwb-minecraft`, `jdw-deployments`, `jdwlabs/deployments`, `dotablaze-tech/deployments` | every check green on the landed head of `main` |
| `release-workflow` | `gameops`, `countdown-app`, `jdwlabs/infrastructure`, `jdwlabs/platform` | the `rollout_workflow` run for the landed head succeeded |
| `gitops` | `jdwlabs/apps`, `dotablaze-tech/apps` → their `deployments` | the image-bump PR in `rollout_target` exists and merges, and `health_check` is green on its landed head |

For the deployments repos merging is the rollout, so they are `none`. Dotfiles is
`none` too: no apply timer exists, so the captain cannot tell when a merge is applied;
an apply timer and a `chezmoi-apply` kind are a separate, later R3. The captain never
runs `chezmoi apply`, applies infrastructure or touches a cluster; Argo CD or cluster
health is also a later R3. A prd promotion bump is R3, so verification stops at
`awaiting-human` and its window does not run.

After each `merged`, a `pending` row goes to the new `rollouts.jsonl`: repo, PR, tier,
kind, deadline, and the landed range. Rebase merge rewrites SHAs, so the range is read
from `main`, not the PR: the landed head is the PR's `mergeCommit`, the base is that
commit's ancestor N first-parent steps down (N the PR's commit count), and the range's
combined diff must match the PR diff's fingerprint (per-file hunks with line numbers
stripped, like `git patch-id`). A mismatch is recorded and never reverted.

## Failure signals and row states

A failing signal is a check that fails on the landed head and was green on the base
(red on the base too is `preexisting-red`), or the kind's rollout signal failing in
the window. The captain never re-runs a check. Each run moves pending rows (up to
`max_verifies_per_run`) to:

- `live`: the kind's signal succeeded.
- `suspect`: one failing signal. Alert only.
- `failed`: a second failing signal for the same landed head (another failing check
  run, or the rollout signal as well). Only `failed` may revert or count toward a freeze.
- `unknown`: window passed with no signal (also after a pause). Alert only.

An alert is the `needs-human` label with one comment on the original PR, plus one
ticket in the repository's own Jira project through `jira-followup`, never `OPS`.
Only the first failing merge after a green base is blamed; with a later merge on top,
the row is alert-only.

## Rollback action

1. Abandoned with an alert, never worked round: a later commit on `main` touched a
   path in the range; the range changes a file mode, a symlink or a submodule; or it
   touches `.github/workflows/` (no token has Workflows write, and none is widened).
2. No clone and no `git push`. Through the API, as the identity below: create
   `revert/<pr>-<short-sha>` at `main`, then one `createCommitOnBranch` commit that
   restores every path in the range to its content at the base (added paths deleted),
   with `expectedHeadOid`. GitHub signs it, so `verify-pr-signatures` passes; the
   message carries the trailers `agent-identity` requires. Tokens reach `gh` only in the
   child's environment, as today, never in argv, a URL or a file.
3. Open `revert: <title> (#N)` with the failing signals in the body.
4. Tier is `change-class` on the revert diff, never below the original. It gets the full
   review that tier requires, from a lane that is neither the original PR's reviewer nor
   any of its implementer lanes. R0–R2 within `max_tier` then merges through the normal
   gates (stage 3); higher is `needs-human`.
5. The original PR gets a comment linking the revert; its implementer lane gets an
   `agent-eval` outcome `rolled-back`.

Revert author. `jdwlabs/*` repos: `jdwlabs-agent-bot`, since rules there need bot
authorship. Its App ID, installation ID and key go into the captain's token directory
through a new owner-only `merge-captain auth-bot`, provisioned like `auth-app`; without
them a revert there waits as `bot-missing`. The approver App approves R0–R2 reverts and
the owner approves R3 ones, neither being the author. `jdwillmsen/*` and
`dotablaze-tech/*`: the owner's fine-grained token for that owner (`auth`), so the PR is
authored as `jdwillmsen`. Those repos require no approving review today; an R3 revert
there is approved the AGENTS.md way (the owner merges it, or names it in chat), never by
a GitHub self-approval. Should one add an approval rule, its reverts wait as
`blocked` until the bot is installed there.

## Caps, freeze and loop protection

- `max_reverts_per_day`; one revert per original PR, keyed in the new `reverts.jsonl`;
  a later failure of the same PR only alerts. A revert PR is never itself reverted.
- After a revert merges, a PR whose diff fingerprint matches the reverted range waits as
  `reverted-change` until the owner runs `merge-captain unrevert O/R#N` (new).
- Two `failed` rows in one repository in 24 hours, or a failed revert, freeze it in the
  new `frozen.json`: no merges, approvals or revert PRs there, plus an alert.
- `merge-captain unfreeze O/R` (new) and `unrevert` refuse without a terminal, inside an
  agent session (`CLAUDECODE`), under `script`/`expect` wrappers and with any override
  set, like `auth-app`. The guard hook covers the new state files.
- Same-user limit: the state directory belongs to the account agents run as, so a freeze
  stops accidents and injected shortcuts, not a process deleting the file. It becomes
  binding only once the captain has its own unix account (JDW-209).
- `merge-captain pause` stops verification and reverts with everything else.
- Log actions: `live`, `rollout-suspect`, `rollout-failed`, `rollout-unknown`,
  `revert-opened`, `revert-merged`, `frozen`. `status` shows pending rows, reverts
  today and frozen repos.

## Stages, blast radius and rollback of the net

1. Checks only: rows, alerts and freezes, no reverts. Runs 1–2 weeks.
2. Revert PRs opened but held (`hold` label). Needs the owner's go-ahead.
3. Revert PRs merge through their gates. Needs the owner's go-ahead.

Worst case at stage 3: a wrong blame reverts a good R0–R2 change in one repository
through a reviewed PR; undoing it is a re-revert PR plus `unrevert`. At most two a day,
and a failed revert freezes instead of compounding. R3 changes and prd promotions are
never reverted automatically. Off: `[rollback] stage = 0`, `rollout = "none"`, or `pause`.

## Tests

Pending row on every merge, none on dry-run; landed range found after a rebase merge and
a fingerprint mismatch never reverts; each kind reaches `live` on its signal and
`unknown` at its deadline; no `chezmoi apply`, no check re-run; one failure is `suspect`
and alerts only, a second is `failed`; `suspect`, `unknown` and `preexisting-red` never
count toward a freeze; a stacked later merge only alerts; one Jira ticket per alert, in
the repo's project, never `OPS`; revert built through the API from `main`, no clone, no
push to `main`, no force; token never in argv, URL or file; overlap, mode, symlink,
submodule and workflow-path ranges abandon; jdwlabs reverts authored by the bot, others
by the owner token, `bot-missing` without the key; revert tier never below the original;
reviewer lane excludes the original reviewer and implementers; R3 revert not merged; one
revert per PR; matching re-merge waits as `reverted-change`; a freeze blocks merges,
approvals and reverts; `unfreeze` and `unrevert` refuse inside an agent session; daily
cap, pause and each stage hold; prd promotion stops at `awaiting-human`; no token or
diff text in any row.

## Decisions (owner, 2026-10-27)

1. GitOps "live" is a GitHub check on the deployments repo. Argo CD or cluster access
   is a separate, later R3.
2. The captain never runs `chezmoi apply`. No apply timer exists, so dotfiles is `none`
   for stage 1; an apply timer is a separate, later R3.
3. Revert PRs get the review their own classified tier requires; no shortcut.
4. One red check on `main` only raises `needs-human`; a revert needs a second failure;
   no automatic re-runs.
5. Windows: CI 30 min, releases 60, GitOps 90.
6. Alerts: `needs-human` label plus a `jira-followup` ticket in the repo's own Jira
   project, not `OPS`.
7. Freeze a repository after 2 failed rollouts in 24 hours; only the owner lifts it.
8. Stage 1 (checks only) is built first and runs 1–2 weeks; stages 2 and 3 each need
   the owner's go-ahead.
