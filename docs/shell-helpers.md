# Shell Helpers Reference

Worktree helpers, sourced automatically in both shells. Moved out of the global
CLAUDE.md so sessions don't pay the token cost of reference tables; the hard
rules live there, the lookup detail lives here.

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
wtclean                 # remove all merged-branch worktrees
```

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
