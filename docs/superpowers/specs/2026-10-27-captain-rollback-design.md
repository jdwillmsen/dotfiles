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

`[[repo]]`: `rollout` (`none` default, `ci-only`, `release-workflow`, `gitops`),
`rollout_window_m` (default by kind: `ci-only` 30, `release-workflow` 60, `gitops` 90),
`rollout_workflow` (workflow file, required for `release-workflow`), `rollout_target`
(`owner/repo`) and `health_check` (workflow name there), both required for `gitops`.
A missing required key is a config error. `[limits]`: `max_verifies_per_run` (10),
`max_reverts_per_day` (2, all repos). `[rollback]`: `stage` (`0` off and the default,
writing nothing; `1` observe; `2` held reverts; `3` reverts merge).

## Rollout kind per repository

From each repository's workflow triggers on 2026-10-27:

| Kind | Repos | Signal |
|---|---|---|
| `none` | `fwb-minecraft` (no workflows) | none; the row closes as `no-signal`, logged only |
| `ci-only` | `dotfiles` (`ci`), `career` (`check`), `jdw-deployments` (`ci`), `jdwlabs/deployments` (`ci`), `jdwlabs/infrastructure` (path-filtered `terraform`, `bootstrap`, `extension-image`, plus `security-scan`), `jdwlabs/platform` (`validate`), `dotablaze-tech/apps` (`ci`) | blame-eligible checks on the landed head |
| `release-workflow` | `gameops` (`semantic-release.yml`), `countdown-app` (`release.yml`), both `workflow_run` after CI on `main`; `dotablaze-tech/deployments` (`release.yaml`, push to `main` under `charts/**`) | that workflow's run for the landed head |
| `gitops` | `jdwlabs/apps` → `jdwlabs/deployments`, `health_check = "E2E"` | the landed head's CI run (it releases and delivers), then the first `E2E` run in the target created after it |

The `release.yml` tag-push workflows elsewhere never run on a merge and are not used.
A path-filtered workflow that the range does not trigger, or a push that skips
`security-scan` (docs only), is no signal; a `ci-only` row with no blame-eligible check
at all closes as `no-signal`. If `jdwlabs/apps` CI released nothing (its
`dispatch-e2e` job skipped), the row is `live` on CI alone. Dotfiles has no apply timer,
so `ci-only` is all it can show; an apply timer is a separate, later R3. The captain
never runs `chezmoi apply`, applies infrastructure or touches a cluster, and does not
verify prd: Argo CD or cluster health is a later R3.

After each `merged` (stage 1 and up), a `pending` row goes to the new `rollouts.jsonl`:
repo, PR, tier, kind, deadline and the landed range. Rebase merge rewrites SHAs, so the
range is read from `main`: the landed head is the PR's `mergeCommit`, the base is its
ancestor N first-parent steps down (N the PR's commit count), and the range's combined
diff must match the PR diff's fingerprint (per-file hunks without line numbers, like
`git patch-id`). A mismatch is recorded and never reverted.

## Signals and row states

Blame-eligible: a check run triggered by `push` to `main` for the landed head, or the
repo's own `rollout_workflow` / `health_check`. Never: `schedule`, `workflow_dispatch`,
other `repository_dispatch` or `workflow_run` runs, and by name `codeql` (schedule),
`prd-drift`, `promote-prd`, `update-pages`, `model-audit`, `audit-admin-bypass`. Only
conclusion `failure` counts; `cancelled`, `timed_out`, `startup_failure` and `stale` are
runner trouble, never blame.

Green on base: the same check concluded `success` on the base commit or, if it did not
run there, on its latest run on `main` before the merge, within 7 days. No such run means
no baseline; red on the baseline is `preexisting-red`, logged and never blamed.

Each run moves pending rows (up to `max_verifies_per_run`) to:

- `live`: the kind's signal succeeded. `no-signal`: nothing to watch.
- `suspect`: one blame-eligible check failed with a green baseline, or the rollout
  signal failed. Alert.
- `failed`: a suspect check with a green baseline that also failed a second time on the
  same head (a re-run someone else started), or a suspect check plus a failed rollout
  signal. The captain never re-runs anything. Alert; only `failed` may revert or count
  toward a freeze.
- `unknown`: window passed without a signal, or it passed during a pause. Logged only:
  no label, no comment.
- `awaiting-human`: a revert that the rules leave to the owner (below).

Later merges: blame never moves. A `failed` row may revert only while no later commit on
`main` touches a path in its range; otherwise it becomes `awaiting-human`.

Alert, stage 1: the `needs-human` label with one comment on the original PR, the ledger
row, and a line under `rollouts` in `merge-captain status`. This deviates from owner
decision 6: the captain holds no Jira credential, so the `jira-followup` ticket waits
for a later stage with its own owner-approved credential design.

## Rollback action (stage 2 and up)

1. Abandoned, row `awaiting-human`, when: a path in the range is anything but a regular
   `100644` file before or after (executable, symlink, submodule; the API cannot carry a
   mode); the range touches `.github/workflows/` (no token has Workflows write and none
   is widened); or a CODEOWNERS line owns a path in the range and the revert would be
   authored by the code owner's own login (no one could approve it).
2. No clone and no `git push`. Through the API: create `revert/<pr>-<short-sha>` at
   `main`, then one `createCommitOnBranch` commit, with `expectedHeadOid`, restoring each
   path to its content at the base (added paths deleted). Tokens reach `gh` only in the
   child's environment, never argv, a URL or a file.
3. The commit is mechanical, so its trailers say so and name no model:
   `Co-Authored-By: merge-captain <merge-captain@noreply.invalid>` and
   `Assisted-by: merge-captain:none`, which satisfy the `agent-identity` pattern
   (`Co-Authored-By` with an email, `Assisted-by: <agent>:<id>`). The body names the
   original PR and its lanes.
4. Open `revert: <title> (#N)` with the failing signals in the body.
5. Tier is `change-class` on the revert diff, never below the original, with the full
   review that tier requires from a lane that is neither the original reviewer nor any
   of its implementers. Stage 2 holds it (`hold`); stage 3 merges R0–R2 within
   `max_tier` through the normal gates. Higher, or a CODEOWNERS path the approver
   refuses, is `needs-human` and the row `awaiting-human`.
6. The original PR gets a comment linking it; the implementer lane gets an `agent-eval`
   outcome `rolled-back`.

A failed revert: one whose own row reaches `failed`, or that GitHub refuses to merge for
a lasting reason (policy, required check, conflict).

## Revert author

- `jdwlabs/apps`, `jdwlabs/infrastructure`, `jdwlabs/platform` require an approving
  review, so the revert is authored by `jdwlabs-agent-bot` and the owner can approve it.
  Their CODEOWNERS files make most reverts `needs-human` anyway: `apps` and
  `infrastructure` have a catch-all `*` line and `platform` owns `.github/`, `tools/`,
  `bootstrap/`, `tenants/platform/` and `renovate.json`; the approver refuses those.
- `jdwlabs/deployments` and the `jdwillmsen/*` and `dotablaze-tech/*` repos require no
  approving review, so the owner's per-owner token (`auth`) authors it, as `jdwillmsen`.
  An R3 revert there is approved the AGENTS.md way (the owner merges it or names it in
  chat), never by self-approval. Code-owner rules there (`jdwlabs/deployments`
  `.github/`, `values-prd.yaml`, `argocd/prd/`; `dotablaze-tech/deployments`) hit rule 1.
- Bot credentials: a new owner-only `merge-captain auth-bot`, provisioned like
  `auth-app`, copies the App ID, installation ID and key into the token directory (0600,
  guard hook, `KNOWN_SECRETS`). Per revert the captain mints an installation token for
  that one repository with only `contents: write` and `pull_requests: write`, keeps it
  in memory, and revokes it after use, on error paths too. It never calls the reviews
  API. Without the files the revert waits as `bot-missing`.
- Accepted risk, to be recorded as for the approver: the key already lives in the
  Kubernetes secret `ai-sre-relay`, readable by agents on this account, so the copy adds
  no capability. It can drift: rotating the secret does not update the copy, so a mint
  that fails shows `bot-key-stale` in `status` until `auth-bot` is run again.

## Caps, freeze and loop protection (stage 2 and up)

- `max_reverts_per_day`; one revert per original PR, keyed in the new `reverts.jsonl`;
  a later failure of the same PR only alerts. A revert PR is never itself reverted.
- After a revert merges, a PR whose diff fingerprint matches the reverted range waits as
  `reverted-change` until the owner runs the new `merge-captain unrevert O/R#N`.
- Two `failed` rows in one repository in 24 hours, or a failed revert, freeze it in the
  new `frozen.json`: no merges, approvals or revert PRs there, plus an alert.
- The new `unfreeze O/R` and `unrevert` refuse without a terminal, inside an agent
  session (`CLAUDECODE`), under `script`/`expect` wrappers and with any override set,
  like `auth-app`. The guard hook covers `frozen.json` and `reverts.jsonl`.
- Same-user limit: the state directory belongs to the account agents run as, so a freeze
  stops accidents and injected shortcuts, not a process deleting the file. It binds only
  once the captain has its own unix account (JDW-209).
- `merge-captain pause` stops verification and reverts with everything else.

Log actions: `live`, `no-signal`, `rollout-suspect`, `rollout-failed`,
`rollout-unknown`, `awaiting-human`, `revert-opened`, `revert-merged`, `frozen`.

## Stages

1. Observe: config keys, `rollouts.jsonl`, the verification walk, `needs-human` label
   and comment on `suspect` and `failed`, `status` section, log actions. No freeze, no
   revert, no change to merge behaviour. Runs 1–2 weeks.
2. Held reverts: `reverts.jsonl`, `auth-bot`, revert PRs with `hold`, freezes,
   `unfreeze`, `unrevert`, guard-hook coverage. Needs the owner's go-ahead.
3. Reverts merge through their gates. Needs the owner's go-ahead.

Blast radius at stage 3: a wrong blame reverts a good R0–R2 change in one repository
through a reviewed PR; undoing it is a re-revert plus `unrevert`. At most two a day, and
a failed revert freezes instead of compounding. R3 changes are never reverted
automatically. Off: `[rollback] stage = 0`, `rollout = "none"`, or `pause`.

## Tests

Stage 1: no row at stage 0 or in dry-run; landed range found after a rebase merge, and a
fingerprint mismatch never reverts; each kind reaches `live` on its signal and `unknown`
at its deadline, and `unknown` writes no label or comment; path-filtered and skipped
workflows give no signal; schedule, dispatch and the named workflows are never blamed;
`cancelled` and `timed_out` are never blame; baseline taken from the latest earlier run
when the base has none; one failure is `suspect`, the second-attempt and rollout-signal
cases are `failed`; no `chezmoi apply`, no re-run; stage 1 opens no revert, writes no
freeze and changes no merge; no token or diff text in any row.

Before stage 2: a `createCommitOnBranch` commit made with each owner's fine-grained token
and with a bot installation token shows `verified` on GitHub and passes
`verify-pr-signatures` and `agent-identity`.

Stage 2 and 3: revert built through the API from `main`, no clone, no push to `main`, no
force; token never in argv, URL or file; non-`100644`, workflow-path, self-owned
CODEOWNERS and later-overlap ranges abandon; bot author on the three gated repos, owner
token elsewhere, `bot-missing` without the key; bot token scoped to one repo and two
permissions, revoked after use, never calls the reviews API; revert tier never below the
original; reviewer lane excludes the original reviewer and implementers; R3 revert not
merged; one revert per PR; matching re-merge waits as `reverted-change`; a freeze blocks
merges, approvals and reverts; `unfreeze` and `unrevert` refuse inside an agent
session; daily cap, pause and each stage hold.

## Decisions (owner, 2026-10-27)

1. GitOps "live" is a GitHub check on the deployments repo. Argo CD or cluster access
   is a separate, later R3.
2. The captain never runs `chezmoi apply`. No apply timer exists, so dotfiles is
   `ci-only`; an apply timer is a separate, later R3.
3. Revert PRs get the review their own classified tier requires; no shortcut.
4. One red check on `main` only raises `needs-human`; a revert needs a second failure;
   no automatic re-runs.
5. Windows: CI 30 min, releases 60, GitOps 90.
6. Alerts: `needs-human` label plus a `jira-followup` ticket in the repo's own Jira
   project, not `OPS`. Proposed amendment, awaiting the owner: stage 1 has no Jira
   ticket (see "Alert, stage 1").
7. Freeze a repository after 2 failed rollouts in 24 hours; only the owner lifts it.
8. Stage 1 (observe only) is built first and runs 1–2 weeks; stages 2 and 3 each need
   the owner's go-ahead.
