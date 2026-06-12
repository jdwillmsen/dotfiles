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
        # Inject statusLine using Go's built-in json approach via a temp file
        TMP="$(mktemp)"
        go run - "$CLAUDE_SETTINGS" "$TMP" <<'GOEOF'
package main
import (
    "encoding/json"
    "os"
)
func main() {
    src, dst := os.Args[1], os.Args[2]
    data := map[string]any{}
    if b, _ := os.ReadFile(src); len(b) > 2 {
        json.Unmarshal(b, &data)
    }
    data["statusLine"] = map[string]any{"type": "command", "command": "claude-status"}
    out, _ := json.MarshalIndent(data, "", "  ")
    os.WriteFile(dst, append(out, '\n'), 0644)
}
GOEOF
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
