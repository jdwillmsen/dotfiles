#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cfg="$here/home/dot_config/opencode/opencode.json"

fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "--- $2"; exit 1; }

[ -f "$cfg" ] || fail "opencode.json is missing"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on this host"; exit 0; }
jq -e . "$cfg" >/dev/null || fail "opencode.json is not valid JSON"

# OpenCode reads the file at startup and a provider missing either half is a
# runtime error at first use, not a parse error here.
while IFS=$'\t' read -r name npm base; do
    case "$npm" in ''|null) fail "provider $name declares no npm package" ;; esac
    case "$base" in
        http://*|https://*) ;;
        *) fail "provider $name has no usable baseURL" "$base" ;;
    esac
    # aipick's table addresses the chat endpoint; the AI SDK appends its own
    # path, so a baseURL carrying one produces /v1/chat/completions/chat/completions.
    case "$base" in
        */chat/completions*) fail "provider $name's baseURL includes the endpoint path" "$base" ;;
    esac
done < <(jq -r '.provider | to_entries[] | [.key, .value.npm, .value.options.baseURL] | @tsv' "$cfg")

# A key in the file would be a credential in git. `{env:VAR}` is OpenCode's own
# indirection; the LAN server wants no credential and is given a placeholder.
while IFS=$'\t' read -r name key; do
    case "$key" in
        '{env:'*'}'|dummy|null|'') ;;
        *) fail "provider $name has a literal apiKey in the repo" ;;
    esac
done < <(jq -r '.provider | to_entries[] | [.key, (.value.options.apiKey // "")] | @tsv' "$cfg")

# OpenCode asks for 32000 output tokens unless a model says otherwise, which on
# its own overruns the LAN server's 32768-token window and fails every call —
# the model was unusable until this limit was declared.
ctx="$(jq -r '.provider["gpu-stack"].models["qwen/qwen3-coder-30b-a3b"].limit.context // "unset"' "$cfg")"
outc="$(jq -r '.provider["gpu-stack"].models["qwen/qwen3-coder-30b-a3b"].limit.output // "unset"' "$cfg")"
[ "$ctx" != unset ] || fail "the gpu-stack model declares no context limit"
[ "$outc" != unset ] || fail "the gpu-stack model declares no output limit"
[ "$outc" -lt "$ctx" ] || fail "the declared output limit does not fit the context window" "$outc >= $ctx"

echo "PASS"
