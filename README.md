# dotfiles

Personal development environment configuration for Jake Willmsen.

## What's included

| File | Purpose |
|------|---------|
| `gitconfig` | Git identity, aliases, sane defaults |
| `gitignore_global` | Global gitignore (OS files, editors, secrets) |
| `zshrc` | Zsh config — sources shared shell files |
| `bashrc` | Bash config — sources shared shell files |
| `shell/exports.sh` | Shared env vars and PATH (Go, pyenv, local bins) |
| `shell/aliases.sh` | Shared aliases (git, docker, kubectl, system) |
| `shell/functions.sh` | Shared helper functions |
| `scripts/claude-status.py` | Claude Code custom status line |

### Claude Code status line

Displays in the Claude Code prompt footer:

```
⬡ sonnet 4.6  │  ⎇ main ⑂  📁 myproject  │  💰 $0.04  │  ctx 23% [██░░░░░░░░] 23k/100k
```

| Segment | Shows |
|---------|-------|
| `⬡ sonnet 4.6` | Active model (shortened) |
| `⎇ main` | Git branch — adds `⑂` when in a worktree |
| `󰉋 project` | Basename of current directory |
| `💰 $0.04` | Accumulated session cost (yellow → red as it grows) |
| `ctx 23% [▓▓░░░░░░░░] 23k/100k` | Context window usage (green → yellow → red) |

The script reads what Claude Code sends via stdin JSON and falls back to shell commands (e.g. git) for anything not in that payload. Uncomment the `~/.claude-status-debug.json` line in the script to inspect the raw JSON on your system.

## Install

```bash
git clone https://github.com/jdwillmsen/dotfiles.git ~/dotfiles
cd ~/dotfiles
chmod +x install.sh
./install.sh
```

The install script symlinks each config file into `$HOME`. Existing files are backed up with a `.bak` suffix before being replaced.

## Version managers

All three version managers are supported. Install whichever you need — shell configs activate them only if they're present:

| Manager | Stack | Install |
|---------|-------|---------|
| [nvm](https://github.com/nvm-sh/nvm) | Node / JavaScript | `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh \| bash` |
| [pyenv](https://github.com/pyenv/pyenv) | Python | `curl https://pyenv.run \| bash` |
| [sdkman](https://sdkman.io) | Java / Kotlin / JVM | `curl -s "https://get.sdkman.io" \| bash` |

## Swapping to Starship prompt

The default prompts are minimal. To upgrade to [Starship](https://starship.rs):

```bash
curl -sS https://starship.rs/install.sh | sh
```

Then uncomment the starship lines in `zshrc` / `bashrc` and remove the existing `PS1=` lines.

## GitHub Codespaces

Point Codespaces at this repo under **Settings → Codespaces → Dotfiles**. Every new Codespace will clone it and run `install.sh` automatically.
