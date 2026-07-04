# Global Claude Instructions

## Code Comments — MANDATORY

Stance: **self-documenting code; comment _why_, never _what_.** Per Google Engineering Practices, *Software Engineering at Google* (ch. 8), *Clean Code*.

1. **Why, not what.** Code shows _what_. Comments capture intent code can't: trade-offs, business rules, non-obvious constraints, "why this not obvious alternative." Never paraphrase code.
2. **Clarify code before commenting.** Try better name, smaller function, clearer structure first. Comment only when code can't carry meaning.
3. **Comment non-obvious — expected:** workarounds (with cause), surprising decisions, `switch` fall-through, intentionally-empty catch blocks, gnarly regex/algorithms, units & invariants, security/concurrency caveats.
4. **No noise comments.** Delete comments restating code, echoing name, narrating obvious steps.
5. **Comment rot is enemy.** Comments change with code — stale comment worse than none. Update/delete comments in any touched block. Never comment-out dead code; delete (version control remembers).
6. **No external references in comments** — issue keys (`JDWLABS-123`, `#123`), ticket/PR URLs, person names. They rot. Traceability goes in **commit messages and PR descriptions**; rationale inline (e.g. "Raised from 512Mi: was OOM-killed under churn"). Applies to all languages/config (YAML, HCL, Dockerfiles, etc.).
7. **TODO/FIXME:** concrete, actionable — no ticket link. Sparingly.
8. **Doc comments** (public API) where value beyond signature — contract, intent, usage; keep accurate.
9. **Match surrounding comment density and idiom.**

## PR Review Before Merge — MANDATORY

**Never merge a PR without reviewing all of its content first.** Applies to every merge, including admin/bypass merges and your own PRs.

Before merging, verify:
1. **All checks green** — CI, status checks, required contexts. No merging on red or pending.
2. **Every review suggestion addressed** — read all inline comments, review threads, and bot/security findings (CodeQL, advanced-security, Dependabot, linters). Each must be either fixed in the diff or have an explicit written justification for why it's safe to dismiss. Never merge with an open, unaddressed suggestion.
3. **Stale vs live** — when a suggestion persists after a fix, confirm it's stale (re-anchored to a new line, alert resolved/closed) and not a fresh finding. Cross-check the code-scanning alerts API (`state=open`), not just the PR comment thread.
4. **Diff sanity** — read the actual changed lines; confirm they match the PR's stated intent, nothing unintended slipped in.
5. **Justification recorded** — the PR description (and commit messages) explain *why*, and any dismissed suggestion has its rationale captured.

Only after all of the above: merge. If anything is unaddressed or unclear, fix it or surface it — do not merge.

## Git Worktree Policy — MANDATORY

**NEVER work on `main`/`master`.** All feature work, fixes, experiments use git worktrees.

### Pre-work Checklist

Before touching code:
1. Run `git branch --show-current` — if `main`/`master`, STOP, create worktree
2. Check `GIT_DIR` vs `GIT_COMMON_DIR` — if different (not submodule), already in worktree
3. Invoke `superpowers:using-git-worktrees` skill for isolated workspace setup

### Branch Naming — `feat/<description>`

| Type | Pattern | Example |
|------|---------|---------|
| Feature | `feat/<name>` | `feat/auth-jwt` |
| Bug fix | `fix/<name>` | `fix/null-session` |
| Chore | `chore/<name>` | `chore/update-deps` |
| Docs | `docs/<name>` | `docs/api-reference` |
| Refactor | `refactor/<name>` | `refactor/auth-module` |

### Worktree Location

Two locations, by tool:

- **Native `EnterWorktree` (agent sessions — preferred):** `.claude/worktrees/<name>` inside the repo, created/cleaned by the tool. Branches from `origin/<default-branch>` by default, so it's always fresh.
- **Shell helpers (`gwta`, terminal use):** `~/worktrees/<project>/<type>/<name>` — global, outside repo. Override: `export WT_BASE=~/worktrees` in `.bashrc` (already default).

```
~/worktrees/
└── myapp/
    ├── feat/auth-jwt/       ← worktree (shell)
    └── fix/null-session/    ← worktree (shell)

/c/repos/myapp/              ← main checkout (merge target only)
└── .claude/worktrees/       ← worktrees (native tool)
```

### Creation Flow

```bash
# Agent session — native tool (handles branch, placement, cleanup):
EnterWorktree feat/<name>

# Terminal — shell helper:
gwta auth-jwt          # → ~/worktrees/myapp/feat/auth-jwt
gwta fix/null-session  # → ~/worktrees/myapp/fix/null-session

# Manual fallback:
git fetch origin && git worktree add ~/worktrees/<project>/feat/<name> -b feat/<name> origin/main
```

### Cleanup Flow (after PR merge)

```bash
# Agent session: verify merged, then ExitWorktree(remove).
# Squash merge rewrites the SHA — `git branch --contains` lies. Compare trees:
git fetch origin main && git diff HEAD origin/main --stat   # empty = merged, safe to remove

# Terminal:
wtd feat/<name>    # removes worktree + deletes branch
wtclean            # or bulk: all merged branches
```

### Main Branch Hygiene — MANDATORY

`main`/`master` is a **merge target only**:

- **Never commit or push directly to main.** Every change lands via PR with green CI. (dotfiles repo enforces this with a GitHub ruleset — direct pushes are rejected; treat the same as policy everywhere.)
- **Refresh main after every merge:** from the main checkout, `git pull --ff-only`. Do this immediately post-merge so the next worktree branches from current state.
- **`--ff-only` fails ⇒ commits leaked onto local main.** Rescue them onto a branch and PR them — never push them directly:
  ```bash
  git branch fix/rescued-work && git reset --hard origin/main
  ```
- **Before creating a worktree:** `git fetch origin` and branch from `origin/main` (native `EnterWorktree` does this automatically).

### Rules

- Never nest worktrees (check if in one before creating)
- Never `git checkout main` — pull updates via `git fetch` from worktree
- No `.gitignore` changes — shell worktrees live outside repo; native ones under `.claude/`

---

## Shell Preference

**Primary shell: Git Bash.** Prefer bash commands, paths, scripts over PowerShell. Use `/c/Users/...` paths in bash context.

## Shell Helpers

Sourced automatically in both shells.

**Git Bash** (`~/.bashrc` → `~/.claude/scripts/worktree-helpers.sh`):
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

**PowerShell** (`~/.claude/scripts/worktree-helpers.ps1`):
```powershell
gwta auth-jwt [-Type feat|fix|chore|docs|refactor|test|ci]
wts          # Out-GridView selector (or fzf if installed)
wtd feat/auth-jwt [-Force] [-KeepBranch]
```

| Command | Action |
|---------|--------|
| `gwt` | List all worktrees |
| `gwta <name> [type]` | Create worktree under `~/worktrees/<proj>/<type>/<name>` |
| `wts` | Interactive switch (fzf or fallback) |
| `wtd <branch>` | Remove worktree + delete branch (tab-completes) |
| `wtp` | Prune stale metadata + fetch --prune |
| `wtclean` | Remove all merged-branch worktrees |

---

## Agent-Facing CLIs — AXI

When building, modifying, or reviewing **any CLI a coding agent runs via shell**, follow AXI (Agent eXperience Interface). Benchmarked to beat both raw CLI and MCP on success, cost, duration, and turns. Full guidance in the `axi` skill; reference impls: `npx -y gh-axi`, `npx -y chrome-devtools-axi`.

10 principles (efficiency / robustness / discoverability):

1. **Token-efficient output** — emit [TOON](https://toonformat.dev/) on stdout (~40% fewer tokens than JSON); convert at the output boundary, keep internal logic on JSON.
2. **Minimal default schemas** — 3–4 fields per list item; more via `--fields`.
3. **Content truncation** — cap large text, append size hint (`(truncated, N chars total — use --full)`).
4. **Pre-computed aggregates** — return `totalCount`, inline CI summaries, etc. to kill round-trips.
5. **Definitive empty states** — explicit zero-result message, never silent empty output.
6. **Structured errors & exit codes** — idempotent mutations; structured errors to **stdout**; never prompt interactively; `0` ok / `1` err.
7. **Ambient context** — install into session hooks/plugins so state is visible before the agent acts; ship a SKILL.md too.
8. **Content first** — no-args prints live actionable data (+ exec path + one-line description), not help text.
9. **Contextual disclosure** — append `help[]` next-step command templates with `<id>` placeholders.
10. **Consistent help** — every subcommand has a concise `--help` fallback.

@RTK.md
