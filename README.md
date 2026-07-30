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
└── docs/                 # secrets, tmux, agentic workflow, and design docs
```

## Testing

```bash
bash tests/smoke.sh                                    # chezmoi apply into a temp HOME, assert key files
for t in tests/template/*.sh; do bash "$t"; done       # template rendering unit tests
for t in tests/scripts/*.sh; do bash "$t"; done        # run_* script unit tests
find home -name 'run_*.sh' -exec shellcheck -s bash {} +
```

## Shell prompt

[starship](https://starship.rs/) (`home/dot_config/starship.toml`), activated by a `command -v starship` guard in `.bashrc` — machines without the binary fall back to a plain `PS1`, so the config is safe to ship everywhere.

The prompt renders git and status glyphs from the Nerd Font private use area. `run_once_44-install-nerd-font.sh` installs the family, **but installing it is not enough — the terminal has to be pointed at it**, or every glyph shows as tofu. On Windows Terminal that is `profiles.defaults.font.face`:

```jsonc
"defaults": { "font": { "face": "JetBrainsMono NF" } }
```

Note the family name: winget's MSI registers `JetBrainsMono NF`, while the upstream Nerd Fonts archives use `JetBrainsMono Nerd Font`. The install script's presence check accepts both.

Terminal colours and font size are deliberately left alone — Windows Terminal rewrites `settings.json` on every UI change, so anything managed here would fight the app for ownership. `font.face` is the one setting worth applying by hand.

### Layout

```
╭─ ADMIN  dotfiles/scripts/claude-status   main  +2 !1   v1.26.0  󰔟 3s
╰─❯                                                                  ✘ NOTFOUND  23:25
```

Two lines, because context grows: deep paths, long branch names, a Kubernetes context and a toolchain version can all appear at once. On one line that pushes the cursor rightward and wraps mid-command; the frame pins the typing column so it never moves. A stable command column also makes scrollback skimmable — you can see where each command starts.

| Segment | Appears |
|---|---|
| `ADMIN` badge | Elevated shells only. A badge, not a bare username — `jdwil` and `Administrator` both read as names, and only one means admin rights. |
| Path | Repo-relative inside a repo, `~` at home. `use_os_path_sep = false` keeps POSIX separators, since Git Bash paths are what you type. |
| `git_state` | Rebase/merge/bisect with progress — it changes what the next command should be. |
| `git_status` | `+` staged, `!` modified, `?` untracked, `⇡⇣` ahead/behind, `*` stashed. |
| Toolchain versions | Detection-gated by starship, so each costs a segment only in a project that uses it. |
| Kubernetes | Enabled (off by default upstream): acting on the wrong cluster is expensive and otherwise invisible. |
| `cmd_duration` | Past 2s. |
| Right side | Exit status and clock, so a failure never shifts the command column. |

Colours come from a named `[palettes.mocha]` block, so styles read as intent (`mauve`, `overlay`, `frame`) rather than hex and retheming is one block.

## Claude Code status line

A three-line footer in the Claude Code prompt, built as a Go binary for fast startup. Shows model, git context, cost, session duration, context window fill (color-tiered to auto-compact threshold), rate limits, cache stats, and more.

When a session is launched through the CCR (claude-code-router) fallback tier via `ccrpick`, the footer reflects the *real* proxied backend instead of Claude Code's native labels: `⚡ <model>` with the provider, reasoning shown only when the route actually reasons, the routed model's context window (or tokens-only when the provider reports none), `FREE` in place of cost, and minimized rate limits. Native and opencode sessions are unaffected. Contract in [`docs/superpowers/specs/2026-07-14-ccr-fallback-statusline-design.md`](docs/superpowers/specs/2026-07-14-ccr-fallback-statusline-design.md).

Source: `scripts/claude-status/main.go`. Rebuild after editing:

```bash
cd scripts/claude-status && go build -o ~/.local/bin/claude-status .
```

## GitHub Codespaces

Add this repo under **Settings → Codespaces → Dotfiles**. Codespaces clones it and applies chezmoi automatically on every new environment (`ephemeral` role, auto-detected via `CODESPACES`).
