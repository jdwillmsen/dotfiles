# shellcheck shell=bash
# Sourced by bashrc and zshrc; declares no shebang of its own.

# mkcd — make directory and cd into it
mkcd() {
    mkdir -p "$1" && cd "$1" || return 1
}

# extract — universal archive unpacker
extract() {
    if [ ! -f "$1" ]; then
        echo "extract: '$1' is not a file"
        return 1
    fi
    case "$1" in
        *.tar.bz2)  tar xjf "$1"    ;;
        *.tar.gz)   tar xzf "$1"    ;;
        *.tar.xz)   tar xJf "$1"    ;;
        *.tar)      tar xf  "$1"    ;;
        *.bz2)      bunzip2 "$1"    ;;
        *.gz)       gunzip  "$1"    ;;
        *.zip)      unzip   "$1"    ;;
        *.7z)       7z x    "$1"    ;;
        *)          echo "extract: unknown format '$1'" ;;
    esac
}

# port — show what process is listening on a port
port() {
    ss -tulanp | grep ":$1"
}

# kubectl exec shorthand — drop into a pod shell
ksh() {
    local pod="${1:?Usage: ksh <pod> [namespace] [shell]}"
    local ns="${2:-default}"
    local sh="${3:-sh}"
    kubectl exec -it "$pod" -n "$ns" -- "$sh"
}

# git clone and cd into the cloned directory
gclone() {
    git clone "$1" && cd "$(basename "$1" .git)" || return 1
}

# Show PATH entries one per line (more readable than the alias)
pathlist() {
    echo "$PATH" | tr ':' '\n' | nl
}

# Quick HTTP server in current directory
serve() {
    local port="${1:-8000}"
    python3 -m http.server "$port"
}

# Launch Claude Code named after the current worktree's Jira ticket, so the
# /resume picker and tab title are scannable. Deliberately NOT named `claude`:
# shadowing the real binary breaks `claude agents --json` and recurses.
cj() {
    local cfg="$HOME/.config/claude-jira.json" gitdir key branch projects
    gitdir=$(git rev-parse --git-dir 2>/dev/null) || { command claude "$@"; return; }

    if [ -r "$gitdir/claude-jira-ticket" ]; then
        key=$(head -c 256 "$gitdir/claude-jira-ticket" | head -n 1 | tr -d '[:space:]')
    fi

    if [ -z "$key" ] && [ -r "$cfg" ]; then
        projects=$(tr -d ' \n' < "$cfg" |
            sed -n 's/.*"projects":\[\([^]]*\)\].*/\1/p' | tr -d '"' | tr ',' '|')
        if [ -n "$projects" ]; then
            # --show-current, not rev-parse: it still reports the branch on an
            # unborn HEAD, i.e. a fresh worktree before its first commit.
            branch=$(git branch --show-current 2>/dev/null)
            key=$(printf '%s' "$branch" | grep -oiE "(^|[/_-])($projects)-[0-9]+" |
                head -n 1 | sed -E 's@^[/_-]@@' | tr '[:lower:]' '[:upper:]')
        fi
    fi

    case "$key" in
        [A-Z][A-Z0-9]*-[1-9]*) command claude -n "$key" "$@" ;;
        *) command claude "$@" ;;
    esac
}
