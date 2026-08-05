# aipick — Multi-CLI Model Swap + Free-Tier Refresh — Design

## Problem

`ccrpick` only launches Claude Code (through CCR) against the free/local
fallback tier. Two other CLIs speak the same providers' native OpenAI-format
API directly — no CCR translation needed — but there's no way to launch them
from the same picker, and no way to swap between "drive this model via Claude
Code" vs "drive it via Aider" vs "drive it via Qwen Code" without hand-writing
env vars each time.

Separately, the free-model landscape churns fast (OpenRouter delisted
`qwen/qwen3-coder:free` mid-2026 with no notice) and NVIDIA NIM ships new
free-tier models (Kimi, MiniMax, Qwen3-Coder-480B) that aren't in
`config.json.tmpl` yet.

## Goal

- One alias (`aipick`) to pick a tool (Claude Code / Aider / Qwen Code) and a
  model from the same `config.json` provider list, then launch that tool
  correctly configured — no manual env-var wrangling.
- `config.json.tmpl` gains the current NVIDIA NIM free-tier coding models and
  drops the confirmed-dead OpenRouter entry.
- A standing way to re-check what's currently free on OpenRouter, since that
  list moves under you.

## Non-goals

- No change to `pick.sh` / `ccrpick` behavior — it keeps working exactly as
  today, untouched.
- No CCR routing for Aider/Qwen Code. They speak OpenAI format natively;
  routing them through CCR would add a translation hop they don't need.
- No auto-editing of `config.json` from the refresh script — it prints
  candidates, the user decides what to paste in.
- No statusline integration for the Aider/Qwen Code paths (out of scope; that
  machinery is Claude-Code-specific per the prior CCR statusline design).

## Architecture

### `aipick` — tool-first, then model

`dot_claude-code-router/executable_aipick.sh`, new file, mirrors `pick.sh`'s
style (`set -euo pipefail`, same config-dir guard, same node one-liners to
read `Providers`).

1. Ask which tool: Claude Code / Aider / Qwen Code / cancel.
2. **Claude Code** → `exec bash "$ccrdir/pick.sh"`. Re-prompts for a model;
   accepted tradeoff — avoids touching the working CCR/router-boot logic in
   `pick.sh` for a one-keypress saving.
3. **Aider / Qwen Code** → list `provider,model` pairs from `config.json`
   (same query `pick.sh` already runs), user picks one, then:
   - Resolve `api_key`: literal string, or `$ENV_VAR` → look up `$ENV_VAR` in
     the environment (same resolution `pick.sh`'s reachability probe already
     does — reuse the pattern, don't reinvent it).
   - Resolve base URL: strip `/chat/completions` and trailing slashes off
     `api_base_url` (same regex `pick.sh`'s probe uses) → yields the plain
     `.../v1` OpenAI-format base both tools expect.
   - Missing binary → auto-install once, then continue:
     - `aider` → `pipx install aider-chat` if `pipx` present, else
       `pip install --user aider-chat`. Neither present → error, tell user to
       install `pipx` first (no cascading package-manager installs).
     - `qwen` → `npm i -g @qwen-code/qwen-code`. `npm` missing → error.
   - Launch:
     - Aider: `exec aider --openai-api-base "$base" --openai-api-key "$key" --model "openai/$model"`
     - Qwen Code: `export OPENAI_API_KEY="$key" OPENAI_BASE_URL="$base" OPENAI_MODEL="$model"; exec qwen`
   - Both `exec` in the caller's `$PWD` (current project dir), same as
     `pick.sh` does for `claude`.
4. No API key resolved and provider isn't `ollama`/`gpu-stack` (dummy-key
   friendly) → print a warning, still launch — some free endpoints tolerate
   a blank/dummy key.

### Config additions — `config.json.tmpl`

`nvidia` provider `models[]` gains:

- `qwen/qwen3-coder-480b-a35b-instruct` — Apache-2.0, 69.6% SWE-bench
  Verified, top open-license coding model.
- `minimaxai/minimax-m3` — 1M context, leads the Aug-2026 open-weight
  ranking (68.7).
- `moonshotai/kimi-k2.6` — Kimi K3 isn't live on NIM's free endpoints yet
  (per NVIDIA dev-forum thread requesting it); K2.6 is the current free one.

`Router` changes: `think` → `nvidia,moonshotai/kimi-k2.6`, `longContext` →
`nvidia,minimaxai/minimax-m3` (matches its 1M window). `default` and
`background` untouched.

`openrouter` provider: drop `qwen/qwen3-coder:free` (confirmed delisted
mid-2026, dead entry). `qwen/qwen3-next-80b-a3b-instruct:free` stays —
unconfirmed but no evidence it's gone.

### `orfree` — OpenRouter free-tier refresh

`dot_claude-code-router/executable_refresh-openrouter-free.sh`, new file.
No auth needed (public catalog endpoint):

```
GET https://openrouter.ai/api/v1/models
```

Filter to entries where `pricing.prompt == "0"` and `pricing.completion ==
"0"`, print `id` one per line (or `--json` for a ready-to-paste array).
Read-only — never touches `config.json`. Run it whenever you want to check
what's currently free; paste what you want into the `openrouter` provider's
`models[]` by hand.

### Aliases (`dot_config/shell/aliases.sh`)

```sh
alias aipick='bash ~/.claude-code-router/aipick.sh'
alias orfree='bash ~/.claude-code-router/refresh-openrouter-free.sh'
```

`ccrpick` alias unchanged.

## Error handling

- No `config.json` → same guard `pick.sh` already has (`exit 1` with message).
- `pipx`/`npm` missing when auto-install needed → clear error naming the
  missing tool, exit 1, no attempt to install the package manager itself.
- Auto-install fails → surface the installer's own error output, exit 1,
  don't launch the tool.
- Unresolvable `api_key` on a provider that needs one → warn to stderr, still
  attempt launch (matches `pick.sh`'s existing "any HTTP answer counts as
  reachable" philosophy — let the provider's own auth error surface instead
  of guessing client-side).

## Testing

- `bash -n` on both new scripts.
- Manual dry run through both menus (tool select → model select → correct
  env/flags computed) — can't exercise real network calls against the user's
  API keys from this environment.
- Confirm `config.json.tmpl` still renders to valid JSON (spot-check by eye;
  no real secrets to render against here).
