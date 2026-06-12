#!/usr/bin/env bash
# Feature: codex — global Codex instructions.
set -euo pipefail

DOTFILES="${1:?DOTFILES path required}"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

FEATURE="$DOTFILES/codex"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CODEX_DIR"

if [ -f "$FEATURE/AGENTS.md" ]; then
    symlink "$FEATURE/AGENTS.md" "$CODEX_DIR/AGENTS.md"
fi

if ! command -v python3 &>/dev/null; then
    skip "python3 not found — skipping Codex status line configuration"
    exit 0
fi

CONFIG="$CODEX_DIR/config.toml"
[ ! -f "$CONFIG" ] && touch "$CONFIG"

python3 - "$CONFIG" <<'PYEOF'
from pathlib import Path
import re
import sys

config = Path(sys.argv[1])
text = config.read_text()
status_line = 'status_line = ["model-with-reasoning", "context-remaining", "git-branch", "current-dir"]'

section_re = re.compile(r'(?m)^\[tui\]\s*$')
match = section_re.search(text)

if not match:
    text = text.rstrip()
    if text:
        text += "\n\n"
    text += f"[tui]\n{status_line}\n"
else:
    next_section = re.search(r'(?m)^\[[^\]]+\]\s*$', text[match.end():])
    section_end = match.end() + next_section.start() if next_section else len(text)
    section = text[match.end():section_end]
    status_re = re.compile(r'(?m)^status_line\s*=.*$')
    if status_re.search(section):
        section = status_re.sub(status_line, section, count=1)
    else:
        if section and not section.endswith("\n"):
            section += "\n"
        section += status_line + "\n"
    text = text[:match.end()] + section + text[section_end:]

config.write_text(text)
PYEOF
success "Configured Codex status line"
