# Contributing to dotfiles

## Commit Messages

This repo uses [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]
```

| Type | When to use |
|------|-------------|
| `feat` | New alias, function, or shell feature |
| `fix` | Bug fix or broken config |
| `chore` | Maintenance, deps, tooling |
| `docs` | Documentation only |
| `refactor` | Restructure without changing behavior |
| `perf` | Performance improvement (e.g. startup time) |
| `ci` | CI/CD pipeline changes |

**Scope:** the feature or module you're changing — use the feature name when in doubt.

**Examples:**
```
feat(aliases): add kubectl context switch shortcut
fix(claude-status): correct model version parsing for 4-part IDs
chore(install): skip claude-status build if Go < 1.21
docs(readme): update statusline segment table
```

## Branch Naming

```
<type>/<short-description>
```

**Examples:**
```
feat/tmux-config
fix/pyenv-path-order
chore/upgrade-go-module
```

## Adding Aliases or Functions

- **Aliases** go in `shell/aliases.sh` — group them with the related block (git, docker, kubectl, system)
- **Functions** go in `shell/functions.sh` — keep each function focused and self-contained
- **Env vars / PATH changes** go in `shell/exports.sh`

Test locally before opening a PR:

```bash
# Re-source to pick up changes
source ~/.zshrc   # or ~/.bashrc

# Then exercise the alias or function
```

## Modifying the Claude Code Status Line

The status line is a Go binary at `scripts/claude-status/main.go`. After editing:

```bash
cd scripts/claude-status
go build -o ~/.local/bin/claude-status .
```

Verify the output by piping a test JSON payload:

```bash
echo '{"model":{"id":"claude-sonnet-4-6","display_name":"Sonnet 4.6"},"cost":{"total_cost_usd":0.05}}' \
  | ~/.local/bin/claude-status
```

## Pull Requests

- Keep PRs focused — one concern per PR
- Link the relevant issue if one exists
- Ensure CI passes before requesting review
- Use the PR template and fill it out completely

## Reporting Issues

Use the issue templates — they exist for a reason. Fill them out fully.
