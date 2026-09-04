# shellcheck shell=bash
# Sourced by bashrc and zshrc; declares no shebang of its own.

# Editor
export EDITOR="nano"
export VISUAL="$EDITOR"

# Locale
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Go — GOPATH/bin always; /usr/local/go/bin only if a toolchain was installed
# there (the standard go.dev tarball location on Linux). Windows/macOS
# installers put `go` on PATH themselves, so this is a no-op there.
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"
if [ -d "/usr/local/go/bin" ]; then
    export PATH="/usr/local/go/bin:$PATH"
fi

# Python (pyenv) — activates only if pyenv is installed
if [ -d "$HOME/.pyenv" ]; then
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
fi

# Java (sdkman) — initialized in shell rc files (requires bash sourcing)

# Local user binaries
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# Kubernetes
export KUBECONFIG="$HOME/.kube/config"

# Docker BuildKit for better build output
export DOCKER_BUILDKIT=1
