# dotfiles

Personal development environment for Jake Willmsen — shell, git, and Claude Code, managed with [chezmoi](https://www.chezmoi.io/) and installable on any machine or devcontainer with a single command.

## Install

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply jdwillmsen
```

You'll be prompted for a machine role (see Targets below). Re-running `chezmoi apply` is always safe — templates and scripts are idempotent.

## Secrets

Encrypted values (git work identity, etc.) are handled via age + pass. See [`docs/secrets.md`](docs/secrets.md) for key generation, storage, and CI setup.

## Targets

The source tree templates itself per machine, selected by a `machineRole` prompt at `init` time:

| Role | What differs |
|------|-------------|
| `personal` | Default identity, no extra work-only git config. |
| `work` | Work git identity + credential config layered in (`home/dot_gitconfig.tmpl`). |
| `ephemeral` | Auto-detected in CI/devcontainers/Codespaces (`CI`, `REMOTE_CONTAINERS`, `CODESPACES` env vars); also selectable explicitly. |

Other data derived automatically at init: `isWSL` (Windows Subsystem for Linux detection) gates WSL-specific templating.

## Structure

```
dotfiles/
├── .chezmoiroot          # points chezmoi at home/ as the source root
├── home/                 # chezmoi source state — everything below is templated/managed
│   ├── .chezmoi.toml.tmpl    # machineRole/isEphemeral/isWSL data + age config
│   ├── dot_*.tmpl            # ~/.bashrc, ~/.zshrc, ~/.gitconfig, ...
│   ├── dot_config/           # ~/.config/shell, ~/.config/git (encrypted work identity), ...
│   ├── private_dot_claude/   # ~/.claude — settings (merged), CLAUDE.md, commands, hooks
│   ├── private_dot_codex/    # ~/.codex — AGENTS.md, config.toml, skills
│   └── run_*                # side-effect scripts (TPM, Go build, MCP, plugins, rtk)
├── scripts/              # compiled tools (claude-status Go binary source)
├── tests/                # template unit tests, script unit tests, smoke test
└── docs/                 # secrets, tmux, and design docs
```

## Testing

```bash
bash tests/smoke.sh                                    # chezmoi apply into a temp HOME, assert key files
for t in tests/template/*.sh; do bash "$t"; done       # template rendering unit tests
for t in tests/scripts/*.sh; do bash "$t"; done        # run_* script unit tests
find home -name 'run_*.sh' -exec shellcheck -s bash {} +
```

## Claude Code status line

A three-line footer in the Claude Code prompt, built as a Go binary for fast startup. Shows model, git context, cost, session duration, context window fill (color-tiered to auto-compact threshold), rate limits, cache stats, and more.

When a session is launched through the CCR (claude-code-router) fallback tier via `ccrpick`, the footer reflects the *real* proxied backend instead of Claude Code's native labels: `⚡ <model>` with the provider, reasoning shown only when the route actually reasons, the routed model's context window (or tokens-only when the provider reports none), `FREE` in place of cost, and minimized rate limits. Native and opencode sessions are unaffected. Contract in [`docs/superpowers/specs/2026-07-14-ccr-fallback-statusline-design.md`](docs/superpowers/specs/2026-07-14-ccr-fallback-statusline-design.md).

Source: `scripts/claude-status/main.go`. Rebuild after editing:

```bash
cd scripts/claude-status && go build -o ~/.local/bin/claude-status .
```

## GitHub Codespaces

Add this repo under **Settings → Codespaces → Dotfiles**. Codespaces clones it and applies chezmoi automatically on every new environment (`ephemeral` role, auto-detected via `CODESPACES`).
