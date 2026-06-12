# Personal Codex Instructions

## Working Style

- Be concise by default. Get to the point and avoid restating obvious diffs.
- Fix the requested issue without unsolicited refactors or speculative features.
- Add comments only when the why is genuinely non-obvious; avoid comments that restate the code.
- Ask before destructive actions such as force-pushing, dropping data, deleting branches, or anything hard to reverse.

## Git

- When asked to commit, use Conventional Commit messages: `type(scope): description`.
- Keep commits atomic. Each commit should represent one logical change and be reviewable on its own.
- Split unrelated formatting, refactors, dependency updates, and behavior changes into separate commits.
- Stage only the files that belong to the logical change being committed.
- If AI contributed to a commit, disclose that in commit/PR metadata. Never present AI-assisted work as entirely human-authored.
- Use the exact trailer `Co-Authored-By: <agent name> <email>` for visible coauthor attribution, and add Linux-style provenance with `Assisted-by: <agent>:<model> [tools...]` when the agent/model is known.
- For Codex-assisted commits, prefer `Co-Authored-By: Codex <codex@openai.com>` and `Assisted-by: Codex:<model>` unless the repository defines a different convention. For Claude-assisted commits, prefer `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>` and `Assisted-by: Claude:Sonnet-4.6`.
- Keep attribution out of source files, docs, and generated files by default unless the repository explicitly requires provenance there; commit/PR metadata is the normal place for attribution.
