#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# Existing file has a user theme + a user-overridden model; script must keep both, add statusLine.
# The modify script contains no template directives, so running it directly with the
# current file content on stdin is byte-faithful to what chezmoi executes.
existing='{"theme":"light","model":"opus"}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
# Windows ships a python3 Store-stub that fails on exec; probe for a real one.
PY=python3
"$PY" -c "" >/dev/null 2>&1 || PY=python
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["theme"]=="light", "user theme lost"; \
 assert d["model"]=="opus", "user model overwritten"; \
 assert d["statusLine"]["command"]=="claude-status", "statusLine missing"; \
 assert d["statusLine"]["refreshInterval"]==60, "refreshInterval default missing"; print("PASS")'

# A pre-existing statusLine dict must gain new default keys (refreshInterval)
# without losing user-set values (custom command).
existing='{"statusLine":{"type":"command","command":"my-status"}}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["statusLine"]["command"]=="my-status", "user statusLine command overwritten"; \
 assert d["statusLine"]["refreshInterval"]==60, "refreshInterval not merged into existing statusLine"; print("PASS")'
