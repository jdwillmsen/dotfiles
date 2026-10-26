#!/usr/bin/env bash
# PreToolUse hook: refuse Write/Edit/MultiEdit/Bash calls that modify the merge-captain's approval state
# (~/.local/state/merge-captain, ~/.local/state/agent-eval) or the deployed delivery policy
# (~/.config/agents/change-risk.toml, lanes.toml, merge-captain.toml). It also refuses Read, Write, Edit, Grep and
# Glob on the merge-captain's token directory (~/.config/merge-captain) and any Bash command that mentions it,
# except `merge-captain auth`, `auth-app` and `status`, which never print a token or key. The directory also holds
# the approver App's id file and private key (approver.json, approver.key), so they are covered the same way. A
# recursive search whose root is the token directory or any directory above it (Bash, Grep or Glob) is refused too,
# since it reads the tokens without naming them.
#
# This stops accidents and a prompt-injected shortcut inside Claude Code. It is not a boundary against a process
# running as the same user: it reads command text, and shell can always spell a path in a way text matching misses.
# Receives the hook JSON on stdin; exit 2 with a message on stderr blocks the call.
#
# It runs before every tool call, so a call that cannot reach a protected path returns without starting a process:
# the input is read with a builtin and matched with shell patterns only. A file tool whose path crosses a symlink
# (or a `..` that a link would change the meaning of) costs one `realpath`, and so does any Grep or Glob.
set -u
# An & in a replacement string must stay a literal ampersand.
shopt -u patsub_replacement 2>/dev/null || true

IFS= read -r -d '' input || true

# True when the text names a protected file, or a directory an environment variable moved one to.
mentions_protected() {
    local v
    case $1 in
        *merge-captain* | *agent-eval* | *change-risk* | *lanes.toml* | *MERGE_CAPTAIN_*) return 0 ;;
    esac
    for v in MERGE_CAPTAIN_TOKENS MERGE_CAPTAIN_STATE AGENT_EVAL_STATE MERGE_CAPTAIN_CONFIG AGENT_PACE_LANES \
        AGENT_EVAL_LANES; do
        if [[ -n ${!v:-} && $1 == *"${!v}"* ]]; then return 0; fi
    done
    return 1
}

# Set when the raw input names nothing protected; whether the call can still reach something is decided below.
FAST=0
if ! mentions_protected "$input"; then
    # A search rooted at ~/.config walks into the token directory without naming it.
    if [[ -n ${XDG_CONFIG_HOME:-} && $input == *"\"$XDG_CONFIG_HOME\""* ]]; then
        :
    elif [[ $input != *'.config"'* && $input != *'.config/"'* ]]; then
        FAST=1
    fi
fi

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
TDIRS=()
TANCESTORS=()
ANC_ALL=()
TPATS=()
RCWD=""
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
    build_token_protected
}

# The directory the captain keeps its per-owner tokens in, spelled as given and with symlinks resolved, and every
# directory above it: a recursive search rooted at any of them walks into the tokens.
build_token_protected() {
    local base d
    local -a dirs=() resolved=()
    for base in "$HOME/.config" "${XDG_CONFIG_HOME:-}"; do
        if [[ -n $base ]]; then dirs+=("$base/merge-captain"); fi
    done
    if [[ -n ${MERGE_CAPTAIN_TOKENS:-} ]]; then dirs+=("$MERGE_CAPTAIN_TOKENS"); fi
    TDIRS=("${dirs[@]}")
    if command -v realpath >/dev/null 2>&1; then
        mapfile -t resolved < <(realpath -m -- "${dirs[@]}" 2>/dev/null)
        TDIRS+=("${resolved[@]}")
    fi
    TANCESTORS=(/)
    for d in "${TDIRS[@]}"; do
        while [[ $d == /*/* ]]; do
            d=${d%/*}
            TANCESTORS+=("$d")
        done
    done
    ANC_ALL=("${TANCESTORS[@]}" "${TDIRS[@]}")
    # Text a command can carry the directory in, unexpanded and expanded.
    TPATS=(".config/merge-captain" "merge-captain/tokens" "XDG_CONFIG_HOME}/merge-captain"
        "XDG_CONFIG_HOME/merge-captain" "${TDIRS[@]}")
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

# True when the path is inside the token directory; $2=1 also counts the directories that contain it.
token_protected() {
    local p=$1 d
    for d in "${TDIRS[@]}"; do
        if [[ $p == "$d" || $p == "$d"/* ]]; then return 0; fi
    done
    if [[ ${2:-0} == 1 ]]; then
        for d in "${TANCESTORS[@]}"; do
            if [[ $p == "$d" ]]; then return 0; fi
        done
    fi
    return 1
}

cwd=""
# True when the word names a protected location, relative words resolved against the call's directory. The link
# resolution runs on the path as written, not on the `..`-collapsed one: a link followed by `..` leaves its target.
hits() {
    local p rp
    expand_word "$1"
    p=$W
    if [[ -z $p ]]; then return 1; fi
    if [[ $p != /* ]]; then p="${cwd:-$PWD}/$p"; fi
    lexnorm "$p"
    if protected "$NORM"; then return 0; fi
    if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath -m -- "$p" 2>/dev/null) || return 1
        protected "$rp"
        return
    fi
    return 1
}

token_hits() {
    local p rp
    expand_word "$1"
    p=$W
    if [[ -z $p ]]; then return 1; fi
    if [[ $p != /* ]]; then p="${cwd:-$PWD}/$p"; fi
    lexnorm "$p"
    if token_protected "$NORM" "${2:-0}"; then return 0; fi
    if command -v realpath >/dev/null 2>&1; then
        rp=$(realpath -m -- "$p" 2>/dev/null) || return 1
        token_protected "$rp" "${2:-0}"
        return
    fi
    return 1
}

# True when the word, resolved against $cwd, is the token directory, inside it, or a directory above it. A word with
# a wildcard counts when its first wildcard component could match the next directory down the way to the tokens,
# the way the shell would: a leading `*` does not match a name that starts with a dot.
root_word_hits() {
    local p pre dirpart dir comp a parent name rp
    expand_word "$1"
    p=$W
    if [[ -z $p ]]; then return 1; fi
    if [[ $p != *[\*\?\[]* ]]; then
        token_hits "$p" 1
        return
    fi
    pre=${p%%[\*\?\[]*}
    if [[ $pre == */* ]]; then
        dirpart=${pre%"${pre##*/}"}
        dir=${dirpart%/}
        if [[ -z $dir ]]; then dir=/; fi
    else
        dirpart=""
        dir=.
    fi
    comp=${p:${#dirpart}}
    comp=${comp%%/*}
    if token_hits "$dir" 0; then return 0; fi
    if [[ $dir != /* ]]; then dir="${cwd:-$PWD}/$dir"; fi
    rp=""
    if command -v realpath >/dev/null 2>&1; then rp=$(realpath -m -- "$dir" 2>/dev/null) || rp=""; fi
    lexnorm "$dir"
    dir=$NORM
    for a in "${ANC_ALL[@]}"; do
        if [[ $a == / ]]; then continue; fi
        parent=${a%/*}
        if [[ -z $parent ]]; then parent=/; fi
        if [[ $parent != "$dir" && $parent != "$rp" ]]; then continue; fi
        name=${a##*/}
        if [[ $name == .* && $comp != .* ]]; then continue; fi
        # shellcheck disable=SC2053  # the component is a glob pattern on purpose
        if [[ $name == $comp ]]; then return 0; fi
    done
    return 1
}

# root_word_hits from the directory the call started in and from the one a `cd` earlier in the line moved to.
search_hit() {
    local saved=$cwd
    if root_word_hits "$1"; then return 0; fi
    if [[ -n $RCWD && $RCWD != "$saved" ]]; then
        cwd=$RCWD
        if root_word_hits "$1"; then
            cwd=$saved
            return 0
        fi
        cwd=$saved
    fi
    return 1
}

# True when a Grep or Glob starting at $1 is confined, by its glob or pattern $2, to a directory that neither is nor
# contains the token directory. A leading wildcard confines nothing.
search_scoped() {
    local root=$1 s=$2 pre dir
    expand_word "$root"
    root=$W
    if [[ $root != /* ]]; then root="${cwd:-$PWD}/$root"; fi
    expand_word "$s"
    s=$W
    if [[ -z $s ]]; then return 1; fi
    if [[ $s == *[\*\?\[\{]* ]]; then
        pre=${s%%[\*\?\[\{]*}
        if [[ $pre != */* ]]; then return 1; fi
        dir=${pre%/*}
        if [[ -z $dir ]]; then dir=/; fi
    else
        dir=$s
    fi
    if [[ $dir != /* ]]; then dir="$root/$dir"; fi
    if token_hits "$dir" 1; then return 1; fi
    return 0
}

SFLAGS=()
SARGS=()
SWORDS=()
STDIR=0
# True when a flag of the current command carries one of the letters ($1), is one of the long names ($2), or both.
has_opt() {
    local f k
    for f in "${SFLAGS[@]}"; do
        case $f in
            --*)
                if [[ " $2 " == *" ${f%%=*} "* ]]; then return 0; fi
                ;;
            -?*)
                for ((k = 0; k < ${#1}; k++)); do
                    if [[ $f == *"${1:k:1}"* ]]; then return 0; fi
                done
                ;;
        esac
    done
    return 1
}

# A command that walks a whole tree, aimed at the token directory or anything above it, reads the tokens however
# little it names them. Without a path it searches the directory it runs in.
check_search() {
    local cmd=$1 recursive=0 pattern=0 t i
    local -a targets=()
    case $cmd in
        grep | egrep | fgrep | zgrep | zegrep | zfgrep)
            pattern=1
            if has_opt rR "--recursive --dereference-recursive"; then recursive=1; fi
            ;;
        rg | ag | ack | fd)
            pattern=1
            recursive=1
            ;;
        find | du | tree) recursive=1 ;;
        ls) if has_opt R "--recursive"; then recursive=1; fi ;;
        cp) if has_opt rRa "--recursive --archive"; then recursive=1; fi ;;
        rsync) if has_opt ra "--recursive --archive"; then recursive=1; fi ;;
        zip) if has_opt r "--recurse-paths"; then recursive=1; fi ;;
        tar)
            if has_opt cru "--create --append --update" || [[ ${SWORDS[0]:-} != -* && ${SWORDS[0]:-} == *[cru]* ]]; then
                recursive=1
            fi
            ;;
    esac
    if ((!recursive)); then return; fi
    case $cmd in
        find)
            for ((i = 0; i < ${#SWORDS[@]}; i++)); do
                t=${SWORDS[i]}
                case $t in
                    -H | -L | -P) continue ;;
                    -* | '(' | ')' | '!') break ;;
                esac
                targets+=("$t")
            done
            ;;
        cp | rsync)
            targets=("${SARGS[@]}")
            if ((!STDIR && ${#targets[@]})); then unset 'targets[-1]'; fi
            ;;
        *) targets=("${SARGS[@]}") ;;
    esac
    if ((pattern)) && ! has_opt ef "--regexp --file --files" && ((${#targets[@]})); then targets=("${targets[@]:1}"); fi
    if ((${#targets[@]} == 0)); then targets=(.); fi
    for t in "${targets[@]}"; do
        if search_hit "$t"; then deny_token "recursive $cmd" "$t" search; fi
    done
}

# True when the text spells the token directory in any form, whatever the command around it does with it.
token_mentions() {
    local pat
    for pat in "${TPATS[@]}"; do
        if [[ -n $pat && $1 == *"$pat"* ]]; then return 0; fi
    done
    return 1
}

# A plain `merge-captain auth|auth-app|status ...` is how a person saves a token or the approver App's key and how
# anyone checks them; none prints one.
# Anything that could run other text inside the same segment disqualifies it.
token_exempt() {
    local -a w=()
    local i t cmd="" sub=""
    # shellcheck disable=SC2016  # matching the literal characters, not expanding them
    case $1 in
        *'`'* | *'<'* | *'>'* | *'$('*) return 1 ;;
    esac
    read -ra w <<<"$1"
    for ((i = 0; i < ${#w[@]}; i++)); do
        t=${w[i]//[\'\"]/}
        if [[ $t =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi
        cmd=${t##*/}
        sub=${w[i + 1]:-}
        break
    done
    [[ $cmd == merge-captain && ($sub == auth || $sub == auth-app || $sub == status) ]]
}

deny_token() {
    local what=${2:0:200}
    {
        echo "guard-delivery-state: blocked $1 on $what"
        echo "That is the merge captain's token directory. An agent may not read or change it: the owner saves a"
        echo "token with \`merge-captain auth <owner>\` (the approver App's key with \`merge-captain auth-app\`) in"
        echo "their own terminal, and \`merge-captain status\` shows which owners have one."
        if [[ -n ${3:-} ]]; then
            echo "A search rooted there walks into it; aim it at the project directory instead."
        fi
    } >&2
    exit 2
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
    local -a w=() args=() flags=()
    local i n t cmd="" ci=0 target last="" take_next=0 in_place=0 dup=0 tdir=0 rest
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

    # `bash -c '...'` runs another line of commands; judge its text the way the outer line is.
    case $cmd in
        bash | sh | zsh | dash)
            for ((i = ci + 1; i < n; i++)); do
                if [[ ${w[i]} == -c ]]; then
                    rest="${w[*]:i+1}"
                    check_command "${rest//[\'\"]/}"
                    break
                fi
            done
            ;;
    esac

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
            -t | --target-directory)
                if [[ $cmd == cp || $cmd == mv || $cmd == install || $cmd == ln ]]; then
                    take_next=1
                    tdir=1
                fi
                ;;
            --target-directory=*)
                tdir=1
                if hits "${t#*=}"; then deny "$cmd" "${t#*=}"; fi
                ;;
            -*) flags+=("$t") ;;
            *) args+=("$t") ;;
        esac
    done
    if ((${#args[@]})); then last=${args[-1]}; fi

    SFLAGS=("${flags[@]}")
    SARGS=("${args[@]}")
    SWORDS=("${w[@]:ci+1}")
    STDIR=$tdir
    check_search "$cmd"
    case $cmd in
        cd | pushd)
            if ((${#args[@]})); then
                expand_word "${args[0]}"
                t=$W
            elif ((${#flags[@]} == 0)); then
                t=$HOME
            else
                t=""
            fi
            if [[ -n $t ]]; then
                if [[ $t != /* ]]; then t="${RCWD:-${cwd:-$PWD}}/$t"; fi
                lexnorm "$t"
                RCWD=$NORM
            fi
            ;;
    esac

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

# The captain's tool and path overrides (MERGE_CAPTAIN_GH, _OPENSSL, _STATE, _TOKENS ...) exist for its tests. Set by an
# agent they would point the captain at a program or a directory of its choosing, so a command that assigns one, inline
# or through export, env, declare, python, perl, ruby or node, is refused. Reading one (grep, rg, echo) is harmless and
# stays allowed.
ASSIGNS_OVERRIDE='MERGE_CAPTAIN_[A-Za-z0-9_]*[[:space:]"'"'"']*[+]?='
# export, env and friends only count as the command being run (start of a line, or after ; & | ( or a quote opening
# a -c script), so grepping for the word "export" alongside a variable name is a read, not an assignment.
EXPORTS_WORD='(^|[;&|(]|[[:space:]]-[a-z]*c[[:space:]]+["'"'"'])[[:space:]]*(command[[:space:]]+|exec[[:space:]]+|sudo[[:space:]]+)?(export|declare|typeset|readonly|env|setenv)([^[:alnum:]_]|$)'
# Other languages' ways of setting a variable for a child (python, perl, ruby, node).
SETS_ENV_WORD='os[.]environ|os[.]putenv|[$]ENV[{[]|(^|[^[:alnum:]_])ENV[{[]|putenv|setenv|process[.]env'
deny_override() {
    {
        echo "guard-delivery-state: blocked Bash on ${1:0:200}"
        echo "MERGE_CAPTAIN_* variables redirect the merge captain's tools and directories. An agent may not set"
        echo "them; run the tool as it is."
    } >&2
    exit 2
}

# A line of commands, split wherever the shell would start a new one: newlines, ; && || | |& and a lone & (which
# backgrounds the command before it). The & of >&, &> and 2>&1 is part of a redirect, so it is set aside first.
check_command() {
    local cmd=$1 seg
    if [[ $cmd == *MERGE_CAPTAIN_* ]] &&
        { [[ $cmd =~ $ASSIGNS_OVERRIDE ]] || [[ $cmd =~ $EXPORTS_WORD ]] || [[ $cmd =~ $SETS_ENV_WORD ]]; }; then
        deny_override "$cmd"
    fi
    cmd=${cmd//>|/>}
    cmd=${cmd//>&/$'\x02'}
    cmd=${cmd//&>/$'\x03'}
    cmd=${cmd//|&/$'\n'}
    cmd=${cmd//&&/$'\n'}
    cmd=${cmd//&/$'\n'}
    cmd=${cmd//||/$'\n'}
    cmd=${cmd//|/$'\n'}
    cmd=${cmd//;/$'\n'}
    cmd=${cmd//(/$'\n'}
    cmd=${cmd//)/$'\n'}
    cmd=${cmd//$'\x02'/>&}
    cmd=${cmd//$'\x03'/&>}
    while IFS= read -r seg; do
        if [[ -z $seg ]]; then continue; fi
        if token_mentions "$seg" && ! token_exempt "$seg"; then deny_token "Bash" "$seg"; fi
        check_segment "$seg"
    done <<<"$cmd"
}

# True when a shell line names a command that can walk a tree and something that could be the home directory, the
# config directory or one of their parents. Decided with builtins only, so an ordinary command costs no process.
SEARCH_WORD='(^|[^[:alnum:]_./-])(grep|egrep|fgrep|zgrep|rg|ag|ack|fd|find|tar|rsync|cp|ls|du|tree|zip)([^[:alnum:]_./-]|$)'
BARE_CD='(^|[;&|(])[[:space:]]*(cd|pushd)[[:space:]]*($|[;&|)])'
SLASH_WORD="(^|[[:space:]'\"])/([[:space:]'\"*]|\$)"
# True when the text spells a directory above $1, or $1 itself.
names_above() {
    local d=$1
    if [[ -z $d ]]; then return 1; fi
    if [[ $2 == *"$d"* ]]; then return 0; fi
    while [[ $d == /*/* ]]; do
        d=${d%/*}
        if [[ $2 == *"$d"* ]]; then return 0; fi
    done
    return 1
}
may_search() {
    [[ $1 =~ $SEARCH_WORD ]] || return 1
    if [[ -n ${MERGE_CAPTAIN_TOKENS:-} ]]; then return 0; fi
    case $1 in
        *'~'* | *HOME* | *XDG* | */home* | *.config* | *..*) return 0 ;;
    esac
    if names_above "$HOME" "$1" || names_above "${XDG_CONFIG_HOME:-}" "$1" || [[ $1 =~ $SLASH_WORD ]]; then return 0; fi
    if [[ -n $cwd && ($cwd == "$HOME" || $HOME == "${cwd%/}"/*) ]]; then return 0; fi
    [[ $1 =~ $BARE_CD ]]
}

# True when no component of the absolute path is a symlink and none is `..`, which a link would make mean something
# else: the path is then its own real path.
plain_path() {
    local acc="" seg
    local -a parts
    local IFS=/
    read -ra parts <<<"$1"
    for seg in "${parts[@]}"; do
        case $seg in
            '') continue ;;
            ..) return 1 ;;
        esac
        acc+="/$seg"
        if [[ -L $acc ]]; then return 1; fi
    done
    return 0
}

# A file tool names a protected path through a link only if resolving it shows so; the common call has no link
# and stays free of processes.
fast_file_gate() {
    local v p r
    local -a resolve=() resolved=()
    extract file_path
    for v in "${VALUES[@]}"; do
        expand_word "$v"
        p=$W
        if [[ -z $p ]]; then continue; fi
        if [[ $p != /* ]]; then p="${cwd:-$PWD}/$p"; fi
        if plain_path "$p"; then
            if mentions_protected "$p"; then return; fi
        else
            resolve+=("$p")
        fi
    done
    if ((${#resolve[@]})); then
        command -v realpath >/dev/null 2>&1 || return
        mapfile -t resolved < <(realpath -m -- "${resolve[@]}" 2>/dev/null)
        for r in "${resolved[@]}"; do
            if mentions_protected "$r"; then return; fi
        done
    fi
    exit 0
}

fast_gate() {
    local v
    case $tool in
        Bash)
            extract command
            for v in "${VALUES[@]}"; do
                if may_search "$v"; then return; fi
            done
            exit 0
            ;;
        Read | Write | Edit | MultiEdit) fast_file_gate ;;
    esac
}

extract tool_name
tool=${VALUES[0]:-}
case $tool in
    Write | Edit | MultiEdit | Bash | Read | Grep | Glob) ;;
    *) exit 0 ;;
esac

extract cwd
cwd=${VALUES[0]:-}
if ((FAST)); then fast_gate; fi
build_protected

# A call that runs from inside the token directory reaches it with relative names.
case $tool in
    Bash | Grep | Glob)
        if [[ -n $cwd ]] && token_hits "$cwd"; then deny_token "$tool" "$cwd"; fi
        ;;
esac

if [[ $tool == Bash ]]; then
    extract command
    for value in "${VALUES[@]}"; do
        RCWD=$cwd
        check_command "$value"
    done
else
    extract file_path
    for value in "${VALUES[@]}"; do
        case $tool in
            Write | Edit | MultiEdit) if hits "$value"; then deny "$tool" "$value"; fi ;;
        esac
        if token_hits "$value"; then deny_token "$tool" "$value"; fi
    done
    if [[ $tool == Grep || $tool == Glob ]]; then
        # Grep's own pattern is a regex to find, not a place; Glob's pattern and Grep's glob are places.
        if [[ $tool == Glob ]]; then extract pattern; else extract glob; fi
        scopes=("${VALUES[@]}")
        for value in "${scopes[@]}"; do
            if token_mentions "$value"; then deny_token "$tool" "$value"; fi
        done
        extract path
        roots=("${VALUES[@]}")
        if ((${#roots[@]} == 0)); then roots=("${cwd:-$PWD}"); fi
        for value in "${roots[@]}"; do
            if [[ -z $value ]]; then value=${cwd:-$PWD}; fi
            if token_hits "$value"; then deny_token "$tool" "$value"; fi
            # A search rooted above the token directory reaches it unless its glob keeps it inside a project.
            if token_hits "$value" 1 && ! search_scoped "$value" "${scopes[0]:-}"; then
                deny_token "$tool" "$value" search
            fi
        done
    fi
fi
exit 0
