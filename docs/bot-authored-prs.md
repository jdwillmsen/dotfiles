# Bot-authored pull requests

How an agent session opens a pull request as `jdwlabs-agent-bot` instead of
under the human's `gh` auth. The rule that says when to do it is in
`~/.claude/CLAUDE.md` (Shipping).

## Why

GitHub does not let an account approve its own pull request, and these repos
have one maintainer. A PR opened as `jdwillmsen` on a branch that requires an
approving review, or a CODEOWNERS approval, can only merge by bypass. Opened
as the bot, the same PR is approved by `jdwillmsen` in the ordinary way.

The bot cannot approve its own PR either, so a bot-authored PR still waits for
the human. It can approve a `jdwillmsen`-authored PR, which satisfies a plain
approval count but never a CODEOWNERS gate.

## Where the credentials are

There is no local helper. The App's credentials are in the Kubernetes secret
`ai-sre-relay`, namespace `ai-sre`, under `GITHUB_APP_ID`,
`GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY`.

Nothing minted is ever printed or persisted. Script the whole flow; do not run
the steps one at a time in a shell tool, where each output lands in the
transcript.

## Method

1. **Commit locally first.** A failed remote step followed by a reset to the
   branch has wiped uncommitted edits before.
2. **Stage the key in memory.** `umask 077`, a temp directory under
   `/dev/shm`, and a `trap` that shreds it on exit. Read each value straight
   into a file there or a shell variable, never to the terminal:
   `kubectl -n ai-sre get secret ai-sre-relay -o go-template='{{index .data "<KEY>"}}' | base64 -d > "$tmp/<file>"`.
3. **Sign a JWT.** RS256, header `{"alg":"RS256","typ":"JWT"}`, payload
   `{iat: now-60, exp: now+540, iss: <app id>}`, signed with
   `openssl dgst -sha256 -sign key.pem`, base64url-encoded.
4. **Exchange it for an installation token.**
   `POST https://api.github.com/app/installations/<installation id>/access_tokens`
   with `Authorization: Bearer <jwt>`; keep `.token` in a shell variable.
5. **Create the branch** at the current head of the base:
   `POST /repos/<owner>/<repo>/git/refs`.
6. **Create the commit through the API**, not with `git push`. Use the GraphQL
   `createCommitOnBranch` mutation: one call produces one commit holding every
   file, signed by GitHub and authored by the bot.
   - `input.branch.repositoryNameWithOwner`, `input.branch.branchName`
   - `input.message.headline`, `input.message.body`
   - `input.expectedHeadOid` — the branch's current head
   - `input.fileChanges.additions[] = {path, contents: <base64>}` and
     `deletions[] = {path}`
7. **Open the PR with the token:**
   `GH_TOKEN=$token gh pr create --repo <owner>/<repo> --head <branch> --body-file <file>`.

For a branch of several logical commits, replay each local commit as its own
`createCommitOnBranch` call. Rebase merge keeps every commit, so one call per
logical change is the unit.

## Traps

- **A locally signed commit pushed under the bot's name fails signature
  verification.** The signing key belongs to the human's account, not the App.
  This is why step 6 goes through the API.
- **Both trailers are required on every bot commit:** `Co-Authored-By` and
  `Assisted-by: <agent>:<model-id>`, in `message.body`. The `agent-identity`
  workflow in the jdwlabs repos checks each commit, API-created ones included.
- **`additions` replace whole files.** Built from a stale checkout, they
  silently revert whatever landed on the base in between. Re-read the base ref
  just before committing and diff your starting point against it for the paths
  you touch; rebase first if that diff is not empty.
- **`additions` cannot carry a file mode.** A change that makes a script
  executable is lost: the file arrives with the mode it already had, or as
  non-executable if new. Check `git diff --summary` for mode changes first and
  ship those another way.
- **Build the GraphQL payload in a file**, written by a short script, and send
  it with `gh api graphql --input <file>`. Base64 file contents passed as
  arguments overflow the argument list on large files.
- **Resetting a branch to its base closes any PR open on it.** Create the
  branch and commit before opening the PR. If it happens anyway,
  `gh pr reopen <n>` restores the same PR with the new commits.
- **To update a branch that has fallen behind without closing its PR**, build
  the commits on a temporary branch and force-move the PR's ref onto it.
- **Workflow files need the App's `workflows: write` permission.** Without it
  the mutation fails with `Resource not accessible by integration`. Check the
  minted token's `permissions` before shipping a workflow change.

## Repo notes

- `jdwlabs/infrastructure`: CODEOWNERS is a single catch-all, so every path is
  gated and bot authorship is the only route.
- `jdwlabs/platform`: the gated paths are listed in its `AGENTS.md`; an admin
  bypass does not clear that gate.
