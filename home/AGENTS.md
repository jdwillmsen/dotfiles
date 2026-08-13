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
- `docs/agentic-workflow.md` and `docs/shell-helpers.md` in this repo are the
  full reference for the captain workflow model and the `gwt`/`gwta`/`wtd`
  worktree commands — `~/.claude/CLAUDE.md` enforces the summary, don't
  duplicate the detail here.
- No standalone `~/dotfiles` clone exists or should be made — it drifts from
  this source and has caused confusion before.

## Projects — `~/projects/<name>`

Flat, one directory per top-level project, no nested grouping folder.

- `~/projects/jdwlabs/` — the `jdwlabs` GitHub org, checked out as four
  independent sibling repos, not a monorepo: `apps/`, `deployments/`,
  `infrastructure/`, `platform/`. Each has its own remote; treat them as
  unrelated repos that happen to share a parent folder.

## Worktrees — `~/worktrees/<project>/<branch>`

`WT_BASE` (default `~/worktrees`) may not exist until the first `gwta` run —
its absence is not an error. Full command reference: `docs/shell-helpers.md`
in the dotfiles repo (see above).

## Ticket-aware Claude launch — `cj`

`cj` (defined in `home/dot_config/shell/functions.sh` in the dotfiles repo)
wraps `claude` to auto-resolve the Jira key from the current worktree/branch
and launch with `-n <KEY>`, so `/resume` and the tab title are scannable.
Deliberately not named `claude` — shadowing the real binary breaks
`claude agents --json`. Prefer `cj` over bare `claude` when inside a
ticket-named worktree.
