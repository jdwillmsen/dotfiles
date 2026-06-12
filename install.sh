#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

info()    { echo "[dotfiles] $*"; }
success() { echo "[dotfiles] ✓ $*"; }
warn()    { echo "[dotfiles] ! $*"; }

symlink() {
    local src="$1"
    local dst="$2"

    # Back up existing non-symlink files
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        warn "Backing up existing $(basename "$dst") -> ${dst}.bak"
        mv "$dst" "${dst}.bak"
    fi

    ln -sf "$src" "$dst"
    success "Linked $dst"
}

info "Installing dotfiles from $DOTFILES"
echo

symlink "$DOTFILES/gitconfig"        "$HOME/.gitconfig"
symlink "$DOTFILES/gitignore_global" "$HOME/.gitignore_global"
symlink "$DOTFILES/zshrc"            "$HOME/.zshrc"
symlink "$DOTFILES/bashrc"           "$HOME/.bashrc"

# Claude Code status line — build Go binary
if command -v go &>/dev/null; then
    info "Building claude-status..."
    mkdir -p "$HOME/.local/bin"
    (cd "$DOTFILES/scripts/claude-status" && go build -o "$HOME/.local/bin/claude-status" .)
    success "Built ~/.local/bin/claude-status"

    mkdir -p "$HOME/.claude"
    CLAUDE_SETTINGS="$HOME/.claude/settings.json"
    [ ! -f "$CLAUDE_SETTINGS" ] && echo '{}' > "$CLAUDE_SETTINGS"
    if ! grep -q '"statusLine"' "$CLAUDE_SETTINGS"; then
        TMP="$(mktemp)"
        python3 - "$CLAUDE_SETTINGS" "$TMP" <<'PYEOF'
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
        mv "$TMP" "$CLAUDE_SETTINGS"
        success "Added statusLine to ~/.claude/settings.json"
    fi
else
    warn "Go not found — skipping claude-status build. Install Go and re-run install.sh."
fi

echo
info "Done. Restart your shell or run:"
info "  source ~/.zshrc   (zsh)"
info "  source ~/.bashrc  (bash)"
