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
