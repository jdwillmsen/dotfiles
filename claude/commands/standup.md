# Standup

Generate a concise standup update from recent git activity across repos.

## Instructions

1. Run `git log --oneline --since="yesterday" --author="Jake Willmsen"` in the current repo (and any other repos mentioned).
2. Group commits by repo/project.
3. Summarize into standup format:

**Yesterday:**
- [bullet per meaningful chunk of work, not per commit]

**Today:**
- [ask me what's planned, or infer from open PRs / recent branch names if visible]

**Blockers:**
- None (unless I mention one)

Keep it to 3–5 bullets total. Engineering-team language, not commit message language.
