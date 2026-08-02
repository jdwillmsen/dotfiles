# Shell Helpers Reference

Worktree helpers. Moved out of the global CLAUDE.md so sessions don't pay the
token cost of reference tables; the hard rules live there, the lookup detail
lives here.

Bash only. The script uses `mapfile` and 0-indexed arrays, neither of which zsh
provides, so `.zshrc` deliberately does not source it and the file returns early
if sourced by a non-bash shell. PowerShell has its own implementation below.

## Git Bash (`~/.bashrc` → `~/.claude/scripts/worktree-helpers.sh`)

```bash
gwt                     # list all worktrees (with dirty indicator)
gwta auth-jwt           # create ~/worktrees/<proj>/feat/auth-jwt
gwta fix/null-check     # create ~/worktrees/<proj>/fix/null-check
gwta auth-jwt fix       # explicit type as second arg
gwtr                    # jump back to root/main worktree
wts                     # interactive switch (fzf+preview or select)
wtst                    # status across all worktrees (dirty/ahead/behind)
wtd feat/auth-jwt       # remove worktree + delete branch (tab-completes)
wtd -f feat/auth-jwt    # force remove
wtd -k feat/auth-jwt    # keep branch, remove worktree only
wtp                     # prune stale metadata + fetch --prune
wtclean                 # remove merged-branch worktrees (prompts)
wtclean -n              # list what would be removed, change nothing
wtclean -y              # remove without prompting (required non-interactively)
```

### How `wtclean` decides a branch is merged

`git branch --merged` is not enough. Squash merges rewrite SHAs, so a
squash-merged branch never becomes an ancestor of the default branch and an
ancestry check reports nothing to clean — in a squash-only repo it can never
clean anything. `wtclean` tries ancestry first (correct and offline for
fast-forward and merge-commit workflows), then falls back to asking the forge:

```bash
gh pr list --head <branch> --state merged
```

Without `gh`, a squash-merged branch is reported unmerged and kept. That is
deliberate — the function deletes, so "no verdict" has to mean "keep".

Non-interactively (`[ ! -t 0 ]`), `wtclean` refuses and exits 2 rather than
prompting. A bare `read` on closed stdin returns empty, which reads as
"declined", and an agent would see a silent no-op that looks like success.

## PowerShell (`~/.claude/scripts/worktree-helpers.ps1`)

```powershell
gwta auth-jwt [-Type feat|fix|chore|docs|refactor|test|ci]
wts          # Out-GridView selector (or fzf if installed)
wtd feat/auth-jwt [-Force] [-KeepBranch]
```

## Worktree locations

- Shell helpers: `~/worktrees/<project>/<type>/<name>` — global, outside repo.
  Override with `export WT_BASE=~/worktrees` in `.bashrc` (already default).
- Native `EnterWorktree` (agent sessions): `.claude/worktrees/<name>` inside
  the repo, created and cleaned by the tool.

```
~/worktrees/
└── myapp/
    ├── feat/auth-jwt/       ← worktree (shell)
    └── fix/null-session/    ← worktree (shell)

/c/repos/myapp/              ← main checkout (merge target only)
└── .claude/worktrees/       ← worktrees (native tool)
```

## `cj` — ticket-named Claude Code launcher

Launches Claude Code named after the current worktree's Jira ticket, so the
`/resume` picker and terminal tab show `JDWLABS-123` instead of a derived name
like `dotfiles-1e`.

```bash
cj              # claude -n JDWLABS-123
cj --resume     # extra args pass straight through
```

Resolution order, matching the statusline exactly:

1. `$(git rev-parse --git-dir)/claude-jira-ticket` — per-worktree override
2. The branch name, gated on the project allowlist in
   `~/.config/claude-jira.json`

Falls back to a plain `claude` launch when no key resolves, when the config is
absent, or when the cwd is not a repo. The allowlist is what stops `SHA-256` and
`UTF-8` in a branch name from being mistaken for a ticket.

Deliberately **not** named `claude` — shadowing the real binary breaks
`claude agents --json` and recurses into itself.

`gwta` remains the way to create a worktree; `cj` is run from inside one.
Rename mid-session with `/rename`.

### `~/.config/claude-jira.json`

Machine-local and never tracked — the site host identifies the company and the
project keys name real projects:

```json
{ "siteBase": "https://example.atlassian.net", "projects": ["ABC", "DEF"] }
```

Missing or unparseable means the feature is entirely off: no statusline segment,
no `cj` naming. An empty `projects` list disables branch resolution
specifically; the override file still works, since it is explicit.
