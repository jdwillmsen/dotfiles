# T3 Code provider pricing research

Fetched 2026-09-10 for a devbox audit of the CLIs `t3code.md` lists under
[Providers](t3code.md#providers): Claude Code, Codex, Cursor, Grok, OpenCode.
Antigravity is also listed there, but its sign-in options and quota were not
researched for this doc.
Anthropic API token pricing (Opus 5 $5/$25, Sonnet 5 $2/$10, Haiku 4.5 $1/$5
per MTok) came from an internal source already and is not re-derived here.

Sourcing note: WebFetch hit a hard 403 on every `openai.com`/`chatgpt.com`/
`help.openai.com`/`x.ai` marketing and help-center page tried (Cloudflare-style
bot block, consistent across retries and archive.org). Those claims are backed
by WebSearch result synthesis instead of a direct page fetch — the search tool
did surface real snippets from the named help.openai.com articles, but this is
weaker sourcing than a direct fetch and is flagged inline. Anthropic, Cursor,
xAI's `docs.x.ai`, Google, Groq, and GitHub-hosted docs fetched directly.

## TL;DR

Claude Pro is $17-20/mo, Max 5x/20x from $100-200/mo, Team seats $20-100/mo,
Enterprise $20/seat + API-rate usage — none of them publish an exact
prompts-per-5-hours number, only "resets on a rolling five-hour window and a
weekly window," sized by seat tier (`claude.com/pricing`,
`code.claude.com/docs/en/costs`, both fetched 2026-09-10). ChatGPT is Free/$8
Go/$20 Plus/$100-200 Pro/$20-125 Business per seat; Codex rides the same
Work/Codex weekly-reset pool on every tier including Free, and **the local
`.chezmoidata.yaml` comment claiming the free-tier Codex quota "does not reset
for a month" looks wrong** — OpenAI's own help-center weekly-reset article
(found via search, not directly fetched) describes a 7-day rolling reset, not
monthly, on every plan including Free (the comment now says weekly). Cursor is
Free Hobby (undisclosed numeric caps) / $20 Pro / $60 Pro+ / $200 Ultra / $40+ Teams, and `cursor-agent`
draws on the exact same pool as the IDE — no separate CLI allocation
(`cursor.com/pricing` fetched 2026-09-10). xAI's SuperGrok is $10 Lite / $30
standard / $300 Heavy, with Grok Build now free-tier-eligible but xAI publishes
no numeric free quota — only a client-side "you've reached your free Grok
Build usage limit" message with no listed reset time; **the local comment's
"free Build quota" is real but its exact size is not documented anywhere
public**, verified against `docs.x.ai/developers/rate-limits` (API tiers only,
no consumer numbers) fetched 2026-09-10. For free/cheap agentic fallback
models: OpenRouter's `:free` models cap at 20 req/min and 50/day (1,000/day
after a one-time $10 lifetime spend), Google's Gemini free tier is Flash/
Flash-Lite only (Pro was pulled from free in April 2026) at 10-15 RPM and
500-1,500 RPD, Groq's free agentic model (`groq/compound`) runs 30 RPM/70K
TPM, and Cerebras gives 1M tokens/day at 30 RPM — all real tool-use-capable
inference, but meaningfully behind frontier models on agentic reliability.
None of Anthropic/OpenAI/Cursor/xAI CLIs officially support side-by-side
multi-account sessions; all four require either a full re-login or pointing a
documented (Codex, Cursor) or undocumented (Claude Code, Grok) config-dir env
var at a second directory to fake it.

## 1. Claude subscription tiers

Source: [claude.com/pricing](https://claude.com/pricing), fetched 2026-09-10
(redirected from `anthropic.com/pricing`); usage-limit mechanics from
[code.claude.com/docs/en/costs](https://code.claude.com/docs/en/costs)
(redirected from `docs.claude.com/en/docs/claude-code/costs`), fetched
2026-09-10.

| Tier | Price | Notes |
|---|---|---|
| Pro | $17/mo billed annually ($200/yr) or $20/mo month-to-month | Claude Code included, shared usage pool with chat; ~5x Free tier's 5-hour allowance |
| Max 5x | from $100/mo | 5x Pro's usage |
| Max 20x | $100-200/mo | 20x Pro's usage, priority access in high-traffic periods |
| Team Standard seat | $20/seat/mo billed annually, $25/mo month-to-month | 2-150 member team size |
| Team Premium seat | $100/seat/mo billed annually, $125/mo month-to-month | 5x Standard seat usage, includes Claude Code dev environment |
| Enterprise | $20/seat billed annually + usage at API rates | No published seat minimum |

Claude Code usage limits: Anthropic does **not** publish an exact
prompts-per-5-hour-window number for any tier. `code.claude.com/docs/en/costs`
states plainly that on Team/Enterprise "each member's Claude Code usage draws
from a per-seat allowance that resets on a rolling five-hour window and a
weekly window," shared with Claude chat and Cowork, sized by seat tier
(Standard vs Premium) — no numeric figure given. Pro/Max get the same
five-hour + weekly window structure per the same doc page, with Max 5x/20x
scaling the pool 5x/20x over Pro. Model access is not tier-gated per this doc;
what's gated is throughput. Anthropic added weekly quotas on top of the
existing five-hour window starting **Aug 28** for heavy Pro/Max users
(per WebSearch synthesis of secondary sources describing this rollout — not
independently confirmed against a dated Anthropic changelog, flagged as
lower-confidence).

Usage credits (`/usage-credits`) let Pro/Max/Team/Enterprise users pay to
continue past the seat allowance once enabled — mechanics documented on the
same costs page, fetched 2026-09-10.

## 2. OpenAI ChatGPT tiers and Codex CLI limits

Pricing: WebFetch was blocked (403) on `openai.com/chatgpt/pricing`,
`chatgpt.com/pricing`, and `openai.com/pricing` on every attempt including via
archive.org (also blocked entirely for this session). Figures below are
WebSearch synthesis of multiple pricing-tracker sites plus one official
`developers.openai.com/api/docs/pricing` fetch (2026-09-10, confirms API-side
model pricing only, not consumer tiers) — **flagged as best-effort, not a
direct primary-source fetch**.

| Tier | Price (unverified via direct fetch) |
|---|---|
| Free | $0 |
| Go | $8/mo |
| Plus | $20/mo |
| Pro | $100/mo (5x) or $200/mo (20x) |
| Business (formerly Team) Standard | $20/seat/mo annual, $25/mo month-to-month, 2-seat minimum |
| Business Premium | $100/seat/mo annual, $125/mo month-to-month, launched Aug 2026, 5x Standard usage |
| Enterprise | Custom, sales-quoted |

Codex CLI access: the official `github.com/openai/codex` README (fetched
2026-09-10, primary source) says "We recommend signing into your ChatGPT
account to use Codex as part of your Plus, Pro, Business, Edu, or Enterprise
plan" — **it does not mention Free tier in that list**, which cuts against
some secondary sources claiming a documented Free-tier Codex allowance. The
README has no usage-limit numbers at all; it points to
`developers.openai.com/codex`, which itself redirects to `learn.chatgpt.com/docs`,
a page that (per direct fetch, 2026-09-10) has nav links to `/codex/pricing`
and `/codex/cli` but no usage-limit content in the fetched body.

Reset-period claim (the one the local `.chezmoidata.yaml` comment makes):
WebSearch surfaced the actual OpenAI help-center article titles and snippet
content for **"Paid weekly Work and Codex rate limit resets"** and **"How
banked Codex resets work"** (`help.openai.com/en/articles/20001507...` and
`.../20001498...`) — both blocked for direct WebFetch (403), so this is
snippet-only sourcing. The synthesized snippet states: "Your new weekly usage
period starts with your first request in Work or Codex after the reset is
applied, and your next automatic weekly reset is scheduled 7 days after that
first request," and that instant-reset purchases are unavailable on
"Free, Go, Business, Enterprise, or Edu" (implying the 7-day automatic cycle
does apply to Free, it just can't be manually accelerated there).

**Verdict on the local comment "the free-tier codex quota does not reset for a
month":** likely wrong, based on this weaker-than-ideal sourcing. OpenAI's own
documented mechanism is a 7-day rolling weekly reset applied uniformly across
plans including Free, not a monthly reset. No official page found states a
monthly reset for Codex at all. Given WebFetch was fully blocked on every
help.openai.com URL tried, treat this correction as probable-but-not-fully-
verified and worth a follow-up manual check of
`help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan` from
a normal browser. The comment has since been corrected to a weekly reset.

Separately, OpenAI toggled the five-hour window on/off for Plus during 2026
(removed July 12, restored Aug 25 for Plus; Pro 5x/20x kept it off "for the
upcoming months") per WebSearch synthesis of secondary trackers — flagged as
unverified against a dated OpenAI changelog.

## 3. Cursor pricing and `cursor-agent` limits

Source: [cursor.com/pricing](https://cursor.com/pricing), fetched directly
2026-09-10 (no block). CLI-specific docs:
[cursor.com/docs/cli/overview](https://cursor.com/docs/cli/overview) and
[cursor.com/docs/cli/reference/configuration](https://cursor.com/docs/cli/reference/configuration),
both fetched 2026-09-10.

| Tier | Price | Usage |
|---|---|---|
| Hobby (Free) | $0, no card | "Limited Agent requests" and "limited Tab completions" — Cursor does not publish the numeric cap on its own pricing page |
| Pro | $20/mo | Extended agent limits, frontier model access, "generous Grok limits," MCPs/skills/hooks, cloud agents, usage-based Bugbot billing |
| Pro+ | $60/mo | "3x Pro limits on Agent" |
| Ultra | $200/mo | "20x Pro limits on Agent," priority feature access |
| Teams | not priced on this page | secondary sources cite $40/user/mo standard, $120/mo premium seat (added June 2026) — unverified via direct fetch |
| Enterprise | custom, sales contact | pooled usage, invoicing, advanced security |

Every paid plan gets 20% off with annual billing. The page's own usage-model
language: "Every plan includes a set amount of model usage. On-demand usage
allows you to continue using models after your included amount is consumed,
billed in arrears" — no exact pool size published.

`cursor-agent` CLI: per Cursor's own CLI docs, "Auth and model usage run
through the same Cursor login you'd use in the editor, so your plan and limits
carry over" — confirmed via the fetched overview page structure (installation/
session/sandbox sections, no separate CLI pricing). **No separate free
allocation for the CLI** beyond whatever Hobby/Pro/etc. grants in the editor.

## 4. xAI Grok pricing and Grok CLI free "Build" tier

Consumer pricing: `x.ai/pricing` and `x.ai/grok` both returned 403 on every
WebFetch attempt (including archive.org, blocked entirely this session), so
pricing figures below are WebSearch synthesis — **flagged unverified via
direct fetch**. API/rate-limit figures below are from a genuine direct fetch of
[docs.x.ai/developers/rate-limits](https://docs.x.ai/developers/rate-limits),
2026-09-10 (no block hit on this docs subdomain).

| Plan (unverified pricing) | Price |
|---|---|
| Free | $0, small usage pool (reset period undocumented) |
| SuperGrok Lite | $10/mo (launched Mar 25, 2026) |
| SuperGrok | $30/mo ($300/yr ≈ $25/mo) — full Grok 4/4.5, DeepSearch, Big Brain, Imagine, voice |
| SuperGrok Heavy | $300/mo ($99/mo promo first 3 months) — Grok 4.5, Grok Bot beta |

Per WebSearch synthesis: paid and free plans share one usage pool spanning
Chat, Imagine, Voice, and Build, replacing an older per-two-hour cap system
retired June 2026. Secondary sources describe that pool as weekly, but xAI
documents no reset period for the free Build quota (see the verdict below).
SuperGrok subscriptions do **not** include API credits — `console.x.ai` API
usage is billed separately. Whether SuperGrok raises Grok Build/CLI limits is
**unconfirmed**: the CLI's own limit message suggests it does, and nothing
fetchable from xAI states either way.

`docs.x.ai/developers/rate-limits` (direct fetch, primary source) only
documents **API access tiers by cumulative spend**, not the consumer
subscription free pool:

| API tier | Cumulative spend threshold | grok-build-0.1 RPS | grok-build-0.1 TPM |
|---|---|---|---|
| Tier 0 (default) | $0 | 37 | 10M |
| Tier 1 | $50 | 50 | 15M |
| Tier 2 | $250 | 75 | 25M |
| Tier 3 | $1,000 | 125 | 45M |
| Tier 4 | $5,000 | 208 | 85M |
| Enterprise | request | — | — |

**Verdict on the local comment's "grok's free Build quota":** real — the CLI
does show a distinct "You've reached your free Grok Build usage limit for
now. Get SuperGrok for much higher limits…" message (per WebSearch synthesis
of the CLI's own client-side copy) — but **xAI does not publish an exact
number or a reset period for it anywhere fetchable**, on the consumer side or
in the API rate-limits doc. Treat the free Build quota as real-but-officially-
undocumented; don't plan capacity against an assumed number.

## 5. Free/cheap models for real agentic coding work

Honest capability note up front: every option below is meaningfully behind
Claude/GPT/Grok frontier models on multi-step agentic reliability (tool-call
correctness across long chains, self-correction, big-context coherence).
They're viable for short, well-scoped tool-use tasks and as a last-resort
failover — not a drop-in replacement for a paid frontier model in the
no-mistakes pipeline's `noMistakesAgent` list.

**OpenRouter** — [openrouter.ai/docs/api-reference/limits](https://openrouter.ai/docs/api-reference/limits),
fetched 2026-09-10. `:free`-suffixed model variants: 20 req/min always; 50
req/day with no prior spend, rising to 1,000 req/day after a one-time
lifetime $10+ credit purchase (permanent unlock, doesn't require an ongoing
balance). Multiple accounts/keys don't bypass this — OpenRouter states limits
are governed globally. Several genuinely tool-use-capable open-weight models
(Llama, Qwen, DeepSeek variants) rotate through the free catalog; quality and
availability both drift week to week since it's whatever upstream providers
donate capacity for.

**Google Gemini / AI Studio** — [ai.google.dev/pricing](https://ai.google.dev/pricing)
fetched 2026-09-10 (partial numbers only — tool/grounding limits present, core
RPM/TPM/RPD table not in the fetched body, redirected to
`ai.google.dev/gemini-api/docs/rate-limits` which also didn't surface the
table content directly); the numbers below are WebSearch synthesis of
tracker sites layered on the official page's confirmed structure — flag as
medium confidence:

| Model | Free-tier RPM | RPD | TPM |
|---|---|---|---|
| Gemini 3 Flash | 10 | 1,500 | 250,000 |
| Gemini 3.1 Flash-Lite | 15 | 1,000 | — |
| Gemini 2.5 Flash | 10 | 500 | 250,000 |
| Gemini 2.5 Pro | — | — | Pro pulled from free tier entirely as of April 2026 (paid-only now) |

Daily quota resets at midnight Pacific, not on a rolling 24h window (per
synthesis, unverified). Flash models support function calling / tool use;
Pro's removal from free means the strongest free Gemini agentic option is
Flash, not Pro.

**Groq** — [console.groq.com/docs/rate-limits](https://console.groq.com/docs/rate-limits),
fetched 2026-09-10 directly. Free-tier `groq/compound` and `groq/compound-mini`
are explicitly agentic models (built-in tool use), 30 RPM / 70K TPM for
`compound`. Other free models (Llama, Qwen, GPT-OSS variants) run 10-30 RPM,
1.2K-70K TPM, 3.6K-500K TPD depending on model. Rate limits apply at the org
level, not per-key — no obvious multi-key bypass.

**Cerebras** — no direct fetch succeeded (docs URL not confirmed); WebSearch
synthesis only, flagged unverified: reportedly 1M tokens/day, 30 req/min,
14,400 req/day per model, no card required, with an 8,192-token context cap
on free-tier models. Catalog reportedly shrank from ~12 models to 2
(Llama 3.3 70B, GPT-OSS 120B) by 2026-05-31. Cerebras's selling point is raw
inference speed (~2,600 tok/s cited), useful for keeping an agent loop's
planner/router step fast even if the model itself is mid-tier.

## 6. Multi-account / org patterns

None of the four vendors officially support running two authenticated
accounts side-by-side in one CLI install's default state — all require either
a full logout/login cycle or pointing an env var at a second config directory
(officially documented for two of the four, community-only for the other two).

| Vendor / CLI | Official multi-account mechanism | Fallback |
|---|---|---|
| Claude Code | None found in docs.claude.com/code.claude.com. `claude logout` + `claude login` is the documented swap. | Undocumented: `CLAUDE_CONFIG_DIR` env var (community-discovered, e.g. `claude-swap`, `Claude Switch` tools) points the CLI at an alternate credential dir — not an Anthropic-documented variable per the fetched costs page or WebSearch of docs.claude.com |
| Codex CLI | `CODEX_HOME` **is officially documented** — [learn.chatgpt.com/docs/config-file/environment-variables](https://learn.chatgpt.com/docs/config-file/environment-variables), fetched 2026-09-10: "Sets the root for Codex state, including config, auth, logs, sessions, skills," default `~/.codex`, directory must pre-exist. Doc doesn't frame this as a multi-account feature, but it works as one. | `codex login` overwrites the active `CODEX_HOME`'s credentials otherwise |
| Cursor / `cursor-agent` | `CURSOR_CONFIG_DIR` **is officially documented** — [cursor.com/docs/cli/reference/configuration](https://cursor.com/docs/cli/reference/configuration), fetched 2026-09-10, alongside `XDG_CONFIG_HOME` on Linux/BSD. Same caveat: documented as a config-location override, not marketed as multi-account. | Default login/logout flow only swaps one active session in `~/.cursor/cli-config.json` |
| Grok CLI (Build) | No config-dir override found in the official authentication doc — [github.com/xai-org/grok-build .../02-authentication.md](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/02-authentication.md), fetched 2026-09-10: credentials live at `~/.grok/auth.json`, and `grok login` explicitly "starts the sign-in flow again, replacing your cached session." No env var for relocating `~/.grok/` is documented in this file. | Community pattern (per WebSearch, unverified against an official doc): set `GROK_HOME` per account and alias per directory — this variable name did not appear in the fetched official auth doc, so treat as community convention, not confirmed API |

Net: Codex and Cursor both have an officially documented, non-hacky way to run
two accounts concurrently via config-dir env vars (`CODEX_HOME`,
`CURSOR_CONFIG_DIR`/`XDG_CONFIG_HOME`) even though neither vendor calls it a
"multi-account feature." Claude Code and Grok Build have no such documented
variable — anything doing this today (`CLAUDE_CONFIG_DIR`, `GROK_HOME`) is a
community convention riding on undocumented behavior, not something covered by
a support contract.
