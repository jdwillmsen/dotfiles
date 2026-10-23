#!/usr/bin/env bash
# PreToolUse hook: refuse Write/Edit/MultiEdit/Bash calls that modify the merge-captain's approval state
# (~/.local/state/merge-captain, ~/.local/state/agent-eval) or the deployed delivery policy
# (~/.config/agents/change-risk.toml, lanes.toml, merge-captain.toml).
#
# This stops accidents and a prompt-injected shortcut inside Claude Code. It is not a boundary against a process
# running as the same user: it reads command text, and shell can always spell a path in a way text matching misses.
# Receives the hook JSON on stdin; exit 2 with a message on stderr blocks the call.
#
# It runs before every tool call, so everything that mentions none of the protected names returns before any
# process is started: the input is read with a builtin and matched with shell patterns only.
set -u

IFS= read -r -d '' input || true

case $input in
    *merge-captain* | *agent-eval* | *change-risk* | *lanes.toml*) ;;
    *) exit 0 ;;
esac

UNESC=""
STR=""
REST=""
VALUES=()

# Undo the JSON string escapes that matter for reading a path or a command.
unescape() {
    local s=$1
    s=${s//\\\\/$'\x01'}
    s=${s//\\\"/\"}
    s=${s//\\n/$'\n'}
    s=${s//\\t/$'\t'}
    s=${s//\\r/$'\r'}
    s=${s//\\\//\/}
    s=${s//\\u003[eE]/>}
    s=${s//\\u003[cC]/<}
    s=${s//\\u0026/&}
    UNESC=${s//$'\x01'/\\}
}

# $1 starts just after an opening quote; sets STR to the raw string and REST to what follows it. Walks quote by
# quote instead of matching a pattern, and cuts by offset: prefix removal with a leading * is quadratic on the
# half-megabyte payload a large Write can carry.
read_string() {
    local text=$1 acc="" chunk bs
    while :; do
        if [[ $text != *\"* ]]; then
            STR=$acc$text
            REST=""
            return
        fi
        chunk=${text%%\"*}
        text=${text:$((${#chunk} + 1))}
        acc+=$chunk
        bs=${chunk##*[^\\]}
        if ((${#bs} % 2 == 1)); then
            acc+='"'
            continue
        fi
        STR=$acc
        REST=$text
        return
    done
}

# Every string value of a key anywhere in the input, unescaped, in VALUES.
extract() {
    local key=$1 rest=$input needle before
    VALUES=()
    needle=\"$key\"
    while [[ $rest == *"$needle"* ]]; do
        before=${rest%%"$needle"*}
        rest=${rest:$((${#before} + ${#needle}))}
        if [[ $rest =~ ^[[:space:]]*:[[:space:]]*\" ]]; then
            rest=${rest:${#BASH_REMATCH[0]}}
            read_string "$rest"
            unescape "$STR"
            VALUES+=("$UNESC")
            rest=$REST
        fi
    done
}

NORM=""
# Collapse . and .. in an absolute path without touching the file system.
lexnorm() {
    local -a parts out=()
    local seg IFS=/
    read -ra parts <<<"$1"
    for seg in "${parts[@]}"; do
        case $seg in
            '' | .) ;;
            ..)
                if ((${#out[@]})); then unset 'out[-1]'; fi
                ;;
            *) out+=("$seg") ;;
        esac
    done
    NORM="/${out[*]}"
}

W=""
# Quotes removed and the home and XDG shorthands a shell would expand.
expand_word() {
    local w=$1 state=${XDG_STATE_HOME:-$HOME/.local/state} config=${XDG_CONFIG_HOME:-$HOME/.config}
    w=${w//[\'\"\`]/}
    # shellcheck disable=SC2088  # matching a literal tilde word, not expanding one
    case $w in
        '~' | '~/'*) w=$HOME${w#\~} ;;
    esac
    w=${w//\$\{HOME\}/$HOME}
    w=${w//\$HOME/$HOME}
    w=${w//\$\{XDG_STATE_HOME\}/$state}
    w=${w//\$XDG_STATE_HOME/$state}
    w=${w//\$\{XDG_CONFIG_HOME\}/$config}
    w=${w//\$XDG_CONFIG_HOME/$config}
    W=$w
}

PDIRS=()
PFILES=()
# The protected locations, spelled as given and with symlinks resolved.
build_protected() {
    local base f var
    local -a dirs=() files=() resolved=()
    for base in "$HOME/.local/state" "${XDG_STATE_HOME:-}"; do
        if [[ -n $base ]]; then dirs+=("$base/merge-captain" "$base/agent-eval"); fi
    done
    for base in "$HOME/.config" "${XDG_CONFIG_HOME:-}"; do
        if [[ -n $base ]]; then
            for f in change-risk lanes merge-captain; do files+=("$base/agents/$f.toml"); done
        fi
    done
    for var in MERGE_CAPTAIN_STATE AGENT_EVAL_STATE; do
        if [[ -n ${!var:-} ]]; then dirs+=("${!var}"); fi
    done
    for var in MERGE_CAPTAIN_CONFIG AGENT_PACE_LANES AGENT_EVAL_LANES; do
        if [[ -n ${!var:-} ]]; then files+=("${!var}"); fi
    done
    PDIRS=("${dirs[@]}")
    PFILES=("${files[@]}")
    if command -v realpath >/dev/null 2>&1; then
        mapfile -t resolved < <(realpath -m -- "${dirs[@]}" 2>/dev/null)
        PDIRS+=("${resolved[@]}")
        mapfile -t resolved < <(realpath -m -- "${files[@]}" 2>/dev/null)
        PFILES+=("${resolved[@]}")
    fi
}

protected() {
    local p=$1 d
    for d in "${PDIRS[@]}"; do
        if [[ $p == "$d" || $p == "$d"/* ]]; then return 0; fi
    done
    for d in "${PFILES[@]}"; do
        if [[ $p == "$d" ]]; then return 0; fi
    done
    return 1
}

cwd=""
# True when the word names a protected location, relative words resolved against the call's directory.
hits() {
    local p rp
    expand_word "$1"
    p=$W
    if [[ -z $p ]]; then return 1; fi
    if [[ $p != /* ]]; then p="${cwd:-$PWD}/$p"; fi
    lexnorm "$p"
    if protected "$NORM"; then return 0; fi
    if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath -m -- "$NORM" 2>/dev/null) || return 1
        protected "$rp"
        return
    fi
    return 1
}

deny() {
    local what=${2:0:200}
    {
        echo "guard-delivery-state: blocked $1 on $what"
        echo "That path is the merge captain's approval state or a delivery policy file, so an agent may not"
        echo "write it. Use \`merge-captain pause|resume\` for the kill switch, or ask the owner to make the"
        echo "change from their own terminal."
    } >&2
    exit 2
}

# One simple command, already split from the rest of the line.
check_segment() {
    local -a w=() args=()
    local i n t cmd="" ci=0 target last="" take_next=0 in_place=0 dup=0
    read -ra w <<<"$1"
    n=${#w[@]}

    for ((i = 0; i < n; i++)); do
        t=${w[i]}
        if [[ $t =~ ^[0-9\&]*\>\>?\|?(.*)$ ]]; then
            target=${BASH_REMATCH[1]}
            dup=0
            if [[ $target == \&* ]]; then
                dup=1
                target=${target#\&}
            fi
            if [[ -z $target ]]; then target=${w[i + 1]:-}; fi
            # `2>&1` and `>&-` duplicate or close a descriptor; `>&file` opens a file.
            if ((dup)) && [[ $target =~ ^([0-9]+|-)$ ]]; then continue; fi
            if hits "$target"; then deny "a redirect" "$target"; fi
        fi
    done

    for ((i = 0; i < n; i++)); do
        t=${w[i]//[\'\"]/}
        if [[ $t =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi
        case $t in
            sudo | doas | env | command | exec | nohup | time | nice | ionice | -*) continue ;;
        esac
        cmd=${t##*/}
        ci=$i
        break
    done
    if [[ -z $cmd ]]; then return; fi

    for ((i = ci + 1; i < n; i++)); do
        t=${w[i]}
        case $t in
            of=*) if [[ $cmd == dd ]] && hits "${t#of=}"; then deny "dd" "${t#of=}"; fi ;;
            -i* | --in-place*) if [[ $cmd == sed ]]; then in_place=1; fi ;;
            -[a-zA-Z]*i*) if [[ $cmd == sed ]]; then in_place=1; fi ;;
        esac
        if ((take_next)); then
            take_next=0
            if hits "$t"; then deny "$cmd" "$t"; fi
            continue
        fi
        case $t in
            -t | --target-directory) if [[ $cmd == cp || $cmd == mv || $cmd == install || $cmd == ln ]]; then take_next=1; fi ;;
            --target-directory=*) if hits "${t#*=}"; then deny "$cmd" "${t#*=}"; fi ;;
            -*) ;;
            *) args+=("$t") ;;
        esac
    done
    if ((${#args[@]})); then last=${args[-1]}; fi

    case $cmd in
        tee | mv | rm | unlink | shred | truncate | touch | chmod | chown | chattr)
            for t in "${args[@]}"; do
                if hits "$t"; then deny "$cmd" "$t"; fi
            done
            ;;
        sed)
            if ((in_place)); then
                for t in "${args[@]}"; do
                    if hits "$t"; then deny "sed -i" "$t"; fi
                done
            fi
            ;;
        cp | install | ln | rsync)
            if [[ -n $last ]] && hits "$last"; then deny "$cmd" "$last"; fi
            ;;
    esac
}

check_command() {
    local cmd=$1 seg
    cmd=${cmd//>|/>}
    cmd=${cmd//&&/$'\n'}
    cmd=${cmd//||/$'\n'}
    cmd=${cmd//|/$'\n'}
    cmd=${cmd//;/$'\n'}
    cmd=${cmd//(/$'\n'}
    cmd=${cmd//)/$'\n'}
    while IFS= read -r seg; do
        if [[ -n $seg ]]; then check_segment "$seg"; fi
    done <<<"$cmd"
}

extract tool_name
tool=${VALUES[0]:-}
case $tool in
    Write | Edit | MultiEdit | Bash) ;;
    *) exit 0 ;;
esac

extract cwd
cwd=${VALUES[0]:-}
build_protected

if [[ $tool == Bash ]]; then
    extract command
    for value in "${VALUES[@]}"; do check_command "$value"; done
else
    extract file_path
    for value in "${VALUES[@]}"; do
        if hits "$value"; then deny "$tool" "$value"; fi
    done
fi
exit 0
