# PR

Create a pull request for the current branch using the project's conventions.

## Instructions

1. Run `git log --format='%h %s%n%(trailers:key=Assisted-by,key=Co-Authored-By)' main..HEAD`
   (or `master..HEAD`). Every AI-assisted commit must carry `Co-Authored-By`
   and `Assisted-by: <agent>:<model-id>` trailers — amend any that are
   missing before opening the PR.
2. Run `git diff main...HEAD --stat` to see the full scope of changes.
3. Draft the PR:
   - **Title**: `type(scope): short description` — conventional commit style,
     under 70 chars.
   - **Body**, ~150 words max, only the sections that have content:

     ```markdown
     ## Why
     1–3 sentences: the problem and why this approach.

     ## Needs attention
     - `path/file.ext:42` — the risky or non-obvious spot, and what feedback you want

     ## Risk / rollout
     Migrations, breaking changes, flags, manual steps. Omit if none.

     ## Verified
     - `command that was run` — result

     Closes #123 / KEY-123
     ```

   - Omit: file-by-file change lists, anything the diff already says, pasted
     prompts, logs, unticked checkboxes, and any "Generated with" footer,
     emoji or AI attribution line (attribution lives in commit trailers).
   - Every claim must be true of the final diff.
4. Use `gh pr create --title ... --body-file <file>`.
