# Shared Agent Rules

Claude Code (by import), Codex, OpenCode and Grok (as a rendered copy) load
this file; Cursor's CLI and Antigravity see only repo `AGENTS.md` files. Rules
here must hold for any model; tool-specific rules live in that tool's own file. Devbox layout:
`~/AGENTS.md`.

## Working Style

- Be concise. Fix what was asked — no unsolicited refactors or speculative
  features.
- Reproduce a bug end-to-end before fixing it, and run the check that proves
  a fix before calling it done. Report failures with their output.
- Optimize for correctness and review cost, not development time: models
  inherit human time estimates and pick cheap, low-quality paths.
- Ask before anything hard to reverse: force-pushing, deleting branches or
  data, deploying, sending messages, or closing/deleting issues, PRs or
  releases. The normal push → PR → CI flow needs no extra confirmation.

## Code Comments

Self-documenting code; comment **why**, never what. Comment only: workarounds
(with cause), surprising decisions, invariants/units, security/concurrency
caveats, gnarly algorithms. No noise comments, no external references (URLs,
names) — traceability goes in commits/PRs. Ticket IDs stay out of comments; the
branch name and PR title are where they belong. Update or delete comments in any
touched block; never comment out dead code. Match surrounding density.

## Git — Worktrees + Main Hygiene

- **Never work on `main`/`master`.** Check `git branch --show-current` before
  touching code; if on main, create a worktree first — `gwta` in an
  interactive shell (dotfiles `docs/shell-helpers.md`), otherwise
  `git worktree add <path> -b <branch> origin/main`.
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + ticket key +
  kebab-case — `feat/JDWLABS-123-fix-login-retry`. `stream key` prints the
  key for the current repo. Omit the key only for work with no ticket.
- **main is a merge target only**: no direct commits or pushes — everything
  lands via PR with green CI (dotfiles enforces this with a GitHub ruleset).
- **Refresh main immediately after every merge**: `git pull --ff-only`. If it
  fails, check `git status` first and stash or commit any uncommitted
  changes — the reset below destroys them. Then the cause is commits leaked
  onto local main — rescue, never push:
  `git branch fix/rescued-work && git reset --hard origin/main`, then PR them.
- Merging rewrites SHAs (rebase replays commits): verify merged by tree diff
  (`git diff HEAD origin/main --stat` empty), not `git branch --contains`.
- Never nest worktrees; never `git checkout main` from a worktree.
- **One worktree + branch per agent task**; never share one between
  concurrent agents or reuse one for unrelated work. Re-fetch `origin/main`
  before rebasing or pushing — another session may have pushed.
- **Branch a fan-out from what is landing, not from `origin/main`.** If any
  dispatched agent's work depends on an open PR, start every worktree from
  that PR's branch (`git worktree add <path> -b <branch> origin/<pr-branch>`;
  `gwta` takes no start point) and tell each agent its base and what is
  pending in it. A stale base yields claims the open PR falsifies, invisible
  in review because each diff reads fine alone.

## Commits

- Conventional Commits: `type(scope): description`. Atomic — one logical
  change each; split formatting, refactors, dependency bumps and behavior
  changes. Stage only the files that belong to the change.
- **Rebase merge, always** — every commit lands on `main` as-is and must stand
  alone. Tidy a messy branch locally before merging; resolve conflicts with
  `git rebase origin/main`, never a merge commit (rebase-merge drops it and
  the conflict returns).
- **AI attribution lives only in commit trailers** — mandatory there, never
  in source files, docs, PR titles, bodies or comments (no "Generated with"
  footer or robot emoji). Trailers survive rebase merge and stay queryable in
  `git log`. Name the exact agent and the model actually running, never a
  guessed or example one:
  - Claude Code: `Co-Authored-By: Claude <Model> <noreply@anthropic.com>`
  - Codex: `Co-Authored-By: Codex <codex@openai.com>`
  - Cursor: `Co-Authored-By: Cursor Agent <cursoragent@cursor.com>`
  - OpenCode: `Co-Authored-By: OpenCode <opencode@noreply.invalid>`
  - Grok: `Co-Authored-By: Grok <grok@noreply.invalid>`
  - plus `Assisted-by: <agent>:<model-id> [tools...]`, e.g.
    `Assisted-by: Codex:gpt-6-luna`. A subagent on another model adds its
    own `Assisted-by` line.

## Pull Requests

- **Never merge a PR without reviewing it**: all checks green; every review
  thread and bot/security finding fixed or explicitly justified (cross-check
  the code-scanning API `state=open`, not just the comment thread); diff read
  line-by-line; rationale recorded in the description.
- **A PR that needs an approving review is opened as the bot.** GitHub blocks
  self-approval and these repos have one maintainer, so one opened under the
  human's `gh` auth can only merge by bypass. Before `gh pr create`,
  check the base branch for a required approval or CODEOWNERS gate in both
  rulesets (`gh api repos/<owner>/<repo>/rules/branches/<base>`) and classic
  protection (`.../branches/<base>/protection`); an access error is not a
  "no". If gated, author it as `jdwlabs-agent-bot` (jdwlabs repos; elsewhere,
  say so first). Method: dotfiles `docs/bot-authored-prs.md`.
- Title `type(scope): short description`, under 70 chars. **Body is for the
  reviewer, ~150 words max**, only sections with content: *Why* (1–3 sentences); *Needs attention* —
  risky spots as `file:line` and the feedback wanted; *Risk/rollout* only if
  any; *Verified* — what was actually run, one line each. No file-by-file
  lists, restated diff, pasted prompts, logs or unticked checkboxes. Every
  claim must match the final diff — rewrite the body after the last push.

## Devbox

- Never run a command that mints, prints or exchanges a credential through
  your shell — the output persists in logs. Prepare everything, then hand the
  human the exact command for a separate terminal.
- Dotfiles are chezmoi-managed: edit `~/.local/share/chezmoi`, never the
  deployed file.
- Before trusting a clean-looking result from `rtk`, `gh`, `kubectl` or
  Windows `curl`, read `~/.local/share/chezmoi/docs/agent-tooling-traps.md`.
- On Windows, Git Bash is primary: bash commands and `/c/Users/...` paths.
- Any CLI an agent runs via shell follows AXI (agent-facing ergonomics:
  compact output, definitive empty states, structured errors, no prompts).
