# CCR Fallback-Aware Statusline — Design

## Problem

When Claude Code runs through the CCR (claude-code-router) fallback tier, the
statusline lies. Claude Code has no idea a local router swapped its backend, so
the JSON payload it pipes to `claude-status` reports:

- `model.display_name` = "Opus 4.8" — but the real backend is e.g. `deepseek-v4-pro`
- `effort.level` = "high" — but reasoning was stripped for that route (NVIDIA 400s on `reasoning`)
- `context_window.context_window_size` = 200000 — Opus's window, not the routed model's
- `cost` / `rate_limits` = Max-quota figures — but no Max quota is being spent

Result: a fallback session shows `⬡ Opus 4.8  high  ctx 0k/200k` — four wrong
facts at a glance.

## Goal

Make the statusline reflect the *real* fallback backend: correct model label,
reasoning shown only when it actually happens, real context window when knowable,
a clear FREE marker instead of cost, and Max quota minimized to "when does it
unlock." Native `claude` sessions and the shared opencode statusline must be
completely unaffected.

## Non-goals

- No per-model price tables / cost counterfactuals (rejected — maintenance burden).
- No attempt to show the exact model of an individual sub-request. CCR routes
  `think`/`background`/`longContext` to potentially different models; the payload
  cannot reveal which. We show the session's *default* route only.
- No change to native or opencode rendering paths.

## Architecture

### The lie is unfixable from the payload

Confirmed via Claude Code docs research: the statusline JSON schema has **no field**
for the API base URL, a custom endpoint, or the truly-served model. So fallback
state must arrive **out of band**. The only available channel is the process
environment — Claude Code spawns the statusLine command as a child and (per the
`COLUMNS`/`LINES` injection pattern + Node's default `child_process` env inheritance)
passes its own environment through.

> **Assumption to verify first (see Verify-First).** Env inheritance is not
> documented, only strongly implied. Implementation step 1 proves it empirically
> before anything is built on it.

### Env contract — the picker stamps, the statusline reads

`~/.claude-code-router/pick.sh` already `export`s the router env before `exec claude`.
It gains three more exports, computed once at launch:

| Var | Value | Source |
|-----|-------|--------|
| `CCR_ACTIVE_ROUTE` | `nvidia,deepseek-ai/deepseek-v4-pro` | the picked route string |
| `CCR_CTX_WINDOW` | `128000` or empty | live `GET <provider>/v1/models` → `context_length ?? max_model_len` |
| `CCR_REASONING` | `on` \| `off` | `off` if the route's provider has the `strip-reasoning` transformer in `config.json`, else `on` |

A native `claude` launch sets none of these → statusline behaves exactly as today.
Opencode likewise sets none → unaffected. Each session's env is private to its
process, so concurrent sessions on different routes each show their own — a
correctness win over reading the mutable global `Router.default`.

### Context window is hybrid (pure-live fails on NVIDIA)

Research finding: `/v1/models` context reporting is inconsistent.

| Provider | Reports window? | Field |
|----------|-----------------|-------|
| OpenRouter | yes | `context_length` (qwen3-coder = 1048576) |
| vLLM (gpu-stack) | yes | `max_model_len` (gpt-oss-20b = 32768) |
| Ollama | only via `/api/show`, not `/v1/models` | — |
| **NVIDIA NIM** | **no** — only id/object/created/owned_by | — |

So the picker reads `context_length ?? max_model_len`; when the provider reports
nothing (NVIDIA), `CCR_CTX_WINDOW` is left empty. When empty, the statusline shows
**tokens-used only, no bar / % / denominator** (`ctx 15k in`) — honest about not
knowing, no fake 200k. The bar draws only when the window is actually known.

## Statusline changes (all gated on `CCR_ACTIVE_ROUTE != ""`)

`main` parses the three env vars into a small `fallback` struct and passes it to
`renderLines` (which currently reads no env — keeping it a pure function preserves
testability). Every branch below is a no-op when the struct is zero (native/opencode).

| Segment | Native (unchanged) | Fallback |
|---------|--------------------|----------|
| model | `⬡ Opus 4.8` (purple ⬡) | `⚡ deepseek-v4-pro` (amber ⚡) + dim provider `nvidia` |
| reasoning/effort | `effort.level` when present | shown only if `CCR_REASONING=on`; hidden otherwise |
| ctx bar | `used/window` + bar | window from `CCR_CTX_WINDOW`; if empty → `ctx <used>k in`, no bar |
| cost | `$0.42` | `FREE` (dim/green tag), no `$` |
| 5h/7d limits | full bars + reset | minimized: `5h 98% ↺2h30m · 7d 61% ↺Thu 9am`, no bars, unlock time emphasized |

Example fallback output:

```
⚡ deepseek-v4-pro  nvidia  │  jdwlabs  │  FREE
ctx ███░░░░░ 12%  15k/128k  │  5h 98% ↺2h30m · 7d 61% ↺Thu 9am
```

(NVIDIA route, unknown window → `ctx 15k in` instead of the bar.)

### Reasoning capability logic

`CCR_REASONING` is derived at launch, not hardcoded per model: the picker inspects
`config.json`, finds the provider named in the picked route, and checks whether its
`transformer.use` list contains `strip-reasoning`. Stripped → `off` → indicator
hidden. Not stripped → `on` → indicator shown (e.g. gpt-oss, a genuine reasoning
model). Adding `strip-reasoning` to any future provider auto-hides the indicator —
self-maintaining, single source of truth.

## Verify-First (implementation step 1, before building)

Env inheritance is the linchpin and is undocumented. First step adds a temporary
`-envdump` mode to the binary that writes its received environment to a temp file.
Deploy, launch one `ccrpick` session, confirm `CCR_ACTIVE_ROUTE` et al. appear.
Only then build the feature. If env is NOT inherited, the design pivots to a
session-correlated marker file (fallback plan, not expected to be needed).

## Testability

`renderLines` gains a `fb fallback` parameter (parsed in `main`, never reads env
itself). `main_test.go` adds cases:

- native (zero `fallback`) — asserts current output unchanged (regression guard)
- fallback + known window — asserts `⚡`, provider, bar with real denominator
- fallback + unknown window — asserts `ctx Nk in`, no bar
- fallback + `CCR_REASONING=off` — asserts effort hidden
- fallback + `CCR_REASONING=on` — asserts effort shown
- fallback cost/limits — asserts `FREE` + minimized limits

## Deployment

- Go binary + tests: edited in this worktree (`feat/ccr-statusline`), shipped via PR,
  never main. Rebuild is automatic — the existing chezmoi `run_onchange` build script
  hashes every `*.go` and rebuilds `~/.local/bin/claude-status` on `chezmoi apply`.
- `pick.sh` lives in `~/.claude-code-router/` (not chezmoi-managed) → edited in place,
  no PR.
- `ccrpick` alias (already added to `aliases.sh` in this branch) ships in the same PR.

## Limitations (documented, accepted)

- Label reflects the session's default route, not the exact model of a given
  sub-request (background/longContext may differ). No payload signal exists to do better.
- Ollama floor route reports no window via `/v1/models` → shows `ctx Nk in`. Acceptable.
- If Claude Code ever strips child env, detection breaks (Verify-First catches this).
