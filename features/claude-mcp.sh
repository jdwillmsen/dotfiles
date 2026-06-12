#!/usr/bin/env bash
set -euo pipefail

DOTFILES="$1"
# shellcheck source=../lib/utils.sh
source "$DOTFILES/lib/utils.sh"

require node
require python3

MCP_FILE="$HOME/.claude/mcp.json"
mkdir -p "$HOME/.claude"

python3 - "$MCP_FILE" << 'PYEOF'
import json, sys, os

path = sys.argv[1]
existing = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            existing = json.load(f)
        except json.JSONDecodeError:
            pass

servers = existing.setdefault("mcpServers", {})

atlassian = {
    "command": "npx",
    "args": ["-y", "mcp-remote@latest", "https://mcp.atlassian.com/v1/mcp/authv2"]
}

if "Atlassian" not in servers:
    servers["Atlassian"] = atlassian
    with open(path, "w") as f:
        json.dump(existing, f, indent=2)
    print("[dotfiles]   ✓ Atlassian MCP server configured")
else:
    print("[dotfiles]   ↷ Atlassian MCP server already configured — skipping")
PYEOF

success "MCP servers ready"
info "  Atlassian/Rovo: authenticate on first use (OAuth browser flow)"
