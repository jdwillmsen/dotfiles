# Dotfiles root — used by shell files to source sibling scripts
export DOTFILES="$HOME/dotfiles"

# Editor
export EDITOR="nano"
export VISUAL="$EDITOR"

# Locale
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Go
export GOPATH="$HOME/go"
export PATH="$GOPATH/bin:$PATH"

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
