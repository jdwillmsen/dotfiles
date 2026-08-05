# aipick Multi-CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One picker (`aipick`) that launches Claude Code (via CCR), Aider, or
Qwen Code against the same free/local model tier defined in `config.json`,
plus a script to check what's currently free on OpenRouter.

**Architecture:** New `executable_aipick.sh` asks tool-first, then model.
Claude Code delegates to the existing, untouched `pick.sh`. Aider and Qwen
Code connect straight to the provider (they speak OpenAI format natively —
no CCR hop). `config.json.tmpl` gains current NVIDIA NIM free models and
drops one confirmed-dead OpenRouter entry. A standalone
`executable_refresh-openrouter-free.sh` prints what's currently free on
OpenRouter (read-only, never edits config).

**Tech Stack:** Bash (`set -euo pipefail`), Node.js one-liners for JSON
(matches `pick.sh`'s existing pattern — no new dependency), `curl` for the
OpenRouter refresh script.

## Global Constraints

- `set -euo pipefail` on every new script (matches `pick.sh`).
- Error/status lines use the existing two-space-indent `echo "  ..."` style;
  errors go to `>&2`.
- Reuse `pick.sh`'s exact `api_key`/`api_base_url` resolution logic (literal
  string, or `$ENV_VAR` name to look up; strip `/chat/completions` +
  trailing slashes off the base URL) — don't invent a different scheme.
- No change to `pick.sh` itself.
- No auto-editing of `config.json` from the refresh script.
- New scripts get the `executable_` chezmoi filename prefix (sets +x on
  `chezmoi apply`, same as `executable_pick.sh`).
- Bash arrays / `mapfile` require real bash — scripts are invoked as
  `bash <path>`, never sourced or run under `sh`.

---

### Task 1: `aipick.sh` — tool menu + Claude Code delegation

**Files:**
- Create: `home/dot_claude-code-router/executable_aipick.sh`

**Interfaces:**
- Consumes: `$HOME/.claude-code-router/config.json` (existence only, for the
  guard) and `$HOME/.claude-code-router/pick.sh` (delegated to via `exec`).
- Produces: a script invocable as `bash aipick.sh` that shows a tool menu
  and, on `1`, execs `pick.sh` unchanged. `2`/`3` are rejected for now
  (Tasks 2–4 add them).

- [ ] **Step 1: Write the failing test**

```bash
mkdir -p /tmp/aipick-test && cat > /tmp/aipick-test/task1.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
mkdir -p "$tmp/.claude-code-router"
echo '{"Providers":[]}' > "$tmp/.claude-code-router/config.json"
cat > "$tmp/.claude-code-router/pick.sh" <<'SH'
#!/usr/bin/env bash
echo "PICK_SH_CALLED"
SH
chmod +x "$tmp/.claude-code-router/pick.sh"

out="$(printf '1\n' | HOME="$tmp" bash home/dot_claude-code-router/executable_aipick.sh)"
echo "$out" | grep -q "PICK_SH_CALLED" && echo "PASS: delegates to pick.sh" || { echo "FAIL: no delegation"; exit 1; }

out2="$(printf 'q\n' | HOME="$tmp" bash home/dot_claude-code-router/executable_aipick.sh)"
echo "$out2" | grep -q "cancelled" && echo "PASS: q cancels" || { echo "FAIL: q didn't cancel"; exit 1; }

rm -rf "$tmp"
TEST
chmod +x /tmp/aipick-test/task1.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `bash /tmp/aipick-test/task1.sh`
Expected: FAIL — `home/dot_claude-code-router/executable_aipick.sh` doesn't exist yet.

- [ ] **Step 3: Write the script**

```bash
cat > home/dot_claude-code-router/executable_aipick.sh <<'SCRIPT'
#!/usr/bin/env bash
# aipick — pick a tool (Claude Code / Aider / Qwen Code) and a model from the
# same CCR fallback-tier config.json, then launch that tool correctly wired.
# Claude Code goes through pick.sh/CCR (Anthropic-format shim). Aider and
# Qwen Code speak OpenAI format natively, so they connect straight to the
# provider — no CCR hop.
# Usage: bash ~/.claude-code-router/aipick.sh   (or alias aipick)
set -euo pipefail

ccrdir="$HOME/.claude-code-router"
[ -f "$ccrdir/config.json" ] || { echo "no CCR config at $ccrdir/config.json" >&2; exit 1; }

echo ""
echo "  aipick — choose a tool:"
echo "  ────────────────────────"
echo "   1) Claude Code   (via CCR)"
echo "   2) Aider"
echo "   3) Qwen Code"
echo "   q) cancel"
echo ""
read -rp "  tool # > " tool
case "$tool" in
  q) echo "  cancelled"; exit 0 ;;
  1) exec bash "$ccrdir/pick.sh" ;;
  *) echo "  not a valid choice (aider/qwen-code land in a later task)" >&2; exit 1 ;;
esac
SCRIPT
chmod +x home/dot_claude-code-router/executable_aipick.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task1.sh`
Expected: both `PASS:` lines print, exit 0.

- [ ] **Step 5: Commit**

```bash
git add home/dot_claude-code-router/executable_aipick.sh
git commit -m "feat(ccr): add aipick tool menu with Claude Code delegation"
```

---

### Task 2: `aipick.sh` — model picker, key/base resolution, Aider path

**Files:**
- Modify: `home/dot_claude-code-router/executable_aipick.sh`

**Interfaces:**
- Consumes: `config.json` shape `{"Providers":[{"name","api_base_url","api_key","models":[...]}]}` — same shape `pick.sh` already reads.
- Produces: for `tool=2`, a resolved `$provider/$model/$key/$base`, an
  `AIPICK_DRY_RUN=1` short-circuit that prints the exact `aider` invocation
  instead of running it, and (non-dry-run) an `exec aider --openai-api-base
  "$base" --openai-api-key "$key" --model "openai/$model"` — errors out if
  `aider` isn't installed (Task 4 adds auto-install).

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/aipick-test/task2.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
mkdir -p "$tmp/.claude-code-router"
cat > "$tmp/.claude-code-router/config.json" <<'JSON'
{
  "Providers": [
    {
      "name": "ollama",
      "api_base_url": "http://127.0.0.1:11434/v1/chat/completions",
      "api_key": "ollama",
      "models": ["gpt-oss:20b"]
    }
  ]
}
JSON

out="$(printf '2\n1\n' | HOME="$tmp" AIPICK_DRY_RUN=1 bash home/dot_claude-code-router/executable_aipick.sh)"
echo "$out"
echo "$out" | grep -q -- '--openai-api-base "http://127.0.0.1:11434/v1"' && echo "PASS: base stripped correctly" || { echo "FAIL: base wrong"; exit 1; }
echo "$out" | grep -q -- '--model "openai/gpt-oss:20b"' && echo "PASS: model prefixed" || { echo "FAIL: model wrong"; exit 1; }
echo "$out" | grep -q -- '--openai-api-key "ollama"' && echo "PASS: literal key resolved" || { echo "FAIL: key wrong"; exit 1; }

rm -rf "$tmp"
TEST
chmod +x /tmp/aipick-test/task2.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/aipick-test/task2.sh`
Expected: FAIL — choosing `2` currently hits the `*) not a valid choice` branch.

- [ ] **Step 3: Extend the script**

Replace the whole file (Task 1's content plus the model picker + Aider path):

```bash
cat > home/dot_claude-code-router/executable_aipick.sh <<'SCRIPT'
#!/usr/bin/env bash
# aipick — pick a tool (Claude Code / Aider / Qwen Code) and a model from the
# same CCR fallback-tier config.json, then launch that tool correctly wired.
# Claude Code goes through pick.sh/CCR (Anthropic-format shim). Aider and
# Qwen Code speak OpenAI format natively, so they connect straight to the
# provider — no CCR hop.
# Usage: bash ~/.claude-code-router/aipick.sh   (or alias aipick)
set -euo pipefail

ccrdir="$HOME/.claude-code-router"
[ -f "$ccrdir/config.json" ] || { echo "no CCR config at $ccrdir/config.json" >&2; exit 1; }

echo ""
echo "  aipick — choose a tool:"
echo "  ────────────────────────"
echo "   1) Claude Code   (via CCR)"
echo "   2) Aider"
echo "   3) Qwen Code"
echo "   q) cancel"
echo ""
read -rp "  tool # > " tool
case "$tool" in
  q) echo "  cancelled"; exit 0 ;;
  1) exec bash "$ccrdir/pick.sh" ;;
  2) ;;
  *) echo "  not a valid choice (qwen-code lands in a later task)" >&2; exit 1 ;;
esac

# ── Model picker (Aider / Qwen Code) — same provider/model list pick.sh uses ──
mapfile -t routes < <(cd "$ccrdir" && node -e '
  const c = require("./config.json");
  for (const p of c.Providers) for (const m of p.models) console.log(p.name + "," + m);
')
[ "${#routes[@]}" -gt 0 ] || { echo "no models in config" >&2; exit 1; }

echo ""
echo "  pick a model:"
echo "  ─────────────"
for i in "${!routes[@]}"; do
  printf "    %2d) %s\n" "$((i+1))" "${routes[$i]}"
done
echo "           q) cancel"
echo ""
read -rp "  pick # > " n
[ "$n" = "q" ] && { echo "  cancelled"; exit 0; }
case "$n" in *[!0-9]*|"") echo "  not a number" >&2; exit 1;; esac
sel="${routes[$((n-1))]:-}"
[ -n "$sel" ] || { echo "  out of range" >&2; exit 1; }

provider="${sel%%,*}"
model="${sel#*,}"

# key<TAB>base — same resolution pick.sh's reachability probe already uses:
# api_key is a literal string, or "$ENV_VAR" naming an env var to look up.
resolved="$(cd "$ccrdir" && node -e '
  const c = require("./config.json");
  const p = (c.Providers || []).find(p => p.name === process.argv[1]);
  if (!p) process.exit(1);
  const keyRef = (p.api_key || "").replace(/^\$/, "");
  const key = (keyRef && process.env[keyRef]) ? process.env[keyRef] : (p.api_key || "");
  const base = p.api_base_url.replace(/\/chat\/completions$/, "").replace(/\/+$/, "");
  process.stdout.write(key + "\t" + base);
' "$provider")"
key="${resolved%%$'\t'*}"
base="${resolved#*$'\t'}"

[ -n "$key" ] || echo "  ⚠ no api key resolved for $provider — launching anyway (dummy-key tolerant providers only)" >&2

case "$tool" in
  2)
    if [ "${AIPICK_DRY_RUN:-}" = "1" ]; then
      echo "  DRY-RUN aider --openai-api-base \"$base\" --openai-api-key \"$key\" --model \"openai/$model\""
      exit 0
    fi
    if ! command -v aider >/dev/null 2>&1; then
      echo "  ✖ aider not installed — run: pipx install aider-chat" >&2
      exit 1
    fi
    echo "  → launching aider on: $sel"
    exec aider --openai-api-base "$base" --openai-api-key "$key" --model "openai/$model"
    ;;
esac
SCRIPT
chmod +x home/dot_claude-code-router/executable_aipick.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task2.sh`
Expected: all three `PASS:` lines print, exit 0. Also re-run Task 1's test
(`bash /tmp/aipick-test/task1.sh`) to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add home/dot_claude-code-router/executable_aipick.sh
git commit -m "feat(ccr): add aipick model picker and direct-to-provider Aider launch"
```

---

### Task 3: `aipick.sh` — Qwen Code path

**Files:**
- Modify: `home/dot_claude-code-router/executable_aipick.sh`

**Interfaces:**
- Consumes: same resolved `$provider/$model/$key/$base` from Task 2's shared
  picker code (unchanged).
- Produces: for `tool=3`, an `AIPICK_DRY_RUN=1` short-circuit printing the
  `OPENAI_*` env vars + `qwen`, and (non-dry-run)
  `export OPENAI_API_KEY/OPENAI_BASE_URL/OPENAI_MODEL; exec qwen` — errors
  out if `qwen` isn't installed (Task 4 adds auto-install).

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/aipick-test/task3.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
mkdir -p "$tmp/.claude-code-router"
cat > "$tmp/.claude-code-router/config.json" <<'JSON'
{
  "Providers": [
    {
      "name": "ollama",
      "api_base_url": "http://127.0.0.1:11434/v1/chat/completions",
      "api_key": "ollama",
      "models": ["gpt-oss:20b"]
    }
  ]
}
JSON

out="$(printf '3\n1\n' | HOME="$tmp" AIPICK_DRY_RUN=1 bash home/dot_claude-code-router/executable_aipick.sh)"
echo "$out"
echo "$out" | grep -q 'OPENAI_BASE_URL="http://127.0.0.1:11434/v1"' && echo "PASS: base" || { echo "FAIL: base wrong"; exit 1; }
echo "$out" | grep -q 'OPENAI_MODEL="gpt-oss:20b"' && echo "PASS: model" || { echo "FAIL: model wrong"; exit 1; }

rm -rf "$tmp"
TEST
chmod +x /tmp/aipick-test/task3.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/aipick-test/task3.sh`
Expected: FAIL — choosing `3` currently hits the `*) not a valid choice` branch.

- [ ] **Step 3: Extend the script**

Two small edits to `home/dot_claude-code-router/executable_aipick.sh`:

Edit 1 — widen the tool-select case to accept `3`:

```
old_string:
  1) exec bash "$ccrdir/pick.sh" ;;
  2) ;;
  *) echo "  not a valid choice (qwen-code lands in a later task)" >&2; exit 1 ;;

new_string:
  1) exec bash "$ccrdir/pick.sh" ;;
  2|3) ;;
  *) echo "  not a valid choice" >&2; exit 1 ;;
```

Edit 2 — add the `3)` branch after the existing `2)` branch inside the
final `case "$tool" in ... esac`:

```
old_string:
    echo "  → launching aider on: $sel"
    exec aider --openai-api-base "$base" --openai-api-key "$key" --model "openai/$model"
    ;;
esac

new_string:
    echo "  → launching aider on: $sel"
    exec aider --openai-api-base "$base" --openai-api-key "$key" --model "openai/$model"
    ;;
  3)
    if [ "${AIPICK_DRY_RUN:-}" = "1" ]; then
      echo "  DRY-RUN OPENAI_API_KEY=*** OPENAI_BASE_URL=\"$base\" OPENAI_MODEL=\"$model\" qwen"
      exit 0
    fi
    if ! command -v qwen >/dev/null 2>&1; then
      echo "  ✖ qwen not installed — run: npm i -g @qwen-code/qwen-code" >&2
      exit 1
    fi
    export OPENAI_API_KEY="$key"
    export OPENAI_BASE_URL="$base"
    export OPENAI_MODEL="$model"
    echo "  → launching qwen on: $sel"
    exec qwen
    ;;
esac
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task3.sh`
Expected: both `PASS:` lines print, exit 0. Re-run Tasks 1 and 2's tests too
— no regression.

- [ ] **Step 5: Commit**

```bash
git add home/dot_claude-code-router/executable_aipick.sh
git commit -m "feat(ccr): add aipick Qwen Code launch path"
```

---

### Task 4: `aipick.sh` — auto-install Aider and Qwen Code on first use

**Files:**
- Modify: `home/dot_claude-code-router/executable_aipick.sh`

**Interfaces:**
- Consumes: `command -v aider|pipx|pip|qwen|npm` (PATH lookups) — no new
  external interface.
- Produces: the `2)`/`3)` branches now install the missing binary once
  (`pipx install aider-chat` → falls back to `pip install --user aider-chat`
  → falls back to a clear error; `npm i -g @qwen-code/qwen-code` → clear
  error if `npm` missing) before launching, instead of erroring immediately.

- [ ] **Step 1: Write the failing test**

Tests the *detection* logic only (no real installs) by putting fake
executables on `PATH`.

```bash
cat > /tmp/aipick-test/task4.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
mkdir -p "$tmp/.claude-code-router" "$tmp/bin"
cat > "$tmp/.claude-code-router/config.json" <<'JSON'
{
  "Providers": [
    {
      "name": "ollama",
      "api_base_url": "http://127.0.0.1:11434/v1/chat/completions",
      "api_key": "ollama",
      "models": ["gpt-oss:20b"]
    }
  ]
}
JSON

# Fake pipx that just logs its args instead of installing anything.
cat > "$tmp/bin/pipx" <<'SH'
#!/usr/bin/env bash
echo "PIPX_INSTALL_CALLED: $*"
SH
chmod +x "$tmp/bin/pipx"

# NOTE: this assumes real `aider`/`pipx` aren't already earlier on your
# inherited PATH than $tmp/bin — true for a stock machine, but if you've
# already installed aider globally this test can false-pass. Prepending
# $tmp/bin makes the fake pipx win; keeping the rest of $PATH intact keeps
# node/bash/curl reachable for the rest of the script.
out="$(printf '2\n1\n' | HOME="$tmp" PATH="$tmp/bin:$PATH" bash home/dot_claude-code-router/executable_aipick.sh 2>&1 || true)"
echo "$out"
echo "$out" | grep -q "PIPX_INSTALL_CALLED: install aider-chat" && echo "PASS: pipx install triggered" || { echo "FAIL: pipx install not triggered"; exit 1; }

rm -rf "$tmp"
TEST
chmod +x /tmp/aipick-test/task4.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/aipick-test/task4.sh`
Expected: FAIL — current script errors with "aider not installed" instead
of attempting a `pipx install`.

- [ ] **Step 3: Wire in auto-install**

Two edits to `home/dot_claude-code-router/executable_aipick.sh`:

Edit 1 — Aider branch:

```
old_string:
    if ! command -v aider >/dev/null 2>&1; then
      echo "  ✖ aider not installed — run: pipx install aider-chat" >&2
      exit 1
    fi

new_string:
    if ! command -v aider >/dev/null 2>&1; then
      echo "  aider not found — installing..." >&2
      if command -v pipx >/dev/null 2>&1; then
        pipx install aider-chat
      elif command -v pip >/dev/null 2>&1; then
        pip install --user aider-chat
      else
        echo "  ✖ neither pipx nor pip found — install pipx first: https://pipx.pypa.io" >&2
        exit 1
      fi
    fi
```

Edit 2 — Qwen Code branch:

```
old_string:
    if ! command -v qwen >/dev/null 2>&1; then
      echo "  ✖ qwen not installed — run: npm i -g @qwen-code/qwen-code" >&2
      exit 1
    fi

new_string:
    if ! command -v qwen >/dev/null 2>&1; then
      echo "  qwen not found — installing..." >&2
      if command -v npm >/dev/null 2>&1; then
        npm i -g @qwen-code/qwen-code
      else
        echo "  ✖ npm not found — install Node.js/npm first" >&2
        exit 1
      fi
    fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task4.sh`
Expected: `PASS: pipx install triggered`, exit 0. Re-run Tasks 1–3's tests —
no regression.

- [ ] **Step 5: Commit**

```bash
git add home/dot_claude-code-router/executable_aipick.sh
git commit -m "feat(ccr): auto-install aider/qwen-code on first aipick use"
```

---

### Task 5: `config.json.tmpl` — new free models + router updates

**Files:**
- Modify: `home/dot_claude-code-router/config.json.tmpl`

**Interfaces:**
- Consumes: nothing (static template).
- Produces: `nvidia` provider `models[]` gains three ids; `Router.think` and
  `Router.longContext` point at two of them; `openrouter` provider loses one
  dead id. This is what Task 1–4's `aipick.sh` (and unmodified `pick.sh`)
  read at runtime.

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/aipick-test/task5.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
f="home/dot_claude-code-router/config.json.tmpl"

grep -q "qwen/qwen3-coder-480b-a35b-instruct" "$f" && echo "PASS: qwen3-coder-480b present" || { echo "FAIL: missing qwen3-coder-480b"; exit 1; }
grep -q "minimaxai/minimax-m3" "$f" && echo "PASS: minimax-m3 present" || { echo "FAIL: missing minimax-m3"; exit 1; }
grep -q "moonshotai/kimi-k2.6" "$f" && echo "PASS: kimi-k2.6 present" || { echo "FAIL: missing kimi-k2.6"; exit 1; }
grep -q '"think": "nvidia,moonshotai/kimi-k2.6"' "$f" && echo "PASS: think updated" || { echo "FAIL: think not updated"; exit 1; }
grep -q '"longContext": "nvidia,minimaxai/minimax-m3"' "$f" && echo "PASS: longContext updated" || { echo "FAIL: longContext not updated"; exit 1; }
! grep -q "qwen/qwen3-coder:free" "$f" && echo "PASS: dead openrouter entry removed" || { echo "FAIL: dead entry still present"; exit 1; }

# Validate the file is still well-formed JSON once the one Go-template line
# is swapped for a literal string (that's the only non-JSON syntax in it).
rendered="$(sed 's#{{ \.chezmoi\.homeDir | replace "\\\\" "/" }}#/home/test#' "$f")"
echo "$rendered" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8")); console.log("PASS: valid JSON")'
TEST
chmod +x /tmp/aipick-test/task5.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/aipick-test/task5.sh`
Expected: FAIL on the first `qwen3-coder-480b` check — none of the new
models are in the file yet.

- [ ] **Step 3: Update the template**

```
old_string:
      "models": [
        "deepseek-ai/deepseek-v4-pro",
        "deepseek-ai/deepseek-v4-flash",
        "qwen/qwen3.5-397b-a17b",
        "z-ai/glm-5.2"
      ],

new_string:
      "models": [
        "deepseek-ai/deepseek-v4-pro",
        "deepseek-ai/deepseek-v4-flash",
        "qwen/qwen3.5-397b-a17b",
        "z-ai/glm-5.2",
        "qwen/qwen3-coder-480b-a35b-instruct",
        "minimaxai/minimax-m3",
        "moonshotai/kimi-k2.6"
      ],
```

```
old_string:
      "models": [
        "qwen/qwen3-coder:free",
        "qwen/qwen3-next-80b-a3b-instruct:free"
      ],

new_string:
      "models": [
        "qwen/qwen3-next-80b-a3b-instruct:free"
      ],
```

```
old_string:
    "default": "ollama,gpt-oss:20b",
    "think": "nvidia,z-ai/glm-5.2",
    "background": "gpu-stack,qwen/qwen3-coder-30b-a3b",
    "longContext": "nvidia,z-ai/glm-5.2",

new_string:
    "default": "ollama,gpt-oss:20b",
    "think": "nvidia,moonshotai/kimi-k2.6",
    "background": "gpu-stack,qwen/qwen3-coder-30b-a3b",
    "longContext": "nvidia,minimaxai/minimax-m3",
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task5.sh`
Expected: all `PASS:` lines print, ending with `PASS: valid JSON`.

- [ ] **Step 5: Commit**

```bash
git add home/dot_claude-code-router/config.json.tmpl
git commit -m "feat(ccr): add NVIDIA NIM free coding models, drop dead OpenRouter entry"
```

---

### Task 6: `refresh-openrouter-free.sh` — free-tier check

**Files:**
- Create: `home/dot_claude-code-router/executable_refresh-openrouter-free.sh`

**Interfaces:**
- Consumes (live mode): `GET https://openrouter.ai/api/v1/models` → JSON
  `{"data":[{"id": "...", "pricing": {"prompt": "0"|"...", "completion": "0"|"..."}}]}`.
  For testing, accepts an optional file argument holding that same JSON
  shape instead of hitting the network.
- Produces: one free model `id` per line to stdout, filtered to entries
  where `pricing.prompt == "0"` and `pricing.completion == "0"`. Never
  writes to `config.json`.

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/aipick-test/task6.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
tmp="$(mktemp -d)"
cat > "$tmp/models.json" <<'JSON'
{
  "data": [
    {"id": "qwen/qwen3-next-80b-a3b-instruct:free", "pricing": {"prompt": "0", "completion": "0"}},
    {"id": "moonshotai/kimi-k3", "pricing": {"prompt": "3", "completion": "15"}},
    {"id": "some/other-free-model:free", "pricing": {"prompt": "0", "completion": "0"}}
  ]
}
JSON

out="$(bash home/dot_claude-code-router/executable_refresh-openrouter-free.sh "$tmp/models.json")"
echo "$out"
echo "$out" | grep -qx "qwen/qwen3-next-80b-a3b-instruct:free" && echo "PASS: free model 1 listed" || { echo "FAIL"; exit 1; }
echo "$out" | grep -qx "some/other-free-model:free" && echo "PASS: free model 2 listed" || { echo "FAIL"; exit 1; }
! echo "$out" | grep -q "kimi-k3" && echo "PASS: paid model excluded" || { echo "FAIL: paid model leaked through"; exit 1; }

rm -rf "$tmp"
TEST
chmod +x /tmp/aipick-test/task6.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/aipick-test/task6.sh`
Expected: FAIL — script doesn't exist yet.

- [ ] **Step 3: Write the script**

```bash
cat > home/dot_claude-code-router/executable_refresh-openrouter-free.sh <<'SCRIPT'
#!/usr/bin/env bash
# refresh-openrouter-free — print currently-free OpenRouter model ids.
# Read-only: never touches config.json. The free lineup on OpenRouter churns
# (models get delisted without notice) — run this whenever you want to
# recheck, then paste what you want into config.json's openrouter provider
# by hand.
# Usage: bash ~/.claude-code-router/refresh-openrouter-free.sh [fixture.json]
#   fixture.json — optional, for testing: read this file instead of hitting
#   the live https://openrouter.ai/api/v1/models endpoint.
set -euo pipefail

source="${1:-}"
if [ -n "$source" ]; then
  body="$(cat "$source")"
else
  body="$(curl -s --max-time 10 https://openrouter.ai/api/v1/models)"
fi

node -e '
  const body = require("fs").readFileSync(0, "utf8");
  const data = (JSON.parse(body).data || []);
  for (const m of data) {
    const p = m.pricing || {};
    if (p.prompt === "0" && p.completion === "0") console.log(m.id);
  }
' <<< "$body"
SCRIPT
chmod +x home/dot_claude-code-router/executable_refresh-openrouter-free.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task6.sh`
Expected: all three `PASS:` lines print, exit 0.

- [ ] **Step 5: Commit**

```bash
git add home/dot_claude-code-router/executable_refresh-openrouter-free.sh
git commit -m "feat(ccr): add OpenRouter free-tier model refresh script"
```

---

### Task 7: Aliases + full integration check

**Files:**
- Modify: `home/dot_config/shell/aliases.sh`

**Interfaces:**
- Consumes: `~/.claude-code-router/aipick.sh` and
  `~/.claude-code-router/refresh-openrouter-free.sh` (Tasks 1–6, post
  `chezmoi apply` — the `executable_` prefix is stripped and +x is set on
  apply, same as the existing `ccrpick` alias's target).
- Produces: two new aliases, `aipick` and `orfree`.

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/aipick-test/task7.sh <<'TEST'
#!/usr/bin/env bash
set -euo pipefail
f="home/dot_config/shell/aliases.sh"
grep -q "alias aipick='bash ~/.claude-code-router/aipick.sh'" "$f" && echo "PASS: aipick alias present" || { echo "FAIL"; exit 1; }
grep -q "alias orfree='bash ~/.claude-code-router/refresh-openrouter-free.sh'" "$f" && echo "PASS: orfree alias present" || { echo "FAIL"; exit 1; }
grep -q "alias ccrpick='bash ~/.claude-code-router/pick.sh'" "$f" && echo "PASS: ccrpick untouched" || { echo "FAIL: ccrpick alias missing/changed"; exit 1; }
bash -n "$f" && echo "PASS: aliases.sh syntax ok" || { echo "FAIL: syntax error"; exit 1; }
TEST
chmod +x /tmp/aipick-test/task7.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash /tmp/aipick-test/task7.sh`
Expected: FAIL on the first grep — new aliases aren't added yet.

- [ ] **Step 3: Add the aliases**

```
old_string:
alias ccrpick='bash ~/.claude-code-router/pick.sh'

new_string:
alias ccrpick='bash ~/.claude-code-router/pick.sh'
alias aipick='bash ~/.claude-code-router/aipick.sh'
alias orfree='bash ~/.claude-code-router/refresh-openrouter-free.sh'
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash /tmp/aipick-test/task7.sh`
Expected: all four `PASS:` lines print, exit 0.

- [ ] **Step 5: Full integration sweep**

```bash
bash -n home/dot_claude-code-router/executable_aipick.sh
bash -n home/dot_claude-code-router/executable_refresh-openrouter-free.sh
bash -n home/dot_config/shell/aliases.sh
for t in 1 2 3 4 5 6 7; do bash "/tmp/aipick-test/task${t}.sh"; done
```

Expected: no syntax errors, every task's test still passes end to end.

- [ ] **Step 6: Commit**

```bash
git add home/dot_config/shell/aliases.sh
git commit -m "feat(ccr): wire up aipick and orfree aliases"
```
