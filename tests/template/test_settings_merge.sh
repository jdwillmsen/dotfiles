#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# Existing file has a user theme + a user-overridden model; script must keep both, add statusLine.
# The modify script contains no template directives, so running it directly with the
# current file content on stdin is byte-faithful to what chezmoi executes.
existing='{"theme":"light","model":"opus"}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.tmpl")"
echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["theme"]=="light", "user theme lost"; \
 assert d["model"]=="opus", "user model overwritten"; \
 assert d["statusLine"]["command"]=="claude-status", "statusLine missing"; print("PASS")'
