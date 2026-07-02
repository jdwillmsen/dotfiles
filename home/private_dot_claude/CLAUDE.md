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
- **Conventional commits.** When asked to commit, use `type(scope): description`. Keep commits atomic: one logical change per commit, with unrelated formatting, refactors, dependency updates, and behavior changes split apart.
- **Attribute AI-assisted work honestly.** If AI contributed to a commit, disclose that in commit/PR metadata. Use the exact trailer `Co-Authored-By: <agent name> <email>` for visible coauthor attribution, and add Linux-style provenance with `Assisted-by: <agent>:<model> [tools...]` when the agent/model is known. For Codex-assisted commits, prefer `Co-Authored-By: Codex <codex@openai.com>` and `Assisted-by: Codex:<model>` unless the repository defines a different convention. For Claude-assisted commits, prefer `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>` and `Assisted-by: Claude:Sonnet-4.6`.
- **Keep attribution out of source by default.** Do not add generated-by banners or provenance comments inside source files, docs, or generated files unless the repository explicitly requires them; commit/PR metadata is the normal place for attribution.
- **Ask before destructive actions.** Confirm before force-pushing, dropping tables, deleting branches, or anything hard to reverse.
- **Always work in a worktree, never on the default branch.** For any non-trivial change, create a git worktree on a dedicated feature branch and do the work there. Never commit directly to `main` or a repo's default branch.

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

# Code Comments

## Default position: don't add them

The bar for adding a comment is high. Most comments that developers reach for describe *what* the code does — information already present in the code itself. Well-named functions, variables, and types make those comments redundant. Prefer expressing intent in the code; reach for a comment only when the code cannot carry the information.

This is the consensus across Google, Linux kernel, LLVM, Mozilla, and all major style guides. It is not "avoid comments always" — it is "comments must earn their place."

## When a comment is required

**Public API documentation.** Every exported / public symbol must have a documentation comment. Users read docs, not implementations. The comment IS the contract — describe what the abstraction does, what it promises, and what callers must know (preconditions, null semantics, units, thread-safety). Use the language-idiomatic format (godoc, docstring, JSDoc, Javadoc, rustdoc, XML doc, etc.). No exceptions.

**Non-obvious invariants and preconditions.** Units of measure, inclusive vs. exclusive boundaries, null semantics, expected value ranges, memory ownership, thread-safety constraints. Type systems rarely express these; a comment does.

**Why, not what.** When the code does something counter-intuitive, rejects a simpler approach, encodes a business rule, or satisfies a non-obvious constraint — say why. Future maintainers (including you) will ask "why is this like this?" before asking "what does this do?"

**Workarounds and hacks.** Comment every intentional hack with: what it works around, a reference (issue, ticket, external bug), and the condition under which it can be removed. This prevents well-meaning future engineers from "fixing" it.

## What never belongs in source code

**Restating the code.** `// increment x` before `x++` is noise. `// loop through users` before `for user in users` is noise. If the code is readable, the comment adds nothing and will eventually contradict.

**Commented-out code.** Delete it. Version control preserves history — `git log` and `git show` retrieve anything deleted. Commented-out code rots within weeks because the surrounding code drifts without it. It signals discomfort with version control, not caution.

**Changelog and journal entries.** `// 2024-03-15 jdw: fixed race condition` belongs in a commit message and `git blame`, not source files. Source code is not a diary.

**TODOs without an owner and a ticket.** `// TODO: fix this` accumulates into permanent ignored noise. A TODO must name an owner and link to a tracking issue: `// TODO(jdw): handle edge case — see GH-1234`. No unlinked TODOs in merged code.

**Outdated comments.** An incorrect comment is actively harmful — empirical research shows code-comment inconsistency increases bug-introducing commits by ~1.5x. When changing code, update adjacent comments. If a comment cannot be kept accurate, delete it rather than leaving it wrong.

## Documentation files (README, CONTRIBUTING, etc.)

Write for the reader who has never seen the project. Cover: what it does, how to run it, how to contribute. Use working code examples.

**Timeless content** (stable): motivation and goals, architectural decisions and their rationale, core concepts, public API contracts, contribution process.

**Rot-prone content** — avoid, or isolate explicitly: specific version numbers, UI screenshots, step-by-step instructions for external services that change, inline changelogs. Apply DRY — one authoritative location per piece of knowledge; link rather than duplicate.

# GitHub Actions

Always use the latest available version of every action. Before writing or modifying any workflow:

1. Look up the current latest tag — never assume: `gh api repos/<owner>/<action>/releases/latest --jq '.tag_name'`
2. Pin to that exact version tag, never `@main` or `@latest`
3. Add `cache: false` to setup-go for modules with no external dependencies (no `go.sum`)

# Project Context

My dotfiles live at `~/dotfiles` and are symlinked to `$HOME` via `install.sh`. The repo is at `github.com/jdwillmsen/dotfiles`. The Claude Code status line is a Go binary at `~/.local/bin/claude-status`.
