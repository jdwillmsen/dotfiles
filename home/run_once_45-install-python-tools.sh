#!/usr/bin/env bash
set -euo pipefail
# uv covers interpreter downloads, venvs and dependency resolution, so the
# system python is left untouched. pipx stays alongside it for tools that
# publish only as pip-installable applications.
BIN="$HOME/.local/bin"
# pipx installs through uv, which this script may have just placed in $BIN — a
# directory the apply shell inherited its PATH from before it existed.
export PATH="$BIN:$PATH"

install_uv() {
    if command -v uv &>/dev/null; then
        echo "uv already installed — skipping"; return 0
    fi
    if command -v brew &>/dev/null; then
        brew install uv || echo "uv brew install failed"
    elif command -v winget &>/dev/null; then
        if winget list --id astral-sh.uv --exact &>/dev/null; then
            echo "uv already installed — restart your shell to pick it up on PATH"
        else
            winget install --id astral-sh.uv --silent \
                --accept-package-agreements --accept-source-agreements ||
                echo "uv winget install failed"
        fi
    elif command -v scoop &>/dev/null; then
        scoop install uv || echo "uv scoop install failed"
    elif command -v curl &>/dev/null; then
        mkdir -p "$BIN"
        curl -LsSf https://astral.sh/uv/install.sh |
            env UV_INSTALL_DIR="$BIN" INSTALLER_NO_MODIFY_PATH=1 sh ||
            echo "uv install script failed"
    else
        echo "uv requires brew, winget, scoop, or curl — install one first"
    fi
}

install_pipx() {
    if command -v pipx &>/dev/null; then
        echo "pipx already installed — skipping"; return 0
    fi
    if command -v brew &>/dev/null; then
        brew install pipx || echo "pipx brew install failed"
    elif command -v scoop &>/dev/null; then
        scoop install pipx || echo "pipx scoop install failed"
    elif command -v uv &>/dev/null; then
        # Recent distros mark the system interpreter externally-managed, so
        # `pip install --user pipx` is refused outright; uv builds pipx its own
        # environment and links the entry point without touching system python.
        uv tool install pipx || echo "pipx uv install failed"
    else
        echo "pipx needs uv, brew, or scoop — none present"
    fi
}

install_uv
install_pipx

echo "Python tool provisioning complete"
