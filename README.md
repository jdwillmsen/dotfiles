# dotfiles

Personal development environment for Jake Willmsen — shell, git, and Claude Code, installable on any machine or devcontainer with a single script.

## Install

```bash
git clone https://github.com/jdwillmsen/dotfiles.git ~/dotfiles
~/dotfiles/install.sh
```

Each feature checks its own requirements and skips cleanly if they aren't met — the install never fails because of a missing tool.

## Structure

```
dotfiles/
├── features/          # one script per feature — the install unit
├── lib/utils.sh       # shared helpers sourced by every feature
├── shell/             # shell config: aliases, exports, functions
├── claude/            # Claude Code: settings, CLAUDE.md, commands, hooks
├── codex/             # Codex: global AGENTS.md, status line, and personal skills
├── scripts/           # compiled tools (claude-status Go binary)
├── gitconfig          # git identity, aliases, sane defaults
├── gitignore_global   # global gitignore
├── zshrc / bashrc     # shell entry points — source shell/
└── install.sh         # runs each feature in order
```

## Features

| Feature | What it installs | Requires |
|---------|-----------------|----------|
| `shell` | `~/.zshrc`, `~/.bashrc` → `shell/` aliases, exports, functions | — |
| `git` | `~/.gitconfig`, `~/.gitignore_global` | `git` |
| `claude-status` | Go status line binary + `statusLine` in `~/.claude/settings.json` | `go`, `python3` |
| `claude` | Settings merge, CLAUDE.md, slash commands, hooks → `~/.claude/` | `python3` |
| `claude-mcp` | MCP server configs (Atlassian/Rovo) → `~/.claude/mcp.json` | `node`, `python3` |
| `claude-plugins` | Native Claude Code plugins (Caveman) via `claude plugin` | `git`, `claude` |
| `claude-rtk` | RTK output-filtering CLI | `cargo` or `brew` |
| `claude-skills-personal` | Personal Claude skills → `~/.claude/skills/` | — |
| `claude-plugins-personal` | Personal Claude plugins → `~/.claude/plugins/` | — |
| `codex` | Global Codex instructions + enriched TUI status line → `${CODEX_HOME:-~/.codex}/` | `python3` for status line |
| `codex-skills-personal` | Personal Codex skills → `${CODEX_HOME:-~/.codex}/skills/` | — |
| `tmux` | `~/.tmux.conf` | `tmux` |

See each `features/*.sh` for exactly what is linked and where.

## Adding a feature

1. Create `features/<name>.sh` — source `lib/utils.sh`, call `require` for any dependencies, use `symlink` to link files
2. Call `run_feature <name>` in `install.sh`
3. Add CI verification steps in `.github/workflows/ci.yml`

The feature will skip gracefully if its requirements aren't present; it will never break the overall install.

## Claude Code status line

A three-line footer in the Claude Code prompt, built as a Go binary for fast startup. Shows model, git context, cost, session duration, context window fill (color-tiered to auto-compact threshold), rate limits, cache stats, and more.

Source: `scripts/claude-status/main.go`. Rebuild after editing:

```bash
cd scripts/claude-status && go build -o ~/.local/bin/claude-status .
```

## GitHub Codespaces

Add this repo under **Settings → Codespaces → Dotfiles**. Codespaces will clone it and run `install.sh` automatically on every new environment.
