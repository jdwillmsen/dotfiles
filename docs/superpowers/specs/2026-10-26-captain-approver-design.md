# Merge captain approver identity

Status: proposed. R3 (changes who can approve merges): needs the owner's approval
before any of it is built.

## Intent

The org rulesets on `jdwlabs/apps`, `jdwlabs/infrastructure` and `jdwlabs/platform`
require one approving review. The captain may never approve as the owner, so every R2
Renovate PR there sits at `merge state BLOCKED` after its own review passes. The
owner chose a dedicated approver identity over reusing the authoring bot or dropping
the requirement, with approval limited to R2 and below from allow-listed authors.

## Identity

A new GitHub App, `merge-captain-approver`, installed on those three repositories
with **Pull requests: Read and write** and nothing else. It authors nothing, so it can
approve PRs opened by the existing bot as well as by Renovate, Dependabot and the
owner. It is separate from `jdwlabs-agent-bot`, so revoking one never disables the
other.

Its App ID, installation ID and private key sit beside the owner tokens in the
captain's token directory, mode 0600, behind the same guard hook. The captain signs a
short-lived JWT and exchanges it for an installation token **per approval**, held in
memory, never written or logged. Private key and token values join `KNOWN_SECRETS`.

Provisioning is the owner's step, in a terminal outside any agent session, like
`auth`: `merge-captain auth-app` refuses without a terminal and reads the three values
from a hidden prompt or a key file path. Agents may drive the App registration form
but never read the generated key.

## Behaviour

After a PR's tier gate is met and the captain would merge it, but GitHub reports
`REVIEW_REQUIRED`:

1. Re-read the head SHA and confirm it is the SHA the reviewer lane approved.
2. Require tier at most R2, author on the existing `authors` allow-list, repo
   `live`, repo opted in with `approver = true`, and no CODEOWNERS requirement
   covering the changed paths (approval on those paths stays with the owner; the PR
   gets `needs-human`).
3. Submit an `APPROVE` review as the App on that head SHA. The body names the tier,
   the reviewer lane and the SHA. Record it in the ledger.
4. Merge with `--match-head-commit` as today. If the rules dismiss the approval
   because the branch moved, the next run starts again from step 1; a PR is never
   merged on an approval for a different SHA.

Caps: `max_approvals_per_hour` (default 4) and `merge-captain pause`, which stops
approvals as well as merges. A PR authored by the App is skipped.

## Blast radius and rollback

Affects only the three repositories that require an approval, and only R0–R2 PRs from
allow-listed authors. R3, CODEOWNERS-gated paths, unknown authors and every other
repository behave as now. Rollback: `merge-captain pause`, then uninstall the App
from the organization, or set `approver = false`; removing the key file makes the
captain say `approver-missing` and wait.

## What this changes in the rules

`AGENTS.md` says never approve as the owner and that a PR needing approval is opened
as the bot. Both stay true. Added: "The merge captain approves R0–R2 org PRs as
`merge-captain-approver` once the tier's review is done."

## Tests

Approval only on the reviewed SHA; no approval for R3, CODEOWNERS paths, unlisted
authors, `approver = false` repos or the App's own PRs; stale approval after a push is
not reused; cap and pause stop approvals; token and key never appear in output,
state or logs; missing or loose key file waits with a named reason.
