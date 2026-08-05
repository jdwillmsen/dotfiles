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
  2|3) ;;
  *) echo "  not a valid choice" >&2; exit 1 ;;
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
    echo "  → launching aider on: $sel"
    exec aider --openai-api-base "$base" --openai-api-key "$key" --model "openai/$model"
    ;;
  3)
    if [ "${AIPICK_DRY_RUN:-}" = "1" ]; then
      echo "  DRY-RUN OPENAI_API_KEY=*** OPENAI_BASE_URL=\"$base\" OPENAI_MODEL=\"$model\" qwen"
      exit 0
    fi
    if ! command -v qwen >/dev/null 2>&1; then
      echo "  qwen not found — installing..." >&2
      if command -v npm >/dev/null 2>&1; then
        npm i -g @qwen-code/qwen-code
      else
        echo "  ✖ npm not found — install Node.js/npm first" >&2
        exit 1
      fi
    fi
    export OPENAI_API_KEY="$key"
    export OPENAI_BASE_URL="$base"
    export OPENAI_MODEL="$model"
    echo "  → launching qwen on: $sel"
    exec qwen
    ;;
esac
