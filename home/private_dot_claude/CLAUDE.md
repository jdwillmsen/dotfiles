# Global Claude Instructions

Loads every session — keep it small; detail goes in skills or dotfiles `docs/`.
Rules every agent shares are imported below; this file holds only what is
specific to Claude Code.

@~/.config/agents/AGENTS.md

## Working Principles — captain model

- Human attention belongs at the **start** (planning, requirements, design) and
  **end** (verification, quality bar) of a task; agents own the middle.
  Parallelize independent work across agents/worktrees.
- Bugs: reproduce first with `mattpocock-skills:diagnosing-bugs`.
- Subagents default to Sonnet; pass `model: "opus"` for review,
  architecture, security and hard debugging.
- Long-running/overnight loops (`/loop`, ralph-loop, `gnhf`) always get **hard
  caps**: max iterations, token budget, explicit stop condition. Never uncapped.
- Never install skills casually — they run with full agent permissions, and
  popular ones have benchmarked *worse* while costing more. Rationale and the
  full tool inventory: `docs/agentic-workflow.md` (dotfiles repo).

## Claude Code Specifics

- Preferred ship path: `/no-mistakes` pipeline (intent → rebase → review →
  test+evidence → docs → lint → push → PR → CI babysit). Rewrite the long body
  it generates to the PR-body rule (`gh pr edit --body-file`).
- Worktrees: native `EnterWorktree` in agent sessions (branches fresh from
  origin); `superpowers:using-git-worktrees` when one is needed mid-task.
  Concurrent subagents touching git each get `isolation: "worktree"`. Neither
  takes a start point: for a fan-out over an open PR, create the worktrees
  with `git worktree add` from the PR branch instead.
- Agent-facing CLIs: invoke the `axi` skill when building, modifying, or
  reviewing one (`axi-quickref` for a fast check).

@RTK.md
