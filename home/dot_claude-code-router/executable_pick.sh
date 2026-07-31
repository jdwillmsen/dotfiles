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

# Reachability + context window, from one best-effort query of the provider's
# /v1/models. Any HTTP answer counts as reachable — 401 and 404 are normal, as
# providers gate or omit that route — so only a transport failure is conclusive.
# OpenRouter reports context_length, vLLM reports max_model_len; NVIDIA reports
# neither → empty → statusline shows tokens-only.
probe="$( cd "$ccrdir" && node -e '
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
  const done = (s) => { process.stdout.write(s); process.exit(0); };
  const req = lib.get(url, { headers: auth ? { Authorization: "Bearer " + auth } : {}, timeout: 4000 }, res => {
    let b = ""; res.on("data", d => b += d); res.on("end", () => {
      let w = "";
      try {
        const m = (JSON.parse(b).data || []).find(x => x.id === model);
        w = (m && (m.context_length || m.max_model_len)) || "";
      } catch (e) {}
      done("up " + w);
    });
  });
  req.on("error", (e) => done("down " + p.api_base_url + " (" + e.code + ")"));
  req.on("timeout", () => { req.destroy(); done("down " + p.api_base_url + " (timeout)"); });
' "$provider" "$model" 2>/dev/null )" || probe=""

# An unreachable upstream still leaves the router itself answering, so it
# surfaces inside the TUI as an opaque `fetch failed` retry loop with no
# mention of which host is down. Say it here, where it is actionable.
ctxwin=""
case "$probe" in
  "up "*) ctxwin="${probe#up }" ;;
  "down "*)
    echo "  ✖ provider unreachable: ${probe#down }" >&2
    if [ -t 0 ]; then
      read -rp "  launch anyway? [y/N] " yn
      case "$yn" in [yY]*) ;; *) echo "  cancelled"; exit 1 ;; esac
    else
      exit 1
    fi
    ;;
esac

export CCR_ACTIVE_ROUTE="$sel"
export CCR_REASONING="$reason"
[ -n "$ctxwin" ] && export CCR_CTX_WINDOW="$ctxwin"

echo "  → launching Claude Code on: $sel"
echo ""
# Nothing above this point mutates state, so an abandoned pick leaves the
# previous default route intact rather than pointing at a route it refused.
( cd "$ccrdir" && node -e '
  const fs = require("fs");
  const c = require("./config.json");
  c.Router.default = process.argv[1];
  fs.writeFileSync("./config.json", JSON.stringify(c, null, 2));
' "$sel" )

# ── Router boot ──────────────────────────────────────────────────────────────
# The port is the only ground truth: ccr decides "is it running?" from a PID
# file and never touches the socket, so a PID left behind by a service that
# died before it listened reads as running forever. Clearing that file when
# nothing answers is what lets a wedged router recover.
# `ccr restart` is also the only command that daemonises. `ccr start` runs the
# server in the foreground — and returns instantly when the PID file is present
# — so it can neither recover the router nor be waited on.
ccrurl="$(cd "$ccrdir" && node -e '
  const c = require("./config.json");
  console.log("http://" + (c.HOST || "127.0.0.1") + ":" + (c.PORT || 3456));
')"
bootlog="$ccrdir/pick-boot.log"

router_up() { curl -s --max-time 1 -o /dev/null "$ccrurl/"; }
wait_router() {
  for _ in $(seq 1 "${CCRPICK_WAIT_TRIES:-40}"); do
    router_up && return 0
    sleep 0.5
  done
  return 1
}

router_up || rm -f "$ccrdir/.claude-code-router.pid"
ccr restart >"$bootlog" 2>&1 || true
if ! wait_router; then
  # Launching anyway just moves the failure into the TUI as an opaque
  # ConnectionRefused, with ccr's own output discarded — so stop here and show it.
  echo "  ✖ router never came up on $ccrurl — not launching Claude Code" >&2
  echo "  ── ccr boot output ($bootlog) ──" >&2
  tail -n 20 "$bootlog" >&2 || true
  # shellcheck disable=SC2012  # ccr names its logs from a timestamp; no spaces to mishandle
  last_log="$(ls -1t "$ccrdir"/logs/*.log 2>/dev/null | head -n 1 || true)"
  if [ -n "$last_log" ]; then
    echo "  ── last router log ($last_log) ──" >&2
    tail -n 20 "$last_log" >&2 || true
  fi
  ccr status >&2 2>&1 || true
  exit 1
fi

# Launch the same `claude` binary you run daily (stable in mintty) pointed at the
# local router — NOT `ccr code`, whose spawner asserts on process-title in Git-Bash
# (libuv util.c:412). These are the exact env vars `ccr code` injects.
#
# Header trick: Claude Code renders whatever ANTHROPIC_MODEL names in its banner,
# and CCR routes "provider,model" ids directly — so the TUI banner shows the real route.
export ANTHROPIC_MODEL="$sel"

export ANTHROPIC_BASE_URL="$ccrurl"
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
# shellcheck disable=SC2086  # unquoted on purpose: an empty override must drop the flag, not pass ""
exec claude ${CCRPICK_PERMISSION_FLAG-"--dangerously-skip-permissions"}   # runs in your current project dir, not the config dir
