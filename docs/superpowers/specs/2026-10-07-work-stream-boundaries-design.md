# Work Stream Boundaries — Design

## Problem

Work for three separate businesses is tracked and laid out as if it were one.

- **Jira** has two projects: `JDWLABS` (754 issues) and `CAREER` (39). Personal
  repo work — gameops and Minecraft, dotfiles, usersrole, T3 — is filed in
  `JDWLABS`, so that board mixes the org's platform work with personal work.
- **`~/projects`** is mostly flat. Personal repos sit beside `jdwlabs/`, and
  `jdwlabs/` itself holds two repos the `jdwlabs` org does not own
  (`jdw-deployments`, a second clone of `minecraft-server-agent`).
- **`~/worktrees`** is flat by repo basename, so `jdwlabs/platform` and
  `dotablaze-tech/platform` would collide.
- **Tooling** encodes the single-stream assumption: `jira-create` hardcodes
  `project = JDWLABS`, `__wt_project` is a folder basename, and
  `~/.config/claude-jira.json` — which `cj` and the statusline read for project
  keys — does not exist on this box, so ticket resolution is currently inert.

The result is that no view shows one business on its own, and none shows all
of them side by side.

## Goal

Three streams — `jdwillmsen`, `jdwlabs`, `dotablaze-tech` — each with its own
Jira project and board, its own folder group and its own worktree namespace,
derived from one rule. Career remains a distinct sub-stream of `jdwillmsen`.
One admin overview shows all streams together. Every helper, skill and doc in
dotfiles reflects the structure, and the box is left clean.

## Non-goals

- GitHub Projects boards. Jira is the only board system.
- Changing how any one stream works internally (workflow states, issue types,
  the jdwlabs repo split).
- Moving closed tickets. `JDWLABS` history stays where it is.
- Renaming or transferring GitHub repos between owners.

## The rule

**A piece of work belongs to the stream of the GitHub owner of its repo.**

`git remote get-url origin` yields `<owner>/<repo>`; everything else derives
from `<owner>`. A fork belongs to the fork's owner (`jdwillmsen/no-mistakes`),
whatever `origin` currently points at. Work with no repo (brand, admin) belongs
to the stream of the business it serves and is filed by hand.

| Stream | Jira project | Folder | Worktrees |
|---|---|---|---|
| `jdwillmsen` | `JDW` (new) | `~/projects/jdwillmsen/<repo>` | `~/worktrees/jdwillmsen/<repo>/<branch>` |
| ↳ career | `CAREER` (existing) | `~/projects/jdwillmsen/career` | `~/worktrees/jdwillmsen/career/<branch>` |
| `jdwlabs` | `JDWLABS` (existing) | `~/projects/jdwlabs/<repo>` | `~/worktrees/jdwlabs/<repo>/<branch>` |
| `dotablaze-tech` | `DOTA` (new) | `~/projects/dotablaze-tech/<repo>` | `~/worktrees/dotablaze-tech/<repo>/<branch>` |

Career is the one per-repo override: owner `jdwillmsen`, project `CAREER`.

## Stream map

One tracked file, `home/dot_config/streams.json`, is the source of truth:

```json
{
  "streams": {
    "jdwillmsen":     { "jira": "JDW",     "repoOverrides": { "career": "CAREER" } },
    "jdwlabs":        { "jira": "JDWLABS" },
    "dotablaze-tech": { "jira": "DOTA" }
  }
}
```

It holds owner names and project keys only. The Jira site host stays in the
machine-local, untracked `~/.config/claude-jira.json`, whose `projects` list is
generated from the stream map by a chezmoi `run_onchange_` script so the two
cannot drift. That file is created on this box as part of this work.

Consumers: `worktree-helpers.sh`, `cj`, the statusline, `jira-create`,
`agent-audit`.

## Jira

1. Create `JDW` ("jdwillmsen") and `DOTA` ("dotablaze-tech") as team-managed
   Kanban projects matching `JDWLABS` issue types and columns.
2. Rename board "KAN board" to "JDWLABS board".
3. Move open personal-repo epics and their open children from `JDWLABS` to
   `JDW`. Classification is by the repo each epic targets. The candidate list
   is produced first and signed off by the owner before any issue moves. Old
   keys redirect; moved issues get a comment recording the old key.
4. Cross-stream dependencies use issue links (`blocks` / `is blocked by`), not
   shared epics. An epic lives in exactly one project.

### Overviews

| View | Scope | Form |
|---|---|---|
| Personal stream | `project in (JDW, CAREER)` | Saved filter |
| All streams | `project in (JDW, CAREER, JDWLABS, DOTA)` | Saved filter + dashboard |

The **All streams dashboard** is the admin view. Per stream it shows open
issues by status, in-progress work, and issues created versus resolved over 30
days; across streams it shows a project × status table and everything currently
In Progress. It is a dashboard rather than a cross-project board because all
four projects are team-managed: each owns its own statuses, and a board over
them needs a hand-kept status-to-column mapping that breaks whenever one
project's workflow changes.

Whether the available Atlassian API can create dashboards and gadgets is
unverified. If it cannot, the plan supplies the filters and exact gadget
settings for a one-time manual build.

## Box layout

Moves into `~/projects/jdwillmsen/`: `career`, `countdown-app`, `gameops`,
`no-mistakes`, `minecraft-afk-bot`, `mc-console-bridge`,
`minecraft-server-agent`, `usersrole`, `usersrole-nx`, and `jdw-deployments`
(out of `jdwlabs/`).

`~/projects/jdwlabs/` keeps `apps`, `deployments`, `infrastructure`,
`platform`, `.github`, `.github-private`.

`~/projects/dotablaze-tech/` gets fresh clones of `deployments` and `platform`.

Dotfiles stay at chezmoi's source dir and belong to the `jdwillmsen` stream.

Worktrees move to `~/worktrees/<owner>/<repo>/<branch>` with
`git worktree move`, which keeps each repo's registrations valid. A main
checkout that moves is followed by `git worktree repair`.

Claude Code keys session history and project memory by absolute path. For each
moved repo and worktree, the matching `~/.claude/projects/<encoded-path>`
directory is renamed to the new encoding so `/resume` and memory survive.

## Tooling changes (all in chezmoi source)

- `worktree-helpers.sh` — `__wt_project` returns `<owner>/<repo>` from the
  origin remote, falling back to the basename when there is no remote. Listing
  and cleanup walk two levels.
- `cj` and `claude-status` — no logic change; they gain the keys through the
  generated `claude-jira.json`. Tests add `JDW`, `DOTA` and `CAREER` cases.
- `jira-create` skill — resolves the project from the current repo's owner via
  the stream map; asks when run outside a repo. Hardcoded `JDWLABS` JQL and
  examples become the resolved key.
- `agent-audit` — globs `projects/*/*/AGENTS.md` instead of `projects/jdwlabs/*`.
- Aliases — `jlabs` kept; `jdw` and `dota` added.
- Docs — `home/AGENTS.md` (devbox map: three grouping folders, new worktree
  path), `private_dot_claude/CLAUDE.md` (branch key is the stream's project
  key), `docs/shell-helpers.md`, `docs/agentic-workflow.md`.
- Sweep — every remaining `projects/<name>`, `worktrees/<name>` and `JDWLABS`
  reference in dotfiles and in each repo's `AGENTS.md` is checked and either
  updated or confirmed stream-correct.

## Cleanup

Each item is inventoried first; nothing is deleted without owner sign-off on
the specific list.

- `~/projects/.git` — empty repo, no commits, no remote: remove. Root-level
  `.aider.*`, `.playwright-mcp`, `.remember`, `.superpowers`, `.env`,
  screenshots and the mp4: inventory, then delete or relocate per sign-off.
- `~/projects/test` — no remote: inventory, then decide.
- `~/projects/jdwlabs/minecraft-server-agent` — a diverged second clone with
  unpushed commits. Compare against the primary clone; rescue anything unique
  to a branch before removal.
- Archived-repo clones — hold dirty and unpushed work. Push or discard per
  repo, then remove the local clone.
- Stale worktrees — merged branches removed with `wtclean`; the legacy
  `~/worktrees/dotfiles`, `~/worktrees/jdwlabs-platform`, `~/worktrees/platform`
  and loose log files under `~/worktrees/apps` folded in or removed.
- Stale `~/.claude/projects/` entries pointing at paths that no longer exist
  (`-home-dev-admin-Dev-…`) — listed for sign-off.

## Order

1. **Tooling, dual-layout.** Stream map, helpers and skill land and work with
   both old and new paths. Merged and applied before anything moves.
2. **Jira structure.** New projects, board rename, filters, dashboard.
3. **Box moves.** One repo at a time: main checkout, its worktrees, its Claude
   project dirs; verify; next repo. `dotablaze-tech` clones.
4. **Ticket migration.** Signed-off list moved to `JDW`.
5. **Cleanup.** Inventories, sign-off, removal.
6. **Docs sweep.** Final pass so every reference matches the end state; drop
   the old-layout fallback from the helpers.

## Risks

- **In-flight sessions.** `gameops` has 31 worktrees and `jdw-deployments` 23.
  A move pulls the working directory out from under any live agent. Each repo
  moves only after `claude agents --json` shows no session inside it.
- **Absolute paths outside git.** tmux sessions, systemd units, cron, editor
  workspaces and `no-mistakes` state may hold old paths. Phase 3 greps for each
  old path across `~/.config`, `~/.local`, `~/.claude` and unit files before
  and after a move.
- **Old keys on open branches.** A branch named `feat/JDWLABS-734-…` keeps
  showing the old key until it merges. Accepted; Jira redirects it.
- **Untracked files inside moved repos** move with the directory and are not
  at risk; nothing is re-cloned.

## Verification

- From a repo in each stream, `gwta` creates a worktree under
  `~/worktrees/<owner>/<repo>/`, and `cj` on a ticket branch launches with that
  stream's key.
- `jira-create` run in `gameops` targets `JDW`; in `platform`, `JDWLABS`; in
  `career`, `CAREER`.
- For every moved repo: `git worktree list` shows no `prunable` entry,
  `git status` matches its pre-move snapshot, and unpushed-commit counts are
  unchanged.
- `/resume` in a moved repo lists its earlier sessions.
- The JDWLABS board shows no issue whose epic targets a `jdwillmsen` repo.
- The All streams dashboard shows all four projects.
- `chezmoi apply` is a no-op afterwards and `git status` in the source is clean.
- A grep for the old flat paths across dotfiles and each repo's agent docs
  returns nothing.
