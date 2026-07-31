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

# Discarding ccr's output is why the boot failure left no evidence at all.
grep -q 'ccr restart >/dev/null' "$script" && { echo "FAIL: ccr boot output must be captured, not discarded"; exit 1; }

tmp="$(mktemp -d)"
srv=""
# shellcheck disable=SC2064  # $tmp/$srv must expand now: the trap outlives their scope
trap "[ -n \"\$srv\" ] && kill \$srv 2>/dev/null; rm -rf '$tmp'" EXIT
bin="$tmp/bin"
mkdir -p "$bin" "$tmp/home/.claude-code-router/logs"
cp "$script" "$tmp/home/.claude-code-router/pick.sh"
printf '#!/usr/bin/env bash\necho "ccr $*"\n' >"$bin/ccr"
chmod +x "$bin/ccr"

write_config() {  # $1 = provider base url
    cat >"$tmp/home/.claude-code-router/config.json" <<JSON
{
  "HOST": "127.0.0.1",
  "PORT": 3456,
  "Providers": [
    { "name": "fake", "api_base_url": "$1", "api_key": "none", "models": ["m1"] }
  ],
  "Router": { "default": "fake,m1" }
}
JSON
}
run_picker() {  # stdin is a pipe here, so the picker's tty-only prompts stay out of the way
    HOME="$tmp/home" PATH="$bin:$PATH" CCRPICK_WAIT_TRIES=2 \
        bash "$tmp/home/.claude-code-router/pick.sh" <<<"1" 2>&1
}

# A provider whose /v1/models refuses the connection: port 9 (discard) is
# closed everywhere, standing in for the LAN inference box being off.
write_config "http://127.0.0.1:9/v1/chat/completions"
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/curl"          # router healthy
printf '#!/usr/bin/env bash\ntouch "%s/launched"\n' "$tmp" >"$bin/claude"
chmod +x "$bin/curl" "$bin/claude"
set +e
out="$(run_picker)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: picker exited 0 with the provider unreachable"; echo "$out"; exit 1; }
[ -e "$tmp/launched" ] && { echo "FAIL: picker launched against an unreachable provider"; exit 1; }
case "$out" in
    *"provider unreachable"*) ;;
    *) echo "FAIL: no diagnostic on unreachable-provider path:"; echo "$out"; exit 1 ;;
esac

# Everything past here needs a provider that answers /v1/models.
cat >"$tmp/srv.js" <<'JS'
const http = require("http"), fs = require("fs");
const s = http.createServer((req, res) => {
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ data: [{ id: "m1", context_length: 4096 }] }));
});
s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], String(s.address().port)));
JS
node "$tmp/srv.js" "$tmp/port" &
srv=$!
for _ in $(seq 1 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
[ -s "$tmp/port" ] || { echo "FAIL: stub provider never bound a port"; exit 1; }
write_config "http://127.0.0.1:$(cat "$tmp/port")/v1/chat/completions"

# Router never answers: fail loudly instead of handing Claude Code a dead base URL.
printf '#!/usr/bin/env bash\nexit 7\n' >"$bin/curl"
chmod +x "$bin/curl"
set +e
out="$(run_picker)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: picker exited 0 with the router down"; echo "$out"; exit 1; }
[ -e "$tmp/launched" ] && { echo "FAIL: picker launched Claude Code against a dead router"; exit 1; }
case "$out" in
    *"not launching Claude Code"*) ;;
    *) echo "FAIL: no diagnostic on router-down path:"; echo "$out"; exit 1 ;;
esac

# Healthy router and provider: launch, with the base URL taken from the config
# and the context window taken from the provider's own /v1/models.
printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/curl"
printf '#!/usr/bin/env bash\n{ echo "$ANTHROPIC_BASE_URL"; echo "$CCR_CTX_WINDOW"; } >"%s/env"\n' "$tmp" >"$bin/claude"
chmod +x "$bin/curl" "$bin/claude"
run_picker >/dev/null
[ "$(sed -n 1p "$tmp/env")" = "http://127.0.0.1:3456" ] \
    || { echo "FAIL: base URL not derived from config: $(sed -n 1p "$tmp/env")"; exit 1; }
[ "$(sed -n 2p "$tmp/env")" = "4096" ] \
    || { echo "FAIL: context window not read from provider: $(sed -n 2p "$tmp/env")"; exit 1; }

echo "PASS"
