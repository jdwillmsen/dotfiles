#!/usr/bin/env bash
# check-openrouter-freshness — flag configured openrouter models OpenRouter no
# longer serves free. The free tier churns without notice (see
# refresh-openrouter-free.sh) — a delisted slug fails at launch time as an
# opaque 404 deep inside whichever tool aipick handed it to. This catches it
# ahead of time instead.
# Usage: bash ~/.claude-code-router/check-openrouter-freshness.sh [fixture.json]
#   fixture.json — optional, forwarded to refresh-openrouter-free.sh for
#   testing instead of hitting the live endpoint.
set -euo pipefail

ccrdir="$HOME/.claude-code-router"
[ -f "$ccrdir/config.json" ] || { echo "no CCR config at $ccrdir/config.json" >&2; exit 1; }

configured="$(cd "$ccrdir" && node -e '
  const c = require("./config.json");
  const p = (c.Providers || []).find(p => p.name === "openrouter");
  for (const m of (p ? p.models : [])) console.log(m);
')"
[ -n "$configured" ] || { echo "no openrouter models configured"; exit 0; }

free="$(bash "$ccrdir/refresh-openrouter-free.sh" "${1:-}")"

stale=()
while IFS= read -r m; do
  [ -n "$m" ] || continue
  grep -qxF "$m" <<<"$free" || stale+=("$m")
done <<<"$configured"

if [ "${#stale[@]}" -gt 0 ]; then
  echo "✖ configured openrouter model(s) no longer free:" >&2
  printf '  %s\n' "${stale[@]}" >&2
  exit 1
fi
echo "all configured openrouter models are currently free"
