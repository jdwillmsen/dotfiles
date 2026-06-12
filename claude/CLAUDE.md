# About Me

I'm Jake Willmsen — a senior polyglot software engineer. My primary stacks:

- **Java / Kotlin** — Spring Boot microservices, Gradle builds
- **Go** — CLI tools, backend services, performance-sensitive code
- **Python** — scripting, data work, automation
- **TypeScript / Node** — Angular frontends, NestJS backends
- **DevOps / Kubernetes** — Helm, Terraform, GitOps, GKE/EKS

I work across the full stack but skew backend and platform. I own infra and deployments alongside application code.

# How I Like to Work

- **Concise by default.** Skip summaries of what you just did — I can read the diff. Get to the point.
- **No unsolicited refactors.** Fix the thing I asked about. Don't clean up surrounding code unless I ask.
- **No speculative features.** Don't add error handling, abstractions, or backwards-compat shims for scenarios that don't exist yet.
- **No filler comments.** Only comment when the *why* is genuinely non-obvious.
- **Conventional commits.** All commit messages follow `type(scope): description`. Always.
- **Ask before destructive actions.** Confirm before force-pushing, dropping tables, deleting branches, or anything hard to reverse.

# Editor & Tooling

- Editor: nano (daily), learning neovim
- Shell: zsh (primary), bash (scripts/CI)
- Version managers: nvm (Node), pyenv (Python), sdkman (Java/Kotlin)
- Container runtime: Docker + Compose
- K8s tooling: kubectl, Helm, k9s

# Code Preferences

- Go: standard library first, minimal dependencies, `gofmt` always
- Java/Kotlin: prefer Kotlin, idiomatic style, avoid raw Java where possible
- TypeScript: strict mode, no `any`
- Python: type hints, `black` formatting
- Shell: `set -euo pipefail`, quote variables, no bashisms in `#!/bin/sh` scripts

# GitHub Actions

Always use the latest available version of every action. Before writing or modifying any workflow:

1. Look up the current latest tag — never assume: `gh api repos/<owner>/<action>/releases/latest --jq '.tag_name'`
2. Pin to that exact version tag, never `@main` or `@latest`
3. Add `cache: false` to setup-go for modules with no external dependencies (no `go.sum`)

# Project Context

My dotfiles live at `~/dotfiles` and are symlinked to `$HOME` via `install.sh`. The repo is at `github.com/jdwillmsen/dotfiles`. The Claude Code status line is a Go binary at `~/.local/bin/claude-status`.
