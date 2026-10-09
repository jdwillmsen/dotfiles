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

# Mint a T3 Code pairing token for one device. Always --tailscale: without it
# the link points at the loopback origin, which no other device can open.
t3pair() {
    local label="${1:?Usage: t3pair <device-label> [ttl]}"
    npx t3@latest pair --tailscale --label "$label" --ttl "${2:-15m}"
}

# Surface the expiry timer's standing warning at shell start. The timer's own
# verdict is a failed user unit, which nothing shows unprompted — sessions
# lapsed with the warning sitting unread in the journal.
t3_expiry_notice() {
    local marker="${XDG_STATE_HOME:-$HOME/.local/state}/t3-session-expiry.warn"
    [ -s "$marker" ] || return 0
    {
        printf '⚠ '
        cat "$marker"
        echo "  Re-pair each device with: t3pair <label>"
        # A re-paired device keeps its old session until that lapses, so the
        # warning outlives the fix unless the old session is revoked.
        echo "  Then clear this: npx t3@latest auth session revoke <id> && t3-session-expiry"
    } >&2
}

# Nudge about the daily report's unacknowledged flags. Only on a terminal, so
# `bash -ic` pipelines see nothing extra. Plain tests come first so a shell
# with nothing pending, or with the flags already acknowledged (acked.json
# newer than flags.json), never starts Python; any failure stays silent.
__agent_state="${AGENT_METRICS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/agent-metrics}"
if [ -t 1 ] && [ -e "$__agent_state/flags.json" ] && [ ! "$__agent_state/acked.json" -nt "$__agent_state/flags.json" ] \
    && command -v agent-notify >/dev/null 2>&1; then
    agent-notify shell 2>/dev/null || true
fi
unset __agent_state
