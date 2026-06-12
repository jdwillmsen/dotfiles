#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require git
require node
require python3

PLUGINS_DIR="$HOME/.claude/plugins"
mkdir -p "$PLUGINS_DIR"
mkdir -p "$HOME/.claude"

# ── Caveman ──────────────────────────────────────────────────────────────────
# Compresses AI output ~65-75% by enforcing terse prose via SessionStart /
# UserPromptSubmit hooks. Activate with /caveman, deactivate with /uncaveman.
CAVEMAN_DIR="$PLUGINS_DIR/caveman"
if [ -d "$CAVEMAN_DIR/.git" ]; then
    git -C "$CAVEMAN_DIR" pull --ff-only --quiet 2>/dev/null \
        || warn "Could not update caveman — using installed version"
    success "Caveman up to date"
else
    info "Installing caveman..."
    git clone --depth=1 --quiet \
        https://github.com/JuliusBrussee/caveman.git "$CAVEMAN_DIR" \
        || { warn "Could not clone caveman — skipping"; exit 0; }
    success "Caveman installed"
fi

# Wire caveman hooks into ~/.claude/settings.json
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

python3 - "$SETTINGS" "$CAVEMAN_DIR" << 'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
caveman_dir   = sys.argv[2]

with open(settings_path) as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError:
        cfg = {}

hooks = cfg.setdefault("hooks", {})

activate_cmd = "node $HOME/.claude/plugins/caveman/hooks/caveman-activate.js"
tracker_cmd  = "node $HOME/.claude/plugins/caveman/hooks/caveman-mode-tracker.js"

def already_has(section, cmd):
    return any(
        any(h.get("command") == cmd for h in entry.get("hooks", []))
        for entry in section
    )

changed = False

session_start = hooks.setdefault("SessionStart", [])
if not already_has(session_start, activate_cmd):
    session_start.append({"hooks": [{"type": "command", "command": activate_cmd}]})
    changed = True

user_prompt = hooks.setdefault("UserPromptSubmit", [])
if not already_has(user_prompt, tracker_cmd):
    user_prompt.append({"hooks": [{"type": "command", "command": tracker_cmd}]})
    changed = True

if changed:
    with open(settings_path, "w") as f:
        json.dump(cfg, f, indent=2)
    print("[dotfiles]   ✓ Caveman hooks wired into settings.json")
else:
    print("[dotfiles]   ↷ Caveman hooks already configured — skipping")
PYEOF
