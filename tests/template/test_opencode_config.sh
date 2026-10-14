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
# Every declared model needs both halves of its limit, and room for input.
[ -n "$(jq -r '.provider["gpu-stack"].models // {} | keys[]' "$cfg")" ] || fail "the gpu-stack provider declares no models"
while IFS=$'\t' read -r prov m ctx outc; do
    [ "$ctx" != unset ] || fail "$prov model $m declares no context limit"
    [ "$outc" != unset ] || fail "$prov model $m declares no output limit"
    [ "$outc" -lt "$ctx" ] || fail "$prov model $m's output limit does not fit its context window" "$outc >= $ctx"
done < <(jq -r '.provider | to_entries[] | .key as $p | .value.models // {} | to_entries[]
    | [$p, .key, (.value.limit.context // "unset"), (.value.limit.output // "unset")] | @tsv' "$cfg")

echo "PASS"
