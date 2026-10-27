# Merge captain rollout verification and rollback net

Status: proposed. R3 (the captain would write to `main` through revert PRs and change
how merges reach production): nothing here is built before the owner answers the open
questions and approves it.

## Intent

The captain merges R0–R2 PRs unattended in the 12 repositories of `merge-captain.toml`.
The shared rules say a change is done when it is live, yet after `gh pr merge` nothing
checks that `main` stayed green or that the rollout worked, and nothing undoes a bad
merge. This adds both, for captain merges only, within the same authors and repositories.

## Rollout kind per repository

Each `[[repo]]` gains `rollout` (default `none`) and `rollout_window_m`:

| Kind | Repos (proposed) | "Live" means |
|---|---|---|
| `none` | `career`, `fwb-minecraft` | `main` CI green on the merged head |
| `chezmoi-apply` | `dotfiles` | CI green, then `chezmoi diff` empty for the merged commit on the devbox |
| `release-workflow` | `gameops`, `countdown-app`, `jdwlabs/infrastructure`, `jdwlabs/platform` | the `rollout_workflow` run (default `release.yml`) for the merged head succeeded |
| `gitops` | `jdwlabs/apps`, `dotablaze-tech/apps` → their `deployments`; the three `deployments` repos themselves | the image-bump PR in `rollout_target` exists, merges, and its `health_check` (a named check on the target's `main`) is green |

A non-prd bump PR is an ordinary R2 PR the captain merges as today; a prd promotion is
R3, so verification stops at `awaiting-human` and the window does not run. The captain
never applies infrastructure or touches a cluster itself.

After each `merged`, a `pending` row goes to `rollouts.jsonl` (repo, PR, merged head,
tier, kind, deadline). Each run first walks pending rows (cap `max_verifies_per_run`,
default 10) and moves each to `live`, `failed` or `unknown` (window passed, no signal).

## Failure signals

- A check fails on the merged head of `main` that was green on its parent (the base the
  PR was rebased onto). A check already red on the parent is `preexisting-red`: logged,
  never reverted.
- The rollout signal for the kind fails within the window.
- `unknown` is never a failure: it labels the PR `needs-human` with one comment.

Only the first failing merge after a green parent is blamed. If a later merge already
landed on top, the row is `failed` but the action is `needs-human`, not a revert.

## Rollback action

1. Never force-push, never push to `main`. In a scratch clone, branch
   `revert/<pr>-<short-sha>` from current `main`, `git revert` the PR's commits newest
   first into one commit, push the branch, open a PR titled `revert: <title> (#N)`
   with the failing signal in the body, authored as the repo's captain identity.
2. A conflicting revert is abandoned: `needs-human` on the original PR, no branch left.
3. Tier is the higher of the original PR's tier and `change-class` on the revert diff.
   R0–R2 within the repo's `max_tier` goes through the normal gates (CI, review,
   approver) and merges; anything higher is labelled `needs-human` and left.
4. The original PR gets a comment linking the revert; the implementer lane gets an
   `agent-eval` outcome `rolled-back` for its scoreboard.

## Caps, pause and loop protection

- `[rollback] enabled` (default `false`), `max_reverts_per_day` (default 2, all repos).
- One revert per original PR, keyed by repo and PR in `reverts.jsonl`; a second failure
  of the same PR is `needs-human`.
- A revert PR is verified like any merge but is never itself reverted: its failure
  pauses that repository (`frozen`, no merges) until `merge-captain unfreeze O/R`.
- Two `failed` rollouts in one repository in 24 hours also freeze it.
- `merge-captain pause` stops verification and reverts with everything else; rows whose
  window passed during a pause become `unknown`, never a revert.
- Log actions: `live`, `rollout-failed`, `rollout-unknown`, `revert-opened`,
  `revert-merged`, `frozen`. `status` shows pending rows, reverts today, frozen repos.

## Blast radius and rollback of the net

Worst case: a wrong blame reverts a good R0–R2 change in one repository, through a PR
that passed its gates; undoing it is a re-revert PR. At most two a day, and a revert that
fails freezes the repo instead of compounding. R3 changes and prd promotions are never
reverted automatically. Rollout in stages: verify-only (rows and `needs-human`, no
reverts) for a week, then revert PRs opened but held (`hold` label), then auto-merge.
Turning it off: `[rollback] enabled = false`, `rollout = "none"` per repo, or `pause`.

## Tests

Pending row on every merge, none on dry-run; each kind reaches `live` on its signal and
`unknown` at the deadline; `preexisting-red` never reverts; a stacked later merge gives
`needs-human`; revert branch built from `main`, no push to `main`, no force; conflict
leaves no branch; revert tier never below the original; R3 revert not merged; one revert
per PR; failed revert freezes; daily cap and pause hold; prd promotion stops at
`awaiting-human`; no token or diff text in any row.

## Open questions for the owner

1. GitOps "live": is a GitHub check on the deployments repo enough, or should the
   captain get read-only Argo CD or cluster health access (R3 on its own)?
2. Dotfiles: should the captain run `chezmoi apply` itself after a merge (it would
   redeploy its own binary and hooks), or only verify after your apply?
3. Should a revert of a captain merge skip the reviewer step (CI-only, like R0) to land
   faster, or take its full tier gate?
4. One red check on `main` triggers a revert, or a second failure first? A rerun needs
   Actions write on the owner tokens, which they lack today.
5. Windows: 30 min for CI, 60 for releases, 120 for GitOps, or other values?
6. Where should a failure reach you: `needs-human` label only, an `OPS` alert ticket,
   or a stream ticket via `jira-followup`?
7. Freeze thresholds (two failures in 24 h) and whether only you may unfreeze.
