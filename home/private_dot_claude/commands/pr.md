# PR

Create a pull request for the current branch using the project's conventions.

## Instructions

1. Run `git log --oneline main..HEAD` (or `master..HEAD`) to see all commits in this branch.
2. Run `git diff main...HEAD --stat` to see the full scope of changes.
3. Draft a PR using these rules:
   - **Title**: `type(scope): short description` — conventional commit style, under 70 chars
   - **Summary**: 2–4 bullets covering *what* and *why*, not *how*
   - **Test plan**: checklist of what to verify
   - **Breaking changes**: call out anything that changes APIs, schemas, or contracts
4. Use `gh pr create` with the drafted title and body.

Keep the description tight. Reviewers read diffs — the PR body should give context the diff can't.
