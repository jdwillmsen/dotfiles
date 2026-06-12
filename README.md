# dotfiles

Personal development environment configuration for Jake Willmsen — shell, git, and Claude Code status line.

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
| `scripts/claude-status/` | Claude Code custom status line (Go) |

## Install

```bash
git clone https://github.com/jdwillmsen/dotfiles.git ~/dotfiles
cd ~/dotfiles
chmod +x install.sh
./install.sh
```

The install script symlinks each config file into `$HOME`. Existing files are backed up with a `.bak` suffix before being replaced. It also builds the `claude-status` Go binary into `~/.local/bin` and injects the `statusLine` setting into `~/.claude/settings.json` if Go is available.

## Shell aliases and functions

### Git

| Alias | Command |
|-------|---------|
| `g` | `git` |
| `gs` | `git status` |
| `ga` | `git add` |
| `gc` | `git commit` |
| `gp` | `git push` |
| `gl` | `git pull` |
| `glog` | Pretty one-line log with graph |

### Docker

| Alias | Command |
|-------|---------|
| `d` | `docker` |
| `dps` | `docker ps` |
| `dc` | `docker compose` |
| `dcu` | `docker compose up -d` |
| `dcd` | `docker compose down` |

### Kubernetes

| Alias | Command |
|-------|---------|
| `k` | `kubectl` |
| `kgp` | `kubectl get pods` |
| `kgs` | `kubectl get services` |
| `kgd` | `kubectl get deployments` |
| `klogs` | `kubectl logs -f` |
| `kns` | `kubectl config set-context --current --namespace` |
| `kctx` | `kubectl config use-context` |

### Functions

| Function | Purpose |
|----------|---------|
| `mkcd <dir>` | Create directory and cd into it |
| `extract <file>` | Extract any archive (zip, tar, gz, bz2, xz, …) |
| `port <n>` | Show what's listening on port N |
| `ksh <pod>` | Open a shell in a Kubernetes pod |
| `gclone <url>` | Clone into `~/projects/<repo>` and cd |
| `pathlist` | Print PATH entries one per line |
| `serve [port]` | Start an HTTP server in the current directory |

## Claude Code status line

A three-line status bar displayed in the Claude Code prompt footer. Written in Go for ~1ms startup time.

```
⬡ Sonnet 4.6  │  ⎇ main +2~3  │  📁 jdwillmsen/dotfiles  │  +156 -23  │  $0.12  ⏱ 5m12s
ctx ██░░░░░░░░ 24%  48k/200k  │  5h ███░░░░░ 38%  ↺ 3:45pm (2h30m)  │  cc 1.2.3
💾 73% hit  35k cached  5k written  8k fresh  │  ↑ 4k out  api 30%  │  📝 session-name
```

| Segment | Shows |
|---------|-------|
| `⬡ Sonnet 4.6` | Active model + version |
| `high` / `💭` | Effort level and thinking mode when active |
| `⎇ main +2~3` | Git branch, staged (+) and modified (~) file counts |
| `📁 owner/repo` | GitHub repo or current directory name |
| `+156 -23` | Lines added/removed by Claude this session |
| `$0.12` | Accumulated session cost (yellow → red) |
| `⏱ 5m12s` | Session wall-clock duration |
| `ctx ██░░ 24%  48k/200k` | Context window bar, %, and token counts |
| `5h ███░ 38%  ↺ 3:45pm (2h30m)` | 5-hour rate limit usage + reset time |
| `7d ████░ 61%  ↺ Thu 9am (1d14h)` | 7-day rate limit usage + reset time (Pro/Max) |
| `cc 1.2.3` | Claude Code version |
| `💾 73% hit` | Prompt cache hit rate |
| `35k cached / 5k written / 8k fresh` | Cache token breakdown |
| `↑ 4k out` | Output tokens generated |
| `api 30%` | Fraction of wall time spent waiting on API |
| `📝 session-name` | Session name if set |

The binary reads the JSON payload Claude Code pipes via stdin and falls back to `git` commands for branch/status (cached for 5 s per session to avoid slowdown).

## Version managers

All three version managers are supported. Shell configs activate them only if they're present:

| Manager | Stack | Install |
|---------|-------|---------|
| [nvm](https://github.com/nvm-sh/nvm) | Node / JavaScript | See [nvm install docs](https://github.com/nvm-sh/nvm#installing-and-updating) for the latest command |
| [pyenv](https://github.com/pyenv/pyenv) | Python | `curl https://pyenv.run \| bash` |
| [sdkman](https://sdkman.io) | Java / Kotlin / JVM | `curl -s "https://get.sdkman.io" \| bash` |

## Starship prompt

The default prompts are minimal. To upgrade to [Starship](https://starship.rs):

```bash
curl -sS https://starship.rs/install.sh | sh
```

Then uncomment the Starship lines in `zshrc` / `bashrc` and remove the existing `PS1=` lines.

## GitHub Codespaces

Point Codespaces at this repo under **Settings → Codespaces → Dotfiles**. Every new Codespace will clone it and run `install.sh` automatically.
