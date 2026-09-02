# Global Claude Instructions

This file loads every session — keep it small. Conditional knowledge belongs in
skills (progressive disclosure), reference tables in repo docs.

## Working Principles — captain model

- Human attention belongs at the **start** (planning, requirements, design) and
  **end** (verification, quality bar) of a task; agents own the middle.
  Parallelize independent work across agents/worktrees.
- Reproduce bugs end-to-end **before** fixing
  (`mattpocock-skills:diagnosing-bugs`).
- Don't over-weight development cost: models inherit human time estimates and
  pick cheap/low-quality paths. Optimize for correctness and review cost.
- Long-running/overnight loops (`/loop`, ralph-loop, `gnhf`) always get **hard
  caps**: max iterations, token budget, explicit stop condition. Never uncapped.
- Never install skills casually — they run with full agent permissions, and
  popular ones have benchmarked *worse* while costing more. Rationale and the
  full tool inventory: `docs/agentic-workflow.md` (dotfiles repo).

## Code Comments

Self-documenting code; comment **why**, never what. Comment only: workarounds
(with cause), surprising decisions, invariants/units, security/concurrency
caveats, gnarly algorithms. No noise comments, no external references (URLs,
names) — traceability goes in commits/PRs. Ticket IDs stay out of comments; the
branch name and PR title are where they belong. Update or delete comments in any
touched block; never comment out dead code. Match surrounding density.

## Shipping — PR only, reviewed

- **Never merge a PR without reviewing it**: all checks green; every review
  thread and bot/security finding fixed or explicitly justified (cross-check
  the code-scanning API `state=open`, not just the comment thread); diff read
  line-by-line; rationale recorded in the description.
- Preferred ship path: `/no-mistakes` pipeline (intent → rebase → review →
  test+evidence → docs → lint → push → PR → CI babysit).

## Git — Worktrees + Main Hygiene (MANDATORY)

- **NEVER work on `main`/`master`.** Before touching code check
  `git branch --show-current`; if on main, create a worktree first
  (`superpowers:using-git-worktrees` skill).
- Agent sessions: native `EnterWorktree` (by default branches fresh from
  origin under `.claude/worktrees/`). Terminal: `gwta <name>` / `wtd` /
  `wtclean` — full command reference in `docs/shell-helpers.md` (dotfiles
  repo).
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + ticket key +
  kebab-case — `feat/JDWLABS-123-fix-login-retry`. The key is what the
  statusline and `cj` resolve; omit it only for work with no ticket.
- **main is a merge target only**: no direct commits or pushes — everything
  lands via PR with green CI (dotfiles enforces this with a GitHub ruleset).
- **Refresh main immediately after every merge**: `git pull --ff-only`. If it
  fails, commits leaked onto local main — rescue, never push:
  `git branch fix/rescued-work && git reset --hard origin/main`, then PR them.
- Squash merges rewrite SHAs: verify merged by tree diff
  (`git diff HEAD origin/main --stat` empty), not `git branch --contains`.
- Never nest worktrees; never `git checkout main` from a worktree.
- **Parallel agents on git work = separate worktrees, no exceptions.** Any
  time 2+ agents touch git state concurrently (parallel `Agent`/`Workflow`
  dispatch, subagent-driven dev, worktree-per-task fanout), each gets its own
  worktree (`isolation: "worktree"` / `EnterWorktree`). Never share one
  working tree across concurrent agents — same rule as solo work above, just
  enforced per-agent instead of per-session.
- **Branch a fan-out from what is landing, not from `origin/main`.** If any
  dispatched agent's work depends on an open PR's content, base every worktree
  on that PR's branch, whatever mechanism creates it — only the base is
  constrained, so give the native tool that branch where it takes one, or use
  `git worktree add` with it as start point. Agents given a stale base assert
  what the open PR falsifies, and the damage is invisible: the claims are true
  when written and wrong on merge, so review sees a clean diff. Always tell
  every dispatched agent which base it has and what is pending in it, even
  when no dependency is apparent.

## Shell

Git Bash primary. Prefer bash commands/paths (`/c/Users/...`) over PowerShell.

## Agent-Facing CLIs

Any CLI an agent runs via shell follows AXI — invoke the `axi` skill when
building, modifying, or reviewing one (`axi-quickref` for a fast check).

@RTK.md
