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
