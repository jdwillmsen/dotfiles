# Merge captain rollout verification and rollback net

Status: proposed. R3 (the captain would write to `main` through revert PRs and change
how merges reach production). Owner decisions are recorded below; stage 1 is built
first and each later stage needs the owner's go-ahead.

## Intent

The captain merges R0–R2 PRs unattended in the 12 repositories of `merge-captain.toml`.
The shared rules say a change is done when it is live, yet after `gh pr merge` nothing
checks that `main` stayed green or that the rollout worked, and nothing undoes a bad
merge. This adds both, for captain merges only, within the same authors and repositories.

## Rollout kind per repository

Each `[[repo]]` gains `rollout` (default `none`) and optionally `rollout_window_m`
(defaults: 30 min for CI, 60 for a release workflow, 90 for GitOps):

| Kind | Repos (proposed) | "Live" means |
|---|---|---|
| `none` | `career`, `fwb-minecraft` | `main` CI green on the merged head |
| `chezmoi-apply` | `dotfiles` | CI green, then the devbox's existing apply timer has applied the merged commit and `chezmoi diff` is empty. The captain never runs `chezmoi apply` |
| `release-workflow` | `gameops`, `countdown-app`, `jdwlabs/infrastructure`, `jdwlabs/platform` | the `rollout_workflow` run (default `release.yml`) for the merged head succeeded |
| `gitops` | `jdwlabs/apps`, `dotablaze-tech/apps` → their `deployments`; the three `deployments` repos themselves | the image-bump PR in `rollout_target` exists and merges, and `health_check` (a named GitHub check on the target's `main`) is green |

The GitOps signal is a GitHub check only; read access to Argo CD or the cluster is a
separate, later R3 change. A non-prd bump PR is an ordinary R2 PR the captain merges as
today; a prd promotion is R3, so verification stops at `awaiting-human` and the window
does not run. The captain never applies infrastructure or touches a cluster.

After each `merged`, a `pending` row goes to `rollouts.jsonl` (repo, PR, merged head,
tier, kind, deadline). Each run first walks pending rows (cap `max_verifies_per_run`,
default 10) and moves each to `live`, `failed` or `unknown` (window passed, no signal).

## Failure signals

- A check fails on the merged head of `main` that was green on its parent (the base the
  PR was rebased onto). A check already red on the parent is `preexisting-red`: logged,
  never reverted.
- The rollout signal for the kind fails within the window.
- The first failing signal for a merge only alerts. A revert needs a second failing
  signal for the same merged head: another failing check run, or the rollout signal as
  well. The captain never re-runs a check itself.
- `unknown` is never a failure; it alerts.

An alert is the `needs-human` label with one comment on the original PR, plus a ticket
in the repository's own Jira project through `jira-followup` (never `OPS`), one per PR.
Only the first failing merge after a green parent is blamed. If a later merge already
landed on top, the action is an alert, not a revert.

## Rollback action

1. Never force-push, never push to `main`. In a scratch clone, branch
   `revert/<pr>-<short-sha>` from current `main`, `git revert` the PR's commits newest
   first into one commit, push the branch, open a PR titled `revert: <title> (#N)`
   with the failing signals in the body, authored as the repo's captain identity.
2. A conflicting revert is abandoned with an alert; no branch is left.
3. The revert PR is classified by `change-class`, never below the original PR's tier,
   and takes the full review that tier requires, with no shortcut. R0–R2 within the
   repo's `max_tier` then merges through the normal gates; higher is `needs-human`.
4. The original PR gets a comment linking the revert; the implementer lane gets an
   `agent-eval` outcome `rolled-back` for its scoreboard.

## Caps, pause and loop protection

- `[rollback] enabled` (default `false`), `max_reverts_per_day` (default 2, all repos).
- One revert per original PR, keyed by repo and PR in `reverts.jsonl`; a later failure
  of the same PR only alerts.
- A revert PR is verified like any merge but is never itself reverted.
- Two `failed` rollouts in one repository in 24 hours, or a failed revert, freeze it
  (no merges, an alert). Only the owner lifts a freeze: `merge-captain unfreeze O/R`
  refuses without a terminal or inside an agent session, like `auth`.
- `merge-captain pause` stops verification and reverts with everything else; rows whose
  window passed during a pause become `unknown`, never a revert.
- Log actions: `live`, `rollout-failed`, `rollout-unknown`, `revert-opened`,
  `revert-merged`, `frozen`. `status` shows pending rows, reverts today, frozen repos.

## Stages, blast radius and rollback of the net

1. Checks only: rows, alerts and freezes, no reverts. Runs 1–2 weeks.
2. Revert PRs opened but held (`hold` label). Needs the owner's go-ahead.
3. Revert PRs merge through their gates. Needs the owner's go-ahead.

Worst case at stage 3: a wrong blame reverts a good R0–R2 change in one repository,
through a PR that passed its gates; undoing it is a re-revert PR. At most two a day, and
the second failure freezes the repo instead of compounding. R3 changes and prd
promotions are never reverted automatically. Turning it off: `[rollback] enabled =
false`, `rollout = "none"` per repo, or `merge-captain pause`.

## Tests

Pending row on every merge, none on dry-run; each kind reaches `live` on its signal and
`unknown` at its deadline; the captain never runs `chezmoi apply` or re-runs a check;
one failure alerts without reverting, a second reverts; `preexisting-red` never reverts;
a stacked later merge only alerts; alert files one Jira ticket in the repo's project,
never `OPS`; revert branch built from `main`, no push to `main`, no force; conflict
leaves no branch; revert tier never below the original and fully reviewed; R3 revert not
merged; one revert per PR; two failures in 24 h freeze; `unfreeze` refuses inside an
agent session; daily cap and pause hold; stage 1 opens no revert; prd promotion stops at
`awaiting-human`; no token or diff text in any row.

## Decisions (owner, 2026-10-27)

1. GitOps "live" is a GitHub check on the deployments repo. Argo CD or cluster access
   is a separate, later R3.
2. The captain never runs `chezmoi apply`; it verifies after the existing apply timer.
3. Revert PRs get the review their own classified tier requires; no shortcut.
4. One red check on `main` only raises `needs-human`; a revert needs a second failure;
   no automatic re-runs.
5. Windows: CI 30 min, releases 60, GitOps 90.
6. Alerts: `needs-human` label plus a `jira-followup` ticket in the repo's own Jira
   project, not `OPS`.
7. Freeze a repository after 2 failed rollouts in 24 hours; only the owner lifts it.
8. Stage 1 (checks only) is built first and runs 1–2 weeks; stages 2 and 3 each need
   the owner's go-ahead.
