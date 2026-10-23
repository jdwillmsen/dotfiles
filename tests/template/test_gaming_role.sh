#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"

fail() {
    echo "FAIL: $1"
    exit 1
}

# The gaming-rig bootstrap runs `chezmoi init --apply --no-tty --promptString
# machineRole=gaming --promptBool installDevTooling=false`. chez_init passes
# that same flag set, and stdin is closed here so a prompt the flags missed
# fails init instead of waiting on a terminal nobody is at.
cfg="$(chez_init gaming </dev/null)" || fail "gaming config must render with no TTY"
out="$(chez_tmpl "$cfg" '{{ .machineRole }}:{{ .isEphemeral }}:{{ .installDevTooling }}')"
[ "$out" = "gaming:false:false" ] || fail "gaming config data got '$out'"
personal="$(chez_init personal)"

dest="$(chez_sandbox)"
managed() { chezmoi managed --source "$CHEZ_SRC" --config "$1" --destination "$dest" "${@:2}"; }
ignored() { chezmoi ignored --source "$CHEZ_SRC" --config "$1" --destination "$dest"; }

# Target names, not source names: chezmoi matches ignore patterns against the
# script's target, so asserting on the rendered .chezmoiignore text alone would
# pass for an entry that ignores nothing.
skipped='
45-install-python-tools.sh
46-install-cloud-clis.sh
47-install-go.sh
49-install-dev-tools.sh
43-install-agent-clis.sh
20-build-claude-status.sh
21-build-opencode-status.sh
50-install-whisper-local.sh
10-install-tpm.sh
11-install-tmux-plugins.sh
51-enable-t3-session-expiry.sh
52-enable-t3-providers.sh
52-enable-agent-audit.sh
53-enable-agent-metrics.sh
54-enable-agent-report.sh
55-enable-agent-notify.sh
56-enable-agent-label.sh
57-enable-agent-propose.sh
58-enable-agent-delivery.sh
54-set-no-mistakes-agent.sh
55-set-no-mistakes-commit-trailers.sh
56-generate-claude-jira.sh
'
g_ignored="$(ignored "$cfg")"
p_ignored="$(ignored "$personal")"
g_scripts="$(managed "$cfg" --include=scripts)"
p_scripts="$(managed "$personal" --include=scripts)"
while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qxF -- "$s" <<<"$g_ignored" || fail "$s is not ignored for gaming"
    grep -qxF -- "$s" <<<"$g_scripts" && fail "$s still runs on a gaming machine"
    grep -qxF -- "$s" <<<"$p_ignored" && fail "$s must not be ignored for personal"
    grep -qxF -- "$s" <<<"$p_scripts" || fail "$s must still run on a personal machine"
done <<<"$skipped"

# The layer the role exists to keep: shell, git, prompt, Claude Code, and the
# scripts that install Claude's plugins, MCP servers and skills plus the small
# CLI set the shell config calls into.
g_files="$(managed "$cfg" --exclude=dirs)"
for t in .bashrc .zshrc .config/shell/aliases.sh .config/shell/exports.sh \
    .config/shell/functions.sh .gitconfig .gitignore_global .config/starship.toml \
    .claude/settings.json .claude/CLAUDE.md \
    30-install-claude-mcp.sh 31-install-claude-plugins.sh \
    32-install-claude-skills-dir.sh 33-install-agent-skills.sh \
    40-install-rtk.sh 42-install-cli-tools.sh 44-install-nerd-font.sh; do
    grep -qxF -- "$t" <<<"$g_files" || fail "$t must stay managed for gaming"
done

# settings.json must never point a gaming machine at claude-status, whose build
# that role skips — not even when a Go toolchain happens to be on PATH, which
# is what the stub stands in for. The personal render under the same stub is
# the control: without it, a stub that never resolved would pass this vacuously.
stub="$(mktemp -d "$CHEZ_TMP_ROOT/stub.XXXXXXXX")"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/go"
chmod 755 "$stub/go"
PY=python3
"$PY" -c "" >/dev/null 2>&1 || PY=python
settings() {
    local script
    script="$(mktemp "$CHEZ_TMP_ROOT/settings.XXXXXXXX")"
    chez_render "$1" "$here/home/private_dot_claude/modify_settings.json.json.tmpl" >"$script"
    printf '%s' "$2" | PATH="$stub:$PATH" bash "$script"
}
has_status() {
    "$PY" -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "statusLine" in d or "subagentStatusLine" in d else 1)'
}
settings "$personal" '' | has_status || fail "control: personal with Go must default a statusLine"
settings "$cfg" '' | has_status && fail "gaming settings.json must not default a claude-status statusLine"
# A ~/.claude restored from another machine carries the statusLine over; the
# merge would keep it, so gaming has to drop it — but only claude-status's.
carried='{"statusLine":{"type":"command","command":"claude-status","refreshInterval":10},"subagentStatusLine":{"type":"command","command":"claude-status -subagents"}}'
settings "$cfg" "$carried" | has_status && fail "gaming must strip a carried-over claude-status statusLine"
own='{"statusLine":{"type":"command","command":"my-status"}}'
settings "$cfg" "$own" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); \
 assert d["statusLine"]["command"]=="my-status", "user statusLine dropped on gaming"'

# A fresh gaming machine has no age identity. Rendering every file target
# against an identity path that does not exist proves nothing on that role
# decrypts. The personal render is the control that the probe reaches the
# encrypted target at all.
no_key() {
    local c
    c="$(mktemp -d "$CHEZ_TMP_ROOT/nokey.XXXXXXXX")/chezmoi.toml"
    sed 's#^\([[:space:]]*identity = \).*#\1"'"$(cygpath -m "$CHEZ_TMP_ROOT" 2>/dev/null || echo "$CHEZ_TMP_ROOT")"'/no-such-key.txt"#' "$1" >"$c"
    grep -q 'no-such-key.txt' "$c" || fail "could not repoint the age identity in $1"
    echo "$c"
}
render_all() {
    HOME="$dest" chezmoi archive --source "$CHEZ_SRC" --config "$1" --destination "$dest" \
        --exclude=scripts --output "$(mktemp "$CHEZ_TMP_ROOT/archive.XXXXXXXX")" 2>&1
}
err="$(render_all "$(no_key "$personal")")" && fail "control: personal render must need the age identity"
grep -q 'work-identity' <<<"$err" || fail "control: personal render failed for another reason: $err"
err="$(render_all "$(no_key "$cfg")")" || fail "gaming must render without an age identity: $err"

echo "PASS"
