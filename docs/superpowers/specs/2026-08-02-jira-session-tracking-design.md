# Jira Ticket Tracking in Claude Code — Design

## Problem

Running several Claude Code sessions in parallel worktrees, there is no way to
see which piece of work each one is on. The statusline shows the branch, the
model, and the context bar; the `/resume` picker and terminal tab show a
Claude-derived session name like `dotfiles-1e`. Neither answers "which ticket is
this session working, and what else is in flight right now."

Today the gap is structural, not cosmetic: the mandated branch convention
(`feat/|fix/|chore/|docs/|refactor/` + kebab-case, global `CLAUDE.md`) carries
no ticket key at all, so nothing in the session's own state names the work item.

## Goal

Make the current session's Jira ticket visible at a glance in the statusline,
name sessions after their ticket so the `/resume` picker and tab title are
scannable, and provide an on-demand listing of every live session and its
ticket. Cost nothing measurable on the statusline hot path, add no credential,
and couple to no undocumented Claude Code internals.

## Non-goals

- Rendering multiple tickets in one statusline. One session works one ticket;
  a session spanning two is a signal to split the worktree.
- Live Jira workflow state (`In Progress` / `Blocked`) in the statusline. It is
  the most volatile field, needs the freshest fetch, and describes the one thing
  the user already knows — they are working it right now.
- Owning worktree creation. `gwta` remains the entry point.
- Any write to Claude Code's own session state.

## Prerequisite: ticket-keyed branches

Phase 1 derives the ticket from the branch, so the branch must carry it:

```
feat/JDWLABS-123-fix-login-retry
```

This is a change to the mandated convention in the global `CLAUDE.md` and it is
load-bearing — without it the branch regex resolves nothing and only the manual
override file works.

It also requires an explicit carve-out in that file's comment rule, which
currently bans ticket IDs as "external references (ticket IDs, URLs, names —
traceability goes in commits/PRs)". The carve-out: comments stay banned; the
branch name and PR title become the sanctioned traceability channel. Without
this edit the design contradicts the repo's own rules.

## Architecture

Three independent pieces, each usable without the others:

| Piece | Runs in | Phase |
|---|---|---|
| Ticket resolution | `claude-status` Go binary | 1 |
| Statusline segment | `claude-status` Go binary | 1 |
| Session naming | shell wrapper + `/rename` | 1 |
| `-jira` cross-session listing | `claude-status -jira` | 2 |
| Summary enrichment | skill-driven cache | 2 |

### Ticket resolution

A pure function of the statusline payload plus at most one small file read. No
subprocess, no network, no shared state.

Order, first hit wins:

1. `<git-dir>/claude-jira-ticket` — manual override
2. Branch name, regex + project-key allowlist
3. None — segment renders nothing

**Why per-worktree, not per-repo.** `<git-dir>` inside a linked worktree
resolves to `<main>/.git/worktrees/<name>`, so an override set in one worktree is
invisible from another. That is the requirement, not a bug: one worktree is one
ticket. `--git-common-dir` would be wrong here.

**Deriving the git dir without a subprocess.** `git rev-parse --git-dir` costs
~60 ms measured, against a total statusline cold-start budget of ~84 ms — a 71%
regression for information the payload already carries. Instead: take
`workspace.git_worktree` as the root, stat `<root>/.git`; if it is a file, read
its one-line `gitdir: <abs>` pointer (~0.076 ms). If the payload carries neither
`workspace.git_worktree` nor a branch, skip resolution rather than spawning.

**Branch parsing.** The naive `[A-Z][A-Z0-9]+-\d+` matches `UTF-8`, `SHA-256`,
`HTTP-2`, `GH-2`, `AWS-4` — each pinning a permanent bogus ticket that never
self-corrects. Instead, anchored to a separator and case-insensitive:

```
(?i)(?:^|[/_-])([a-z][a-z0-9]{1,9}-\d+)(?:$|[/_-])
```

Uppercase the capture, take the first match deterministically, then **require
the project key to appear in a configured allowlist**. The allowlist is what
actually excludes `SHA-256`; the regex alone cannot.

**Single validation choke point.** The key becomes a filename in phase 2, and it
arrives from more than one source, so exactly one function validates it:

```go
func parseTicketKey(s string) (string, bool)  // ^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6}$
```

Anchored, applied after `TrimSpace`, **reject — never repair, never fold case
into validity**. Every source calls it; there is no other path to a key. The
override file read is capped at 256 bytes, first line only.

### Configuration

Two values are needed and neither may be committed: the Jira site base URL is
company-identifying, and the project-key allowlist names real projects.

Both live in one machine-local file, `~/.config/claude-jira.json`, unmanaged by
chezmoi:

```json
{ "siteBase": "https://example.atlassian.net", "projects": ["ABC", "DEF"] }
```

Read once per statusline invocation (~0.076 ms, same cost class as the override
file). Missing or unparseable ⇒ **the feature is entirely off**: no segment, no
link, no resolution. That is the correct default for a machine that has no Jira,
and it means the feature ships dark until deliberately configured.

An empty or missing `projects` list disables branch resolution specifically —
the allowlist is what excludes `SHA-256`, so resolving without one is not a
safe fallback. The override file still works, since it is explicit.

### Statusline segment

The statusline's first line is the most crowded surface in the app. Rendering
`JDWLABS-123` beside `⎇ feat/JDWLABS-123-fix-login-retry` prints the key twice
in adjacent segments.

Instead: **strip the key from the branch display and render it as its own
OSC-8-linked segment**, placed in the `gitParts` group adjacent to the PR
segment — the ticket and the PR are the same work item at two stages. Net width
change is approximately zero, and the key becomes a distinct clickable token.

- Link target derived locally as `siteBase + "/browse/" + key`, never taken from
  data. `siteBase` is parsed once with `net/url` requiring `https`, non-empty
  host, nil user, and empty path/query/fragment. Unset or invalid ⇒ render the
  key with no link.
- **No emoji.** `TestRenderNoEmoji` (`main_test.go:441-448`) asserts
  single-width glyphs only, and `visibleLen` counts runes rather than display
  cells, so a wide glyph is undercounted by one column and overflows truncation.
  Use a BMP or Nerd Font PUA mark consistent with the existing `⎇ ⬡ ⚡` set.
- Tiers, stated explicitly so the implementer does not guess: `narrow` (<80
  cols) drops it with the rest of `gitParts`; `normal` and `wide` render the key.

Phase 1 renders no summary, so no line-measurement machinery is required.
`renderLines` currently never measures its own assembled output — `joinSections`
concatenates — so "render the summary if it fits" would mean building width
accounting that includes `sep` and OSC-8 bytes. Deferred with the summary.

### Session naming

`claude -n <name>` is a documented flag; `/rename` is a documented in-session
command. Both are used as-is.

- **At launch:** a shell function resolves the ticket from the current worktree
  and runs `claude -n "JDWLABS-123"`.
- **Mid-session:** `/rename`, run by the user. Tooling may *suggest* it; nothing
  renames a session behind the user's back.

**Key only, no summary.** Building `claude -n "ABC-123 <summary>"` as a command
string executes `$(…)` and backticks from a ticket title. Argv arrays are not
sufficient mitigation on Windows, where `claude` resolves to a `.cmd` shim and
`%`/`&`/`^` re-parse inside `cmd.exe` (BatBadBut class, CVE-2024-24576). A
validated key is injection-free by construction and loses nothing as a label.

**The wrapper must not be named `claude`.** Aliasing or shadowing `claude`
breaks `claude agents --json`, `claude mcp`, and `claude update`, and recurses
into itself — and phase 2 depends on the real binary. Name it distinctly (`cj`),
alongside the existing `ccrpick` / `clauded`, and have it derive the ticket from
the current worktree rather than creating one.

**Coverage limit, stated plainly:** a shell wrapper covers terminal launches
only. `EnterWorktree` sessions, `Agent`-tool subagents, and `claude --bg` never
traverse a shell function. Those sessions fall back to `/rename` or to no name.

### Terminal-safety hardening

Ships in phase 1 regardless of the Jira work, because it fixes existing paths.

Any externally-sourced text reaching the terminal is an injection vector. A Jira
summary is settable by anyone with access to the Jira instance, and the
statusline re-renders every 10 seconds:

- `\x1b]52;c;<base64>\x07` (OSC 52) writes the **system clipboard** — the next
  paste is attacker-chosen text.
- `\x1b[6n` makes the terminal write a response onto the tty's *input* stream.
- `\n` / `\r` forge or overwrite statusline rows (a fake `PR #47 ✓ approved`).
- `\x1b]8;;\x1b\\` closes an `osc8` hyperlink early and opens a new one — text
  unchanged, target attacker-controlled.

Blocklisting `\x1b` is insufficient: BEL (`0x07`) terminates OSC in many
terminals, and `0x9B` / `0x9D` are bare C1 CSI/OSC introducers.

**Mitigation — an allowlist applied at the read boundary**, not at render:

```go
func safeText(s string, maxRunes int) string
```

Drops C0 + DEL, C1 (`0x80`–`0x9F`), anything failing `unicode.IsPrint`, and BiDi
overrides (`U+202A`–`U+202E`, `U+2066`–`U+2069`, `U+200E`, `U+200F`); truncates
by rune **after** stripping so removed escapes do not consume budget.

Harden `osc8` as defense in depth: return `text` unchanged when `url` fails
validation or either argument contains a rune below `0x20`.

This closes latent holes on paths that exist today and are unsanitized:
`p.PR.URL` and repo host/owner (`main.go:660-667`), `p.SessionName`
(`main.go:853`), and subagent names/descriptions (`main.go:936-960`).

## Phase 2

Built only on phase 1's foundations; neither requires rework of it.

### `claude-status -jira`

Lists every live session and its ticket. Reads `claude agents --json` — a
**documented, supported** flag emitting `{id, pid, cwd, kind, startedAt,
sessionId, name, status|state}` for interactive and background sessions.

Reading `~/.claude/sessions/*.json` directly was considered and rejected: it is
undocumented internal state that Claude Code rewrites on every status change,
its real schema already differs from what this design first assumed (it also
carries `procStart`, `peerProtocol`, `statusUpdatedAt`, and background sessions
use `state` not `status`), and those files appear and vanish within seconds,
producing a live stat-then-read race.

- Cost ~2.1 s measured. Acceptable on demand; **never** callable from the
  statusline render path.
- Liveness by `updatedAt` recency, **not** by PID probing.
  `os.FindProcess(pid).Signal(syscall.Signal(0))` returns "not supported by
  windows" for *live* PIDs — verified against two running sessions, both
  reported dead. That idiom would print an empty table forever: silently
  plausible and completely wrong.
- Failure degrades to one line — `jira: session list unavailable` — and exits 0.
  Never a stack trace, never silence.
- It is an agent-facing CLI, so AXI applies (global `CLAUDE.md`): flag style
  consistent with the existing `-subagents`, a machine-readable output mode,
  non-zero exit only on real failure, one-line usage on bad input.

### Summary enrichment

Adds the ticket summary to the segment built in phase 1 — a pure addition.

**A hook cannot do this.** Claude Code hooks are shell commands; MCP tools are
invoked by the model inside a turn. There is no hook-side MCP client, and the
Atlassian plugin server's OAuth token lives in the plugin's own undocumented
store. Two honest options, and the implementation must pick one explicitly
rather than describing one and building the other:

- **Skill-driven** — a skill the model invokes, which calls the Atlassian MCP
  and writes the cache. Works with existing OAuth, no new credential, refreshes
  only when the model runs it. Acceptable because summaries are near-static.
- **Hook + own credential** — a hook hitting the Jira REST API with a PAT stored
  through the existing age + `pass` pipeline (`docs/secrets.md`). Deterministic,
  but adds a secret to provision on every machine.

The cache is written by an LLM and is therefore hostile input:

- Location: **outside** `~/.claude/cache/` (Claude Code owns that directory) and
  **outside** the chezmoi-managed subtree. `home/private_dot_claude/` maps to
  `~/.claude`, so a cache there could be swept into this **public** repo by any
  `chezmoi add ~/.claude`. Prefer `os.TempDir()`, matching the precedent and
  reasoning already documented at `main.go:218`.
- `io.LimitReader` at 8 KB; decode into a struct of string fields only.
- **Fail closed** — any decode error renders no summary, never raw bytes.
- Cross-check the parsed key against the requested key.
- `fetchedAt` must parse, be in the past, and be within a TTL; a future
  timestamp must not read as fresh. Beyond TTL ⇒ key only.
- No `url` field. It is derived locally (above). A data-supplied URL reaches the
  OS opener on ctrl+click — `file://`, `\\attacker\share` (NTLM hash leak on
  Windows), `ms-msdt:` — and buys nothing.

**Torn reads are not theoretical:** a naive write/read pair measured 1,561 torn
reads in 6,219 attempts (25%) over 2 seconds, with the reader seeing zero bytes.
The writer uses tmp + rename — and on Windows `os.Rename` over a file a reader
holds open fails `Access is denied` (954 failures in 2 s), because Go's
`os.Open` does not pass `FILE_SHARE_DELETE`. The writer therefore retries the
rename 3–5× with ~10–20 ms backoff and gives up silently. The reader treats any
error as a cache miss.

**Never sweep in the hot path.** `cleanStaleCaches` (`main.go:281`) already
costs ~40 ms — `ReadDir` + `Info()` over 3,713 temp entries, ~48% of the
statusline budget, growing with unrelated litter. Do not replicate it; prune on
the writer side only.

## Distribution

- **Go sources** — covered automatically. `run_onchange_after_20-build-claude-status.sh.tmpl`
  hashes `glob(scripts/claude-status/*.go)`, so a new `jira.go` retriggers the
  build and a new subcommand needs no build-script change.
- **Shell function** — `home/dot_config/shell/functions.sh` (sourced by bash and
  zsh), documented in `docs/shell-helpers.md` beside `gwta` / `wtd`.
- **`home/.chezmoiignore`** — add the Jira pieces to the `.isEphemeral` block.
  A ticket lookup on a CI or Codespaces machine is pure latency and noise.
- **`README.md`** — the "Claude Code status line" section describes the rendered
  output and goes stale; updating it is part of the work.

## Testing

`tests/scripts/test_claude_scripts.sh` renders templates and shellchecks them;
it does not test runtime behavior. Coverage splits:

**Go** (`scripts/claude-status/main_test.go`, 43 existing tests):

- Resolution precedence: override file > branch > none.
- Regex rejects `SHA-256`, `UTF-8`, `HTTP-2`; allowlist excludes unknown keys.
- `parseTicketKey` rejects `../../../etc/passwd`, lowercase, over-long keys.
- Branch key is stripped from the branch display exactly once.
- `safeText`: given `"\x1b]52;c;cm0gLXJmIH4=\x07"`, `"ok\nFORGED"`,
  `"a\x1b]8;;https://evil\x1b\\b"`, `"x\x1b[6n"`, `"‮gnp.exe"`, assert the
  rendered output contains no byte below `0x20` and exactly the expected line
  count.
- `-jira` parses a **fixture** `claude agents --json` array from an injected
  `io.Reader` — never by shelling out, so CI (ubuntu, no `claude` binary) can
  run it. Empty and garbage input exit 0.

**Templates:** extend `test_claude_scripts.sh` for any new render + shellcheck.

**Leak guard:** fixtures use synthetic values only (`ABC-123`,
`https://example.atlassian.net`). Add a CI check failing the build on a real
`atlassian.net` host outside an `example.` prefix — this guards the whole repo,
not just fixtures, since `~/.config/claude-jira.json` is machine-local by design
and no real site URL or project key should ever appear in tracked files.

**CI:** the existing `claude-status` job (build / gofmt / vet / smoke on ubuntu)
picks the new tests up free, provided none depend on the `claude` binary.

## Rejected

- **Patching `~/.claude/sessions/<pid>.json`** to rename a live session. Claude
  Code rewrites that file on every status change; the write loses a race at
  nondeterministic intervals and fails silently. `/rename` is supported and does
  the same job.
- **Agent SDK `renameSession`.** Adds a node + SDK dependency (not currently
  installed) for what `/rename` already does.
- **`CLAUDE_JIRA_TICKET` as a user-facing knob.** Per-process, so exporting it
  elsewhere does nothing to a running session; sticky across `cd`; and it makes
  resolution impure, which structurally breaks `-jira`, since that resolves
  tickets for directories it is not running in. Survives only as internal
  plumbing inside the launch wrapper.
- **Cached workflow status.** Most volatile field, needs the freshest data,
  least informative — worst value-to-cost ratio in the design.

## Pre-existing defects surfaced

Independent of this feature; worth fixing regardless.

- `home/private_dot_claude/hooks/executable_session-summary.sh` is shipped and
  tracked but **registered nowhere** — the runtime `settings.json` has only
  rtk's `PreToolUse`. It is dead code today. Register it or delete it.
- `home/private_dot_claude/modify_settings.json.json.tmpl` merges with
  existing-on-disk winning. Dict keys merge recursively, but a key whose value is
  a **list** is replaced wholesale. Once `settings.json` contains a
  `hooks.SessionStart` array, every future dotfiles change to that hook is a
  silent no-op. Fix: union hook arrays by `command` string, and add a regression
  test feeding an existing `settings.json` with a `hooks` block.
