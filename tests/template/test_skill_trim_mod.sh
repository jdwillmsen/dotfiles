#!/usr/bin/env bash
# The skill-trim mod is loaded through settings env and deployed under
# ~/.claude/mods; both halves must hold, or the mod silently never runs.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
src="$here/home/private_dot_claude/mods/skill-trim"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
PY=python3
"$PY" -c "" >/dev/null 2>&1 || PY=python

# A stale on-disk path is replaced, and sibling env vars survive.
existing='{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/stale/path","MY_VAR":"1"}}'
out="$(printf '%s' "$existing" | HOME="$tmp/home" bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | EXPECT="$tmp/home/.claude/mods/skill-trim" "$PY" -c 'import json,os,sys; e=json.load(sys.stdin)["env"]; \
 assert e["CLAUDE_CODE_PLUGIN_DIRS"]==os.environ["EXPECT"], "plugin dir not enforced: "+e["CLAUDE_CODE_PLUGIN_DIRS"]; \
 assert e["MY_VAR"]=="1", "sibling env var lost"; print("PASS")'

# chezmoi skips dot-prefixed source names, so the manifest lives under
# dot_claude-plugin; stage the deployed layout to check it as Claude Code sees it.
mod="$tmp/skill-trim"
cp -r "$src" "$mod"
mv "$mod/dot_claude-plugin" "$mod/.claude-plugin"
"$PY" -c 'import json,sys; m=json.load(open(sys.argv[1])); h=json.load(open(sys.argv[2])); \
 assert m["name"]=="skill-trim", "manifest name"; \
 assert h["modules"]==["./register.js"], "hooks module path"; print("PASS")' \
 "$mod/.claude-plugin/plugin.json" "$mod/hooks/hooks.json"

if command -v node >/dev/null 2>&1; then
    node --input-type=module -e '
import { pathToFileURL } from "node:url"
const { trimListing, calmContexts, CALM_BOOTSTRAP } = await import(pathToFileURL(process.argv[1]).href)
const listing = "intro\n\n- axi: kept.\n- mattpocock-skills:tdd: hidden.\nmore hidden\n- superpowers:brainstorming: kept."
const out = trimListing(listing)
if (out !== "intro\n\n- axi: kept.\n- superpowers:brainstorming: kept.") throw new Error("trim: " + JSON.stringify(out))
const ctx = calmContexts(["x You have superpowers. y", "other"])
if (ctx[0] !== CALM_BOOTSTRAP || ctx[1] !== "other") throw new Error("bootstrap not replaced")
console.log("PASS")
' "$mod/hooks/register.js"
else
    echo "SKIP: node not installed"
fi

# The mod's own suite needs the claude-code/testing kit, which only the CLI
# provides; CI runners have no claude binary.
if command -v claude >/dev/null 2>&1 && claude plugin test --help >/dev/null 2>&1; then
    (cd "$mod" && claude plugin test . >"$tmp/plugin-test.log" 2>&1) || { cat "$tmp/plugin-test.log"; echo "FAIL: claude plugin test"; exit 1; }
    tail -n 3 "$tmp/plugin-test.log"
    echo "PASS"
else
    echo "SKIP: claude plugin test unavailable"
fi
