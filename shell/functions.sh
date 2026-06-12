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
