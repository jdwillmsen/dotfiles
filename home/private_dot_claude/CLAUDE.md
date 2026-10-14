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
- **Subagent models — Opus only where it changes the outcome.** Leave `model`
  unset (Sonnet, via `CLAUDE_CODE_SUBAGENT_MODEL`) for implementation,
  research, reports, data gathering and routine PR review. Pass
  `model: "haiku"` for search, summarizing and log reading. Pass
  `model: "opus"` only for a final pre-merge review, security review,
  architecture decisions, or a bug Sonnet already failed on — an unqualified
  "review" here once sent a third of all usage to Opus subagents.
- **Claude usage is the scarce resource.** Near the session limit, hand bulk
  or mechanical work to another provider (OpenCode on NVIDIA NIM or the LAN
  model, Codex) — routing table: dotfiles `docs/agentic-workflow.md`.
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
