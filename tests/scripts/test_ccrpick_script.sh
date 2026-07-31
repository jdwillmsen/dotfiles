#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_claude-code-router/executable_pick.sh"

[ -f "$script" ] || { echo "FAIL: picker not tracked in source state"; exit 1; }
shellcheck -s bash "$script"
bash -n "$script"

grep -q "alias ccrpick=" "$here/home/dot_config/shell/aliases.sh" \
    || { echo "FAIL: no ccrpick alias"; exit 1; }

# `ccr start` runs the server in the foreground and returns instantly when a PID
# file exists, so as a recovery step it either hangs the picker or silently does
# nothing. `ccr restart` is the only command that daemonises.
code="$(grep -vE '^[[:space:]]*#' "$script")"
grep -qE '(^|[^-])ccr start' <<<"$code" && { echo "FAIL: picker must not boot via 'ccr start'"; exit 1; }
grep -q 'ccr restart' "$script" || { echo "FAIL: picker must boot the router with 'ccr restart'"; exit 1; }

# ccr's liveness check reads the PID file and never touches the socket, so a PID
# left by a service that died before listening wedges every later boot.
grep -q 'rm -f "\$ccrdir/.claude-code-router.pid"' "$script" \
    || { echo "FAIL: picker must clear a stale PID file when the port is silent"; exit 1; }

# Discarding ccr's output is why the last failure left no evidence at all.
grep -q 'ccr restart >/dev/null' "$script" && { echo "FAIL: ccr boot output must be captured, not discarded"; exit 1; }

# Behavioural: with the router never answering, the picker must fail loudly
# instead of handing Claude Code a dead base URL.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin" "$tmp/home/.claude-code-router/logs"
cat >"$tmp/home/.claude-code-router/config.json" <<'JSON'
{
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "Providers": [
    { "name": "fake", "api_base_url": "http://127.0.0.1:9/v1/chat/completions",
      "api_key": "none", "models": ["m1"] }
  ],
  "Router": { "default": "fake,m1" }
}
JSON
cp "$script" "$tmp/home/.claude-code-router/pick.sh"
printf '#!/usr/bin/env bash\necho "ccr $*"\n' >"$bin/ccr"
printf '#!/usr/bin/env bash\ntouch "%s/launched"\n' "$tmp" >"$bin/claude"
# Router that never answers: every probe fails, like a service that died at boot.
printf '#!/usr/bin/env bash\nexit 7\n' >"$bin/curl"
chmod +x "$bin/ccr" "$bin/claude" "$bin/curl"

set +e
out="$(HOME="$tmp/home" PATH="$bin:$PATH" CCRPICK_WAIT_TRIES=2 \
    bash "$tmp/home/.claude-code-router/pick.sh" <<<"1" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: picker exited 0 with the router down"; echo "$out"; exit 1; }
[ -e "$tmp/launched" ] && { echo "FAIL: picker launched Claude Code against a dead router"; exit 1; }
case "$out" in
    *"not launching Claude Code"*) ;;
    *) echo "FAIL: no diagnostic on router-down path:"; echo "$out"; exit 1 ;;
esac

# Healthy router: the picker launches, and points Claude Code at the configured
# host/port rather than a hardcoded one.
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/curl"
printf '#!/usr/bin/env bash\necho "$ANTHROPIC_BASE_URL" >"%s/base_url"\n' "$tmp" >"$bin/claude"
chmod +x "$bin/curl" "$bin/claude"
HOME="$tmp/home" PATH="$bin:$PATH" CCRPICK_WAIT_TRIES=2 \
    bash "$tmp/home/.claude-code-router/pick.sh" <<<"1" >/dev/null 2>&1
[ "$(cat "$tmp/base_url")" = "http://127.0.0.1:3456" ] \
    || { echo "FAIL: base URL not derived from config: $(cat "$tmp/base_url")"; exit 1; }

echo "PASS"
