# RTK

A Claude Code hook rewrites shell commands through `rtk` (e.g. `git status` →
`rtk git status`) to compress their output. The summary can hide failures —
`rtk go build` has printed success on exit 1 — so trust the exit code, and run
`rtk proxy <cmd>` when you need the raw output. Analytics and install checks:
dotfiles `docs/agentic-workflow.md`.
More traps where tool output misleads (`rtk`, `gh`, `kubectl`, Windows
`curl`/CRLF): `~/.local/share/chezmoi/docs/agent-tooling-traps.md`.
