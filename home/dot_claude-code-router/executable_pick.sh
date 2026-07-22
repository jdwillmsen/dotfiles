#!/usr/bin/env bash
# CCR fallback picker — list configured free/local models, pick one, launch Claude Code through it.
# Git-Bash safe: node reads/writes ./config.json from inside the config dir (subshell), so MSYS
# never mangles a leading-slash path, and your project cwd is preserved for `ccr code`.
# Usage:  bash ~/.claude-code-router/pick.sh      (or alias ccrpick — see setup notes)
set -euo pipefail

ccrdir="$HOME/.claude-code-router"
[ -f "$ccrdir/config.json" ] || { echo "no CCR config at $ccrdir/config.json" >&2; exit 1; }

mapfile -t routes < <(cd "$ccrdir" && node -e '
  const c = require("./config.json");
  for (const p of c.Providers) for (const m of p.models) console.log(p.name + "," + m);
')
[ "${#routes[@]}" -gt 0 ] || { echo "no models in config" >&2; exit 1; }

def="$(cd "$ccrdir" && node -e 'console.log(require("./config.json").Router.default || "")')"

echo ""
echo "  CCR fallback tier — pick a model to launch Claude Code on:"
echo "  ─────────────────────────────────────────────────────────"
for i in "${!routes[@]}"; do
  mark=" "; [ "${routes[$i]}" = "$def" ] && mark="*"
  printf "   %s %2d) %s\n" "$mark" "$((i+1))" "${routes[$i]}"
done
echo "          q) cancel        (* = current default)"
echo ""
read -rp "  pick # > " n
[ "$n" = "q" ] && { echo "  cancelled"; exit 0; }
case "$n" in *[!0-9]*|"") echo "  not a number" >&2; exit 1;; esac
sel="${routes[$((n-1))]:-}"
[ -n "$sel" ] || { echo "  out of range" >&2; exit 1; }

# set it as the default route, reload service
( cd "$ccrdir" && node -e '
  const fs = require("fs");
  const c = require("./config.json");
  c.Router.default = process.argv[1];
  fs.writeFileSync("./config.json", JSON.stringify(c, null, 2));
' "$sel" )
ccr restart >/dev/null 2>&1 || true

# ── Stamp fallback state for the statusline (read by claude-status) ───────────
provider="${sel%%,*}"
model="${sel#*,}"

# Reasoning: off when this provider strips it (strip-reasoning transformer).
reason="on"
if ( cd "$ccrdir" && node -e '
  const c = require("./config.json");
  const p = (c.Providers || []).find(p => p.name === process.argv[1]);
  const use = (p && p.transformer && p.transformer.use) || [];
  process.exit(use.includes("strip-reasoning") ? 0 : 1);
' "$provider" ); then reason="off"; fi

# Context window: best-effort live query of the provider's /v1/models.
# OpenRouter reports context_length, vLLM reports max_model_len; NVIDIA reports
# neither → empty → statusline shows tokens-only.
ctxwin="$( cd "$ccrdir" && node -e '
  const http = require("http"), https = require("https");
  const c = require("./config.json");
  const p = (c.Providers || []).find(p => p.name === process.argv[1]);
  const model = process.argv[2];
  if (!p) process.exit(0);
  const base = p.api_base_url.replace(/\/chat\/completions$/, "").replace(/\/+$/, "");
  const url = base + "/models";
  const keyRef = (p.api_key || "").replace(/^\$/, "");
  const auth = (keyRef && process.env[keyRef]) ? process.env[keyRef] : (p.api_key || "");
  const lib = url.startsWith("https") ? https : http;
  const req = lib.get(url, { headers: auth ? { Authorization: "Bearer " + auth } : {}, timeout: 4000 }, res => {
    let b = ""; res.on("data", d => b += d); res.on("end", () => {
      try {
        const m = (JSON.parse(b).data || []).find(x => x.id === model);
        const w = m && (m.context_length || m.max_model_len);
        if (w) process.stdout.write(String(w));
      } catch (e) {}
      process.exit(0);
    });
  });
  req.on("error", () => process.exit(0));
  req.on("timeout", () => { req.destroy(); process.exit(0); });
' "$provider" "$model" 2>/dev/null || true )"

export CCR_ACTIVE_ROUTE="$sel"
export CCR_REASONING="$reason"
[ -n "$ctxwin" ] && export CCR_CTX_WINDOW="$ctxwin"

echo "  → launching Claude Code on: $sel"
echo ""
# Launch the same `claude` binary you run daily (stable in mintty) pointed at the
# local router — NOT `ccr code`, whose spawner asserts on process-title in Git-Bash
# (libuv util.c:412). These are the exact env vars `ccr code` injects.
# Wait for the router to actually accept connections — `ccr restart` returns
# before the port is up, and Claude Code's first requests race it (ConnectionRefused).
wait_router() {
  for _ in $(seq 1 30); do
    if curl -s --max-time 1 -o /dev/null "http://127.0.0.1:3456/"; then return 0; fi
    sleep 0.5
  done
  return 1
}
if ! wait_router; then
  echo "  router down — starting ccr…"
  ccr start >/dev/null 2>&1 || true
  wait_router || echo "  ⚠ router still not answering on 127.0.0.1:3456 — check: ccr status" >&2
fi

# Header trick: Claude Code renders whatever ANTHROPIC_MODEL names in its banner,
# and CCR routes "provider,model" ids directly — so the TUI banner shows the real route.
export ANTHROPIC_MODEL="$sel"

export ANTHROPIC_BASE_URL="http://127.0.0.1:3456"
export ANTHROPIC_AUTH_TOKEN="test"
export ANTHROPIC_API_KEY=""
export NO_PROXY="127.0.0.1"
export DISABLE_TELEMETRY="true"
export DISABLE_COST_WARNINGS="true"
export API_TIMEOUT_MS="600000"
unset CLAUDE_CODE_USE_BEDROCK
# Bypass permissions: fallback sessions are interactive break-glass work; prompts
# on slow free-tier models cost more than they protect. Override per-launch:
#   CCRPICK_PERMISSION_FLAG="" ccrpick               (native prompting)
#   CCRPICK_PERMISSION_FLAG="--permission-mode acceptEdits" ccrpick
exec claude ${CCRPICK_PERMISSION_FLAG-"--dangerously-skip-permissions"}   # runs in your current project dir, not the config dir
