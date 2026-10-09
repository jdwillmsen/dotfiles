# Devbox Map

Personal devbox (`dev-admin`). This file is the ancestor-directory map every
agent inherits when working anywhere under `$HOME` — it says where things
live and the conventions specific to *this box*, not workflow philosophy
(that's `~/.claude/CLAUDE.md`'s job).

## Dotfiles — chezmoi, not a plain clone

Source of truth: `~/.local/share/chezmoi` (chezmoi `sourceDir`). Jump there
with the `dotfiles` alias (`cd "$(chezmoi source-path)"`).

- Edit files under the source dir, never the deployed target directly
  (`~/.config/...`, `~/.claude/...`, etc.) — `chezmoi apply` overwrites the
  target from source on every run, so direct edits there silently vanish.
- After editing source: `chezmoi apply -v` to deploy and see the diff.
- Reference docs live in its `docs/` (workflow, shell helpers, provisioning,
  services, secrets); rules stay in `~/.claude/CLAUDE.md`, not here.
- No standalone `~/dotfiles` clone exists or should be made — it drifts from
  this source and has caused confusion before.
- **Standing rule:** any devbox config change — shell, tmux, SSH-into-devbox
  setup (`docs/provisioning.md`), env vars, editor
  config — gets mirrored into chezmoi source and committed, not left only in
  the deployed target. Check `git status` in the source dir after any such
  change; if it's dirty, that change is not standardized yet.

## Projects — `~/projects/<owner>/<repo>`

One grouping folder per GitHub owner; each owner is a separate business
stream with its own Jira project and board (dotfiles `docs/streams.md`).

- `~/projects/jdwillmsen/` — personal projects and brand, `JDW`; the `career`
  repo files to `CAREER`.
- `~/projects/jdwlabs/` — the `jdwlabs` org, `JDWLABS`: `apps/`,
  `deployments/`, `infrastructure/`, `platform/`. Independent sibling repos,
  not a monorepo.
- `~/projects/dotablaze-tech/` — the `dotablaze-tech` org, `DOTA`.

A repo's folder, worktree namespace and Jira project all follow its GitHub
owner. Streams reference each other with Jira issue links, never by sharing
an Epic.

## Worktrees — `~/worktrees/<owner>/<repo>/<branch>`

`gwta` namespaces by the repo's GitHub owner, so `jdwlabs/platform` and
`dotablaze-tech/platform` cannot collide. `WT_BASE` (default `~/worktrees`)
may not exist until the first `gwta` run — its absence is not an error.

## Streams — one per GitHub owner

Each owner is a separate business with its own Jira project; the map is
`~/.config/streams.json`. `stream key` prints the project for the current
repo and `stream status <owner>` its open PRs and alerts. A fork whose origin
is upstream is assigned with `git config stream.owner <owner>`. Alert
tickets are filed automatically into a separate `OPS` project and belong to
no stream; never file planned work there. Detail: dotfiles `docs/streams.md`.

## Ticket-aware Claude launch — `cj`

Prefer `cj` over bare `claude` inside a ticket-named worktree: it launches
with `-n <KEY>` resolved from the branch, so `/resume` and the tab title are
scannable. Defined in dotfiles `home/dot_config/shell/functions.sh`; never
rename it to `claude` — shadowing the binary breaks `claude agents --json`.

## Credential-minting commands — human's terminal, not an agent's

Commands that mint, print, or exchange a credential (pairing tokens, auth
codes, QR codes, API keys, recovery codes, session tokens) never run through
an agent's shell tool — that output is persisted in transcripts and logs, a
printed credential cannot be un-printed, and revocation is a race.

- **Prepare, then hand over.** Do the install and config up to that point,
  then give the human the exact command to run in a terminal *outside* the
  agent session — a separate SSH login, a tmux pane, a local shell — so the
  secret reaches no transcript at all.
- **Not Claude Code's `! <command>`.** Bash mode appends its output to the
  session context, so the credential lands in the transcript anyway. Use it
  only when nothing else is to hand, and revoke the credential afterwards.
- Worked example: `docs/t3code.md` in the dotfiles repo.
