#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
f="$here/home/dot_claude-code-router/config.json.tmpl"

grep -q "qwen/qwen3-coder-480b-a35b-instruct" "$f" || { echo "FAIL: missing qwen3-coder-480b"; exit 1; }
grep -q "minimaxai/minimax-m3" "$f" || { echo "FAIL: missing minimax-m3"; exit 1; }
grep -q "moonshotai/kimi-k2.6" "$f" || { echo "FAIL: missing kimi-k2.6"; exit 1; }
grep -q "nvidia/nemotron-3-ultra-550b-a55b" "$f" || { echo "FAIL: missing nemotron-3-ultra-550b"; exit 1; }
grep -q "mistralai/mistral-nemotron" "$f" || { echo "FAIL: missing mistral-nemotron"; exit 1; }
grep -q "poolside/laguna-s-2.1:free" "$f" || { echo "FAIL: missing laguna-s-2.1"; exit 1; }
grep -q "cohere/north-mini-code:free" "$f" || { echo "FAIL: missing north-mini-code"; exit 1; }
grep -q '"think": "nvidia,moonshotai/kimi-k2.6"' "$f" || { echo "FAIL: think not updated"; exit 1; }
grep -q '"longContext": "nvidia,minimaxai/minimax-m3"' "$f" || { echo "FAIL: longContext not updated"; exit 1; }
grep -q "qwen/qwen3-coder:free" "$f" && { echo "FAIL: dead openrouter entry still present"; exit 1; }
grep -q "qwen/qwen3-next-80b-a3b-instruct:free" "$f" && { echo "FAIL: dead openrouter entry still present"; exit 1; }

# Only the Go-template homeDir line is non-JSON; swap it for a literal and
# confirm the rest still parses.
rendered="$(sed 's#{{ \.chezmoi\.homeDir | replace "\\\\" "/" }}#/home/test#' "$f")"
echo "$rendered" | node -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))'

echo "PASS"
