# shellcheck shell=bash
# Sourced by bashrc and zshrc right after nvm, never before it: nvm keeps any
# nvm node already on PATH and only consults its default alias when there is
# none, so prepending here first would override an explicit `nvm alias default`.
#
# nvm's default is `lts/*`, and any `nvm ls-remote` or `nvm install` rewrites
# the lts aliases to the newest release upstream; until that exact version is
# installed the alias resolves to N/A, nvm silently falls back to "system", and
# every shell has no node at all. Claude Code then fails to spawn npx-launched
# MCP servers, since they inherit this PATH. So when nvm leaves no npx, use the
# newest installed version, chosen without nvm's alias resolution.
# Guarded on npx rather than node: Ubuntu's nodejs package ships /usr/bin/node
# without npm, so a node on PATH says nothing about whether npx resolves.
# find rather than a glob: an unmatched glob is a hard error under zsh.
if ! command -v npx >/dev/null 2>&1 && [ -d "$HOME/.nvm/versions/node" ]; then
    # Matching on the binary skips a version directory an interrupted install
    # left without one, rather than selecting it and ending up with no node.
    node_bin="$(find "$HOME/.nvm/versions/node" -mindepth 3 -maxdepth 3 -path '*/v*/bin/node' 2>/dev/null | sort -V | tail -n 1)"
    if [ -n "$node_bin" ]; then
        export PATH="${node_bin%/node}:$PATH"
    fi
    unset node_bin
fi
