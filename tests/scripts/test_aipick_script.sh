#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_claude-code-router/executable_aipick.sh"

[ -f "$script" ] || { echo "FAIL: aipick not tracked in source state"; exit 1; }
shellcheck -s bash "$script"
bash -n "$script"

grep -q "alias aipick=" "$here/home/dot_config/shell/aliases.sh" \
    || { echo "FAIL: no aipick alias"; exit 1; }
grep -q "alias ccrpick='bash ~/.claude-code-router/pick.sh'" "$here/home/dot_config/shell/aliases.sh" \
    || { echo "FAIL: ccrpick alias missing/changed"; exit 1; }

tmp="$(mktemp -d)"
trap "rm -rf '$tmp'" EXIT
mkdir -p "$tmp/.claude-code-router"

write_config() {  # $1 = api_key value in config.json
    cat >"$tmp/.claude-code-router/config.json" <<JSON
{
  "Providers": [
    {
      "name": "ollama",
      "api_base_url": "http://127.0.0.1:11434/v1/chat/completions",
      "api_key": "$1",
      "models": ["gpt-oss:20b"]
    }
  ]
}
JSON
}

# ── Task 1: tool menu — Claude Code delegates unchanged to pick.sh ──
cat >"$tmp/.claude-code-router/pick.sh" <<'SH'
#!/usr/bin/env bash
echo "PICK_SH_CALLED"
SH
chmod +x "$tmp/.claude-code-router/pick.sh"
write_config "ollama"

out="$(printf '1\n' | HOME="$tmp" bash "$script")"
echo "$out" | grep -q "PICK_SH_CALLED" || { echo "FAIL: tool=1 didn't delegate to pick.sh"; echo "$out"; exit 1; }

out="$(printf 'q\n' | HOME="$tmp" bash "$script")"
echo "$out" | grep -q "cancelled" || { echo "FAIL: q didn't cancel"; echo "$out"; exit 1; }

# ── Task 2: model picker + Aider dry-run — literal api_key resolved ──
out="$(printf '2\n1\n' | HOME="$tmp" AIPICK_DRY_RUN=1 bash "$script")"
echo "$out" | grep -q 'OPENAI_API_BASE="http://127.0.0.1:11434/v1"' \
    || { echo "FAIL: aider dry-run base not stripped correctly"; echo "$out"; exit 1; }
echo "$out" | grep -q -- '--model "openai/gpt-oss:20b"' \
    || { echo "FAIL: aider dry-run model not prefixed openai/"; echo "$out"; exit 1; }
echo "$out" | grep -q 'OPENAI_API_KEY=\*\*\*' \
    || { echo "FAIL: aider dry-run key not masked in output"; echo "$out"; exit 1; }
echo "$out" | grep -qi "no api key resolved" \
    && { echo "FAIL: literal api_key 'ollama' treated as unresolved"; echo "$out"; exit 1; }

# ── \$ENV_VAR-named key resolves from the environment (pick.sh's scheme) ──
write_config '$FAKE_PROVIDER_KEY'
out="$(printf '2\n1\n' | HOME="$tmp" FAKE_PROVIDER_KEY="secret123" AIPICK_DRY_RUN=1 bash "$script")"
echo "$out" | grep -qi "no api key resolved" \
    && { echo "FAIL: \$ENV_VAR-style api_key not resolved from environment"; echo "$out"; exit 1; }
write_config "ollama"

# ── Task 3: Qwen Code dry-run ──
out="$(printf '3\n1\n' | HOME="$tmp" AIPICK_DRY_RUN=1 bash "$script")"
echo "$out" | grep -q 'OPENAI_BASE_URL="http://127.0.0.1:11434/v1"' \
    || { echo "FAIL: qwen dry-run base wrong"; echo "$out"; exit 1; }
echo "$out" | grep -q 'OPENAI_MODEL="gpt-oss:20b"' \
    || { echo "FAIL: qwen dry-run model wrong"; echo "$out"; exit 1; }

# ── Task 4: auto-install — detection only, fake pipx logs instead of installing ──
# Real `aider`/`qwen` may already be on this machine's PATH, so build a
# minimal PATH (bash + node only, no aider/qwen dirs) instead of prepending
# to the inherited one — otherwise "not found" never triggers.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pipx" <<'SH'
#!/usr/bin/env bash
echo "PIPX_INSTALL_CALLED: $*"
exit 1
SH
chmod +x "$tmp/bin/pipx"
node_dir="$(dirname "$(command -v node)")"
bash_dir="$(dirname "$(command -v bash)")"
out="$(printf '2\n1\n' | HOME="$tmp" PATH="$tmp/bin:$bash_dir:$node_dir:/usr/bin:/bin" bash "$script" 2>&1 || true)"
echo "$out" | grep -q "PIPX_INSTALL_CALLED: install aider-chat" \
    || { echo "FAIL: pipx auto-install not triggered when aider missing"; echo "$out"; exit 1; }

# ── Task 5: input-validation edge cases ──
write_config "ollama"

set +e
out="$(printf '9\n' | HOME="$tmp" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 on out-of-range tool #"; echo "$out"; exit 1; }
echo "$out" | grep -q "not a valid choice" \
    || { echo "FAIL: no diagnostic for out-of-range tool #"; echo "$out"; exit 1; }

out="$(printf '2\nq\n' | HOME="$tmp" bash "$script")"
echo "$out" | grep -q "cancelled" \
    || { echo "FAIL: q at model picker didn't cancel"; echo "$out"; exit 1; }

set +e
out="$(printf '2\nabc\n' | HOME="$tmp" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 on non-numeric model #"; echo "$out"; exit 1; }
echo "$out" | grep -q "not a number" \
    || { echo "FAIL: no diagnostic for non-numeric model #"; echo "$out"; exit 1; }

set +e
out="$(printf '2\n99\n' | HOME="$tmp" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 on out-of-range model #"; echo "$out"; exit 1; }
echo "$out" | grep -q "out of range" \
    || { echo "FAIL: no diagnostic for out-of-range model #"; echo "$out"; exit 1; }

# empty model list — the provider exists but lists nothing to pick
cat >"$tmp/.claude-code-router/config.json" <<'JSON'
{ "Providers": [ { "name": "ollama", "api_base_url": "http://x", "api_key": "x", "models": [] } ] }
JSON
set +e
out="$(printf '2\n' | HOME="$tmp" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with an empty model list"; echo "$out"; exit 1; }
echo "$out" | grep -q "no models in config" \
    || { echo "FAIL: no diagnostic for empty model list"; echo "$out"; exit 1; }

# malformed config.json — fail loudly, not a silent empty picker
echo "not json" >"$tmp/.claude-code-router/config.json"
set +e
out="$(printf '2\n' | HOME="$tmp" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with malformed config.json"; echo "$out"; exit 1; }
write_config "ollama"

# missing config.json entirely
rm -f "$tmp/.claude-code-router/config.json"
set +e
out="$(printf '1\n' | HOME="$tmp" bash "$script" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] && { echo "FAIL: exited 0 with no config.json"; echo "$out"; exit 1; }
echo "$out" | grep -q "no CCR config" \
    || { echo "FAIL: no diagnostic for missing config.json"; echo "$out"; exit 1; }
write_config "ollama"

echo "PASS"
