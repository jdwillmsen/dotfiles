# Personal Codex Instructions

## Working Style

- Be concise by default. Get to the point and avoid restating obvious diffs.
- Fix the requested issue without unsolicited refactors or speculative features.
- Add comments only when the why is genuinely non-obvious; avoid comments that restate the code.
- Ask before destructive actions such as force-pushing, dropping data, deleting branches, or anything hard to reverse.

## Git

- Work in a git worktree on a dedicated feature branch before touching code. Never commit directly to `main` or a repo's default branch.
- When asked to commit, use Conventional Commit messages: `type(scope): description`.
- Keep commits atomic: one logical change, reviewable on its own. Repos merge rebase-only, so every commit lands on `main` as-is; resolve conflicts with `git rebase origin/main`, never a merge commit.
- Split unrelated formatting, refactors, dependency updates, and behavior changes into separate commits.
- Stage only the files that belong to the logical change being committed.
- AI attribution in commits is mandatory. Every commit Codex (or any AI agent) contributed to names the exact agent and model in trailers, so provenance stays queryable in `git log`:
  - `Co-Authored-By: Codex <codex@openai.com>`
  - `Assisted-by: Codex:<model-id> [tools...]` — the model actually running, never a guessed or example one.
  - Other agents follow the same shape with their own name and model (Claude: `Co-Authored-By: Claude <Model> <noreply@anthropic.com>`, `Assisted-by: Claude Code:<model-id>`).
- Attribution lives only in commit trailers — never in source files, docs, PR titles, PR bodies or PR comments. No "Generated with" footers or robot emoji in PR text.

## Pull Requests

- Title: `type(scope): short description`, under 70 chars.
- Body is for the reviewer, ~150 words max, only sections with content: **Why** (1–3 sentences), **Needs attention** (risky or non-obvious spots as `file:line`, and the feedback wanted), **Risk / rollout** (only if any), **Verified** (commands actually run, one line each).
- No file-by-file lists, restated diff, pasted prompts, logs or unticked checkboxes. Every claim must match the final diff; rewrite the body after the last push.

## Devbox

- Never run a command that mints, prints or exchanges a credential (tokens, auth codes, QR codes, API keys) through your shell — the output persists in logs. Prepare everything, then hand the human the exact command to run in a separate terminal.
- Dotfiles are chezmoi-managed: edit `~/.local/share/chezmoi`, never the deployed file. Devbox layout: `~/AGENTS.md`.
- Before trusting a clean-looking result from `rtk`, `gh`, `kubectl` or Windows `curl`, read `~/.local/share/chezmoi/docs/agent-tooling-traps.md` — those tools have printed success, stale state or truncated output here.
