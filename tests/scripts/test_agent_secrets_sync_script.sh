#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_local/bin/executable_agent-secrets-sync"
[ -x "$script" ] || { echo "FAIL: agent-secrets-sync missing or not executable"; exit 1; }
shellcheck -s bash "$script"

tmp="$(mktemp -d)"
# shellcheck disable=SC2064  # $tmp must expand now: the trap outlives its scope
trap "rm -rf '$tmp'" EXIT
mkdir -p "$tmp/bin"

# No Vault token, so the cluster fallback is the path under test.
cat >"$tmp/bin/vault" <<'SH'
#!/usr/bin/env bash
exit 2
SH
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s' "c2stdGVzdC12YWx1ZQ=="
SH
chmod +x "$tmp/bin/vault" "$tmp/bin/kubectl"

out_file="$tmp/agent-secrets.env"
out="$(PATH="$tmp/bin:$PATH" AGENT_SECRETS_FILE="$out_file" bash "$script")"
grep -qx 'PLATFORMCTL_JDWLABS_NVIDIA_API_KEY=sk-test-value' "$out_file" || { echo "FAIL: key not written"; cat "$out_file"; exit 1; }
[ "$(stat -c '%a' "$out_file")" = 600 ] || { echo "FAIL: file mode is not 600"; exit 1; }
echo "$out" | grep -q 'sk-test-value' && { echo "FAIL: secret value printed to stdout"; exit 1; }
echo "$out" | grep -q 'from kubectl' || { echo "FAIL: source not reported"; echo "$out"; exit 1; }

check="$(AGENT_SECRETS_FILE="$out_file" bash "$script" --check)"
echo "$check" | grep -q 'PLATFORMCTL_JDWLABS_NVIDIA_API_KEY: present' || { echo "FAIL: --check missed the key"; echo "$check"; exit 1; }

# A failed fetch must leave the previous file intact rather than truncating a
# working key to nothing.
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
set +e
out="$(PATH="$tmp/bin:$PATH" AGENT_SECRETS_FILE="$out_file" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: exited 0 with no source available"; exit 1; }
grep -qx 'PLATFORMCTL_JDWLABS_NVIDIA_API_KEY=sk-test-value' "$out_file" || { echo "FAIL: failed sync clobbered the existing file"; exit 1; }
[ -z "$(find "$tmp" -name 'agent-secrets.env.*')" ] || { echo "FAIL: temp file left behind"; exit 1; }
echo "$out" | grep -q '✖ PLATFORMCTL_JDWLABS_NVIDIA_API_KEY: not found' || { echo "FAIL: no diagnostic when every source fails"; echo "$out"; exit 1; }

# The file is sourced by every shell, so a value that is not a plain token
# must be refused, never written for the shell to execute.
cat >"$tmp/bin/kubectl" <<'SH'
#!/usr/bin/env bash
printf '%s' "YTtyZWJvb3Q="
SH
set +e
out="$(PATH="$tmp/bin:$PATH" AGENT_SECRETS_FILE="$out_file" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: accepted a value with shell metacharacters"; exit 1; }
echo "$out" | grep -q 'unsafe to source' || { echo "FAIL: no diagnostic for an unsafe value"; echo "$out"; exit 1; }
echo "$out" | grep -q 'reboot' && { echo "FAIL: unsafe value echoed"; exit 1; }
grep -qx 'PLATFORMCTL_JDWLABS_NVIDIA_API_KEY=sk-test-value' "$out_file" || { echo "FAIL: unsafe value replaced the existing file"; exit 1; }

# Vault wins when a token is present, and only for the exact kv path and field.
cat >"$tmp/bin/vault" <<'SH'
#!/usr/bin/env bash
[ "$*" = "token lookup" ] && exit 0
[ "$*" = "kv get -field=nvidia_api_key kv/litellm" ] && { printf '%s' "sk-from-vault"; exit 0; }
exit 2
SH
out="$(PATH="$tmp/bin:$PATH" AGENT_SECRETS_FILE="$out_file" bash "$script")"
echo "$out" | grep -q 'from vault' || { echo "FAIL: Vault not preferred"; echo "$out"; exit 1; }
grep -qx 'PLATFORMCTL_JDWLABS_NVIDIA_API_KEY=sk-from-vault' "$out_file" || { echo "FAIL: Vault value not written"; exit 1; }

echo "PASS"
