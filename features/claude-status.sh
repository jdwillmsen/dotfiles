#!/usr/bin/env bash
# Feature: claude-status — build the Go status line binary and wire it into
# ~/.claude/settings.json. Skips cleanly if Go or python3 are unavailable.
DOTFILES="${1:?DOTFILES path required}"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require go  "Go not found — install Go to enable claude-status"
require python3 "python3 not found — needed for settings.json injection"

mkdir -p "$HOME/.local/bin"
if (cd "$DOTFILES/scripts/claude-status" && go build -o "$HOME/.local/bin/claude-status" .); then
    success "Built ~/.local/bin/claude-status"
else
    warn "claude-status build failed — skipping"
    exit 0
fi

# Inject statusLine into ~/.claude/settings.json
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[ ! -f "$SETTINGS" ] && echo '{}' > "$SETTINGS"

if ! grep -q '"statusLine"' "$SETTINGS"; then
    TMP="$(mktemp)"
    python3 - "$SETTINGS" "$TMP" <<'PYEOF'
import json, sys
data = {}
try:
    with open(sys.argv[1]) as f:
        content = f.read()
    if content.strip():
        data = json.loads(content)
except Exception:
    pass
data["statusLine"] = {"type": "command", "command": "claude-status"}
with open(sys.argv[2], "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    mv "$TMP" "$SETTINGS"
    success "Added statusLine to ~/.claude/settings.json"
fi
