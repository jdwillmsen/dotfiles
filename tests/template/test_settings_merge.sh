#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# Existing file has a user theme + a user-overridden model; script must keep both, add statusLine.
# The model here must differ from the DEFAULTS model, or the override assertion
# passes on the default value and proves nothing.
# The modify script contains no template directives, so running it directly with the
# current file content on stdin is byte-faithful to what chezmoi executes.
existing='{"theme":"light","model":"haiku"}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
# Windows ships a python3 Store-stub that fails on exec; probe for a real one.
PY=python3
"$PY" -c "" >/dev/null 2>&1 || PY=python
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["theme"]=="light", "user theme lost"; \
 assert d["model"]=="haiku", "user model overwritten"; \
 assert d["statusLine"]["command"]=="claude-status", "statusLine missing"; \
 assert d["statusLine"]["refreshInterval"]==10, "refreshInterval default missing"; \
 assert d["subagentStatusLine"]["command"]=="claude-status -subagents", "subagentStatusLine missing"; print("PASS")'

# A fresh install (no existing file) takes the dotfiles model default.
out="$(printf '' | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["model"]=="opus", "default model should be opus"; \
 assert d["env"]["MAX_MCP_OUTPUT_TOKENS"]=="50000", "MCP output budget default missing"; \
 assert d["env"]["BASH_DEFAULT_TIMEOUT_MS"]=="180000", "bash timeout default missing"; print("PASS")'

# env merges per-key: a user-set var survives while the other default fills in.
existing='{"env":{"MAX_MCP_OUTPUT_TOKENS":"9000"}}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["env"]["MAX_MCP_OUTPUT_TOKENS"]=="9000", "user env var overwritten"; \
 assert d["env"]["BASH_DEFAULT_TIMEOUT_MS"]=="180000", "sibling env default not merged in"; print("PASS")'

# A pre-existing statusLine dict must gain new default keys (refreshInterval)
# without losing user-set values (custom command).
existing='{"statusLine":{"type":"command","command":"my-status"}}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["statusLine"]["command"]=="my-status", "user statusLine command overwritten"; \
 assert d["statusLine"]["refreshInterval"]==10, "refreshInterval not merged into existing statusLine"; print("PASS")'

# enabledPlugins and skillOverrides keys the template lists override existing
# values (a `false` default must flip an on-disk `true`), while keys the
# template does not list survive untouched.
existing='{"enabledPlugins":{"ralph-loop@claude-plugins-official":true,"my-plugin@mine":true,"superpowers@claude-plugins-official":false},"skillOverrides":{"lavish":"on","my-skill":"name-only"}}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); p=d["enabledPlugins"]; s=d["skillOverrides"]; \
 assert p["ralph-loop@claude-plugins-official"] is False, "listed plugin not forced off"; \
 assert p["remember@claude-plugins-official"] is False, "listed plugin missing"; \
 assert p["my-plugin@mine"] is True, "unlisted plugin lost"; \
 assert p["superpowers@claude-plugins-official"] is False, "unlisted plugin toggle overwritten"; \
 assert s["my-skill"]=="name-only", "unlisted skillOverride lost"; \
 assert s["lavish"]=="off", "listed skillOverride not enforced"; print("PASS")'

# deniedMcpServers is a union: the template's connectors are added, a server
# the user denied locally survives, and re-running does not duplicate entries.
existing='{"deniedMcpServers":[{"serverName":"claude.ai Slack"},{"serverName":"claude.ai Gmail"}]}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
out="$(printf '%s' "$out" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); names=[e["serverName"] for e in d["deniedMcpServers"]]; \
 assert "claude.ai Slack" in names, "locally denied server dropped"; \
 assert "claude.ai Atlassian Rovo" in names, "template-denied server missing"; \
 assert names.count("claude.ai Gmail")==1, "deny entries duplicated"; \
 assert not any("Claude Docs" in n or "Google Drive" in n for n in names), "kept connector denied"; print("PASS")'

# REMOVED keys are deleted from the merged result even though the merge would
# otherwise keep them, while unknown user keys in the same section survive.
existing='{"skillOverrides":{"tdd":"off","zoom-out":"off","setup-matt-pocock-skills":"off","my-skill":"off"}}'
out="$(printf '%s' "$existing" | bash "$here/home/private_dot_claude/modify_settings.json.json.tmpl")"
echo "$out" | "$PY" -c 'import json,sys; s=json.load(sys.stdin)["skillOverrides"]; \
 assert not {"tdd","zoom-out","setup-matt-pocock-skills"} & set(s), "removed skillOverrides kept: %s" % s; \
 assert s["my-skill"]=="off", "unknown user skillOverride removed"; \
 assert s["lavish"]=="off", "enforced skillOverride lost"; print("PASS")'
