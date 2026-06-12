#!/usr/bin/env bash
# Feature: claude — global Claude Code settings, CLAUDE.md, commands, and hooks.
# Merges settings without overwriting user customizations. Each sub-step is
# independent; a failure in one does not abort the others.
DOTFILES="${1:?DOTFILES path required}"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require python3 "python3 not found — needed for settings.json merge"

FEATURE="$DOTFILES/claude"
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/hooks"

# ── settings.json — deep merge, existing user values win ──────────────────────
SETTINGS="$CLAUDE_DIR/settings.json"
[ ! -f "$SETTINGS" ] && echo '{}' > "$SETTINGS"

TMP="$(mktemp)"
if python3 - "$FEATURE/settings.json" "$SETTINGS" "$TMP" <<'PYEOF'; then
import json, sys

def deep_merge(base, override):
    """Merge override into base; existing keys in base win."""
    result = dict(base)
    for k, v in override.items():
        if k not in result:
            result[k] = v
        elif isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = deep_merge(result[k], v)
        # existing value wins for scalars and arrays
    return result

with open(sys.argv[1]) as f:
    new_settings = json.load(f)
with open(sys.argv[2]) as f:
    existing = json.load(f)

merged = deep_merge(new_settings, existing)

with open(sys.argv[3], "w") as f:
    json.dump(merged, f, indent=2)
    f.write("\n")
PYEOF
    mv "$TMP" "$SETTINGS"
    success "Merged settings into ~/.claude/settings.json"
else
    warn "settings.json merge failed — skipping"
    rm -f "$TMP"
fi

# ── CLAUDE.md — symlink global instructions ────────────────────────────────────
if [ -f "$FEATURE/CLAUDE.md" ]; then
    symlink "$FEATURE/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
fi

# ── commands — symlink each .md file into ~/.claude/commands/ ─────────────────
for cmd_file in "$FEATURE/commands/"*.md; do
    [ -f "$cmd_file" ] || continue
    name="$(basename "$cmd_file")"
    symlink "$cmd_file" "$CLAUDE_DIR/commands/$name"
done

# ── hooks — symlink each hook script into ~/.claude/hooks/ ────────────────────
for hook_file in "$FEATURE/hooks/"*.sh; do
    [ -f "$hook_file" ] || continue
    name="$(basename "$hook_file")"
    symlink "$hook_file" "$CLAUDE_DIR/hooks/$name"
    chmod +x "$CLAUDE_DIR/hooks/$name"
done
