# Global Claude Instructions

Loads every session — keep it small; detail goes in skills or dotfiles `docs/`.

## Working Principles — captain model

- Human attention belongs at the **start** (planning, requirements, design) and
  **end** (verification, quality bar) of a task; agents own the middle.
  Parallelize independent work across agents/worktrees.
- Reproduce bugs end-to-end **before** fixing
  (`mattpocock-skills:diagnosing-bugs`).
- Don't over-weight development cost: models inherit human time estimates and
  pick cheap/low-quality paths. Optimize for correctness and review cost.
- Subagents default to Sonnet; pass `model: "opus"` for review,
  architecture, security and hard debugging.
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
- **Rebase merge, always** — every repo is rebase-only, so each commit lands
  on `main` as-is and must stand alone. Tidy a messy branch locally before
  merging; resolve conflicts with `git rebase origin/main`, never a merge
  commit (rebase-merge drops it and the conflict returns).
- **AI attribution: mandatory in commits, never in PR text.** Every
  AI-assisted commit names the exact agent and model in trailers —
  `Co-Authored-By: <Model> <email>` plus `Assisted-by: <agent>:<model-id>`
  (e.g. `Assisted-by: Claude Code:claude-opus-5-5`); a subagent on another
  model adds its own line.
  Trailers survive rebase merge and stay queryable in `git log`; a PR footer
  does neither. PR titles, bodies and comments carry no "Generated with"
  footer, robot emoji or attribution line.
- **PR body is for the reviewer, ~150 words max**: *Why* (1–3 sentences);
  *Needs attention* — the risky or non-obvious spots (`file:line`) and the
  feedback wanted; *Risk/rollout* only if there is any; *Verified* — what
  was actually run, one line each. No file-by-file lists, restated diff,
  pasted prompts, logs or unticked template checkboxes. Every claim must
  match the final diff — rewrite the body after the last push, including
  the long body `/no-mistakes` generates (`gh pr edit --body-file`).

## Git — Worktrees + Main Hygiene

- **NEVER work on `main`/`master`.** Before touching code check
  `git branch --show-current`; if on main, create a worktree first
  (`superpowers:using-git-worktrees` skill).
- Agent sessions: native `EnterWorktree` (branches fresh from origin).
  Terminal: `gwta` / `wtd` / `wtclean` (dotfiles `docs/shell-helpers.md`).
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + ticket key +
  kebab-case — `feat/JDWLABS-123-fix-login-retry`. The key is what the
  statusline and `cj` resolve; omit it only for work with no ticket.
- **main is a merge target only**: no direct commits or pushes — everything
  lands via PR with green CI (dotfiles enforces this with a GitHub ruleset).
- **Refresh main immediately after every merge**: `git pull --ff-only`. If it
  fails, commits leaked onto local main — rescue, never push:
  `git branch fix/rescued-work && git reset --hard origin/main`, then PR them.
- Merging rewrites SHAs (rebase replays commits): verify merged by tree diff
  (`git diff HEAD origin/main --stat` empty), not `git branch --contains`.
- Never nest worktrees; never `git checkout main` from a worktree.
- **One worktree + branch per agent task.** 2+ agents touching git state
  concurrently each get their own (`isolation: "worktree"` / `EnterWorktree`);
  never share one, never reuse one for a second unrelated task. Re-fetch
  `origin/main` before rebasing or pushing — another session may have pushed.
- **Branch a fan-out from what is landing, not from `origin/main`.** If any
  dispatched agent's work depends on an open PR, start every worktree from
  that PR's branch (the routes above take no start point) and tell each agent
  its base and what is pending in it. A stale base yields claims the open PR
  falsifies, invisible in review because each diff reads fine alone.

## Shell

On Windows, Git Bash is primary: prefer bash commands and `/c/Users/...` paths
over PowerShell.

## Agent-Facing CLIs

Any CLI an agent runs via shell follows AXI — invoke the `axi` skill when
building, modifying, or reviewing one (`axi-quickref` for a fast check).

@RTK.md
