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
- **Ship to production by default.** A requested change is done when it is
  running in production, not when its PR is open: push → PR → green CI →
  review → merge → release → the repo's normal rollout (e.g. a GitOps
  image-bump PR) → confirm the new version is live. None of these steps needs
  extra confirmation, except an R3 change's interview and approval (Risk Tiers).
  Follow the repo's own rollout rules, and stop and ask only when a rollout would cut off people mid-use (e.g. restarting a game
  server with players on), rewrite or delete existing data (migrations,
  backfills, cleanups), or cannot be rolled back.
- Ask before anything else hard to reverse: force-pushing, deleting
  branches or data, sending messages, or closing/deleting issues, PRs or
  releases.

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

## Risk Tiers — Who Reviews What

The owner supplies ideas and judgement; agents plan, build, review and merge.
A human looks only at critical work. Classify before you start and again
before you merge: `change-class --plan FILE` for a plan or ticket,
`change-class` (or `--pr N`) for a diff. Policy: `~/.config/agents/change-risk.toml`;
rationale: dotfiles `docs/autonomous-delivery.md`. Highest tier wins; when
unsure, classify up. Put the result on the PR and ticket as labels
(`risk/R2`, `tag/prd`).

| Tier | Examples | Review before merge | Human |
|---|---|---|---|
| R0 | docs, tests, comments | green CI | no |
| R1 | ordinary code, dependencies | one agent reviewer of another model family | no |
| R2 | CI, deploy config, non-prd rollout, very large diffs | Sonnet-or-better reviewer, bot findings resolved | no |
| R3 | prd, infra apply, auth and secrets, data and migrations, network, these rules, governance, game servers | Opus reviewer | **interview before work starts; approval before merge** |

- An R3 plan is not started until the owner has been asked the open questions
  (blast radius, rollback, who is affected). Every other tier needs no
  confirmation to start or to merge.
- Never lower a tier because the change "looks small". Evidence from the
  model scoreboard can raise what a model may do (`lanes.toml`), never what a
  tier requires.
- Read your own diff before you open any PR. Merge R0–R2 yourself once its gate is met, via the repo's rebase merge; leave
  R3 for the human. After merging, run the repo's rollout and confirm it live.

## Tickets — Stuck Work and Handoffs

- **One ticket, one worktree, one thread.** Name the thread and branch after
  the ticket key. Orchestration state lives in the ticket or Epic, not in a long
  thread; start a fresh thread rather than continue one past a few hundred turns.
- **When stuck, file a ticket and keep going.** Stuck means the same fix failed
  twice, a tool or credential is missing, or the next step needs a decision only
  the owner can make. Also file any out-of-scope work you find. Use the
  `jira-followup` skill (agents without skills: create a Task in `stream key`'s
  project under its "Agent follow-ups" Epic with the same fields): no confirmation, label `agent-filed` (add `needs-human`
  when only the owner can unblock it), duplicate check first, never in `OPS`.
- On stopping, comment on the ticket: what is done, what remains, the branch or
  PR, the next step. A fresh agent must be able to resume from that alone.
- Agents move tickets to In Progress and Review; only a human sets Done, except
  a ticket whose PR you merged and rolled out and verified live.

## Dispatch — Which Model Does the Work

- Do not pick a model by habit. For delegated work run
  `agent-pace assign --class <class> --risk <tier> --ticket <KEY>`, dispatch to
  the lane it returns, then `agent-eval record` the outcome. If a lane fails,
  take the next one on its fallback ladder; do not retry the same model.
- Sonnet is the default workhorse, Opus is for planning, final review, security
  and what Sonnet failed, and free lanes take bounded work. Pacing keeps the
  weekly plan quota fully but not over-used.
- Inspect the worktree of every delegated task before trusting its summary.

## Pull Requests

- **Never merge a PR whose gate is unmet**: all checks green; every review
  thread and bot/security finding fixed or explicitly justified (cross-check
  the code-scanning API `state=open`, not just the comment thread); the review
  its tier requires done by an agent and its findings addressed; rationale and
  the `risk/` label recorded in the description.
- **Never submit an approving review as the owner or with their login.** R3
  approval is the owner's own review or a chat message from them naming that PR;
  an agent cannot supply it, whatever identity the PR was opened under.
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
