# Git Worktree Helpers — Bash (Git Bash / WSL); PowerShell equivalents live in
# worktree-helpers.ps1. Sourced from .bashrc.
#
# Bash-only by construction: mapfile and 0-indexed arrays have no zsh
# equivalent, so .zshrc deliberately does not source this.
#
# Worktrees: ~/worktrees/<project>/<type>/<name>   (override: export WT_BASE=...)
# Commands:  gwt  gwta  gwtr  wts  wtd  wtp  wtst  wtclean
#
# shellcheck disable=SC2059  # colour codes are interpolated into every format
# string here by design; the inputs are this file's own constants, not user data
[ -n "${BASH_VERSION:-}" ] || return 0

WT_BASE="${WT_BASE:-$HOME/worktrees}"

# ── colors ────────────────────────────────────────────────────────────────────
_R=$'\033[0m' _B=$'\033[1m' _D=$'\033[2m'
_RED=$'\033[31m' _GRN=$'\033[32m' _YLW=$'\033[33m'
_BLU=$'\033[34m' _CYN=$'\033[36m' _WHT=$'\033[37m' _GRY=$'\033[90m'
_BG_BLK=$'\033[40m'

# ── internal ──────────────────────────────────────────────────────────────────

__wt_repo_root() {
    git rev-parse --show-toplevel 2>/dev/null \
        || { echo "[wt] Not in a git repo" >&2; return 1; }
}

__wt_project() { basename "$(__wt_repo_root 2>/dev/null)"; }

__wt_branch_list() {
    git worktree list --porcelain 2>/dev/null \
        | grep "^branch " | sed 's|^branch refs/heads/||'
}

# Has BRANCH already landed in MAIN?
#
# Ancestry alone is wrong under squash merges: the squash commit shares no SHA
# with the branch, so `git branch --merged` reports nothing even when every
# branch is merged. Ask the forge, and treat "no answer" as unmerged — this
# gates deletion, so the safe default is to keep.
__wt_branch_merged() {
    local branch="$1" main_branch="$2"

    git merge-base --is-ancestor "$branch" "$main_branch" 2>/dev/null && return 0

    command -v gh &>/dev/null || return 1
    local n
    n=$(gh pr list --head "$branch" --state merged --json number --jq 'length' 2>/dev/null) || return 1
    [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -gt 0 ]]
}

# Short path: strips ~/worktrees/<project>/ prefix
# -l flag: keep full path
__wt_path_display() {
    local path="$1" long="${2:-0}" project
    project=$(__wt_project 2>/dev/null)
    local prefix="$WT_BASE/$project/"
    if [[ "$long" -eq 1 ]]; then
        echo "$path"
    elif [[ "$path" == "$prefix"* ]]; then
        echo "${path#"$prefix"}"          # → feat/auth-jwt
    else
        echo "$(basename "$path") (root)" # → myapp (root)
    fi
}

# Parse porcelain output → lines of: PATH|BRANCH|COMMIT
__wt_parse() {
    git worktree list --porcelain 2>/dev/null | awk '
        /^worktree / { path=$2 }
        /^branch /   { branch=$2; sub("refs/heads/","",branch) }
        /^HEAD /     { commit=substr($2,1,7) }
        /^$/         {
            print path "|" (branch ? branch : "(detached)") "|" commit
            path=""; branch=""; commit=""
        }
        END { if (path) print path "|" (branch ? branch : "(detached)") "|" commit }
    '
}

# One rich display row — pad BEFORE coloring for correct alignment
__wt_row() {
    local path="$1" branch="$2" commit="$3" is_current="${4:-0}" long="${5:-0}"

    local bullet
    [[ "$is_current" == "1" ]] \
        && bullet="${_YLW}${_B}◉${_R}" \
        || bullet="${_GRY}○${_R}"

    local dirty_n dirty_str
    dirty_n=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$dirty_n" -gt 0 ]]; then
        dirty_str="${_YLW}✗ $(printf '%-2s' "$dirty_n")${_R}"
    else
        dirty_str="${_GRN}✔   ${_R}"
    fi

    local ahead behind
    ahead=$(git -C "$path" rev-list --count "@{upstream}..HEAD" 2>/dev/null || echo "·")
    behind=$(git -C "$path" rev-list --count "HEAD..@{upstream}" 2>/dev/null || echo "·")

    # Pad before coloring
    local branch_p commit_p path_p
    branch_p=$(printf "%-34s" "$branch")
    commit_p=$(printf "%-8s"  "$commit")
    path_p=$(__wt_path_display "$path" "$long")

    printf "  %b  %b%b%b  %b%b%b  %b  %b↑%-3s%b%b↓%s%b  %b%s%b\n" \
        "$bullet" \
        "$_B$_WHT" "$branch_p" "$_R" \
        "$_GRY"   "$commit_p" "$_R" \
        "$dirty_str" \
        "$_CYN"   "$ahead"  "$_R" \
        "$_RED"   "$behind" "$_R" \
        "$_GRY"   "$path_p" "$_R"
}

# ── gwt ───────────────────────────────────────────────────────────────────────
# List all worktrees.  gwt -l  for full paths.

gwt() {
    local long=0
    [[ "$1" == "-l" || "$1" == "--long" ]] && long=1

    local current
    current=$(git rev-parse --show-toplevel 2>/dev/null)

    local project
    project=$(__wt_project 2>/dev/null)

    local hdr_branch hdr_commit
    hdr_branch=$(printf "%-34s" "BRANCH")
    hdr_commit=$(printf "%-8s"  "COMMIT")

    printf "\n  ${_D}  ${hdr_branch}  ${hdr_commit}  STATUS    ↑↓       PATH${_R}\n"
    printf "  ${_GRY}%s${_R}\n" "$(printf '─%.0s' {1..78})"

    __wt_parse | while IFS='|' read -r path branch commit; do
        local is_current=0
        [[ "$path" == "$current" ]] && is_current=1
        __wt_row "$path" "$branch" "$commit" "$is_current" "$long"
    done

    printf "\n"
}

# ── gwta ──────────────────────────────────────────────────────────────────────
# gwta <name>          → feat/auth-jwt
# gwta fix/null-check  → fix/null-check
# gwta <name> fix      → fix/<name>

gwta() {
    local input="$1" type="${2:-feat}" name

    if [[ -z "$input" ]]; then
        echo -e "${_YLW}Usage:${_R}  gwta <name> [feat|fix|chore|docs|refactor|test|ci]"
        echo    "        gwta <type>/<name>"
        return 1
    fi

    if [[ "$input" == */* ]]; then
        type="${input%%/*}"; name="${input#*/}"
    else
        name="$input"
    fi

    local root branch wt_path
    root=$(__wt_repo_root) || return 1
    branch="$type/$name"
    wt_path="$WT_BASE/$(__wt_project)/$branch"

    mkdir -p "$(dirname "$wt_path")"

    printf "\n  ${_CYN}${_B}Creating worktree${_R}\n"
    printf "  ${_GRY}%-10s${_R} %s\n" "branch"  "${_B}${_WHT}${branch}${_R}"
    printf "  ${_GRY}%-10s${_R} %s\n" "path"    "${_GRY}${wt_path}${_R}"
    printf "  ${_GRY}%s${_R}\n\n" "$(printf '─%.0s' {1..50})"

    git worktree add "$wt_path" -b "$branch" && {
        printf "\n  ${_GRN}✔ Ready${_R}  ${_GRY}→${_R}  ${_B}${branch}${_R}\n\n"
        cd "$wt_path" || return 1
    }
}

# ── gwtr ──────────────────────────────────────────────────────────────────────
# Jump to root (main) worktree

gwtr() {
    local root
    root=$(git worktree list --porcelain 2>/dev/null \
        | grep "^worktree " | head -1 | awk '{print $2}')
    [[ -z "$root" ]] && { echo "[wt] No root worktree" >&2; return 1; }
    cd "$root" || return 1
    printf "  ${_GRN}◉${_R}  ${_B}%s${_R}  ${_GRY}(root)${_R}\n" \
        "$(git -C "$root" branch --show-current 2>/dev/null)"
}

# ── wts ───────────────────────────────────────────────────────────────────────
# Interactive switch. fzf shows git log preview; fallback: numbered select.

wts() {
    local current
    current=$(git rev-parse --show-toplevel 2>/dev/null)

    # Build tab-delimited lines: DISPLAY\tPATH
    local lines=()
    while IFS='|' read -r path branch commit; do
        local dirty_n marker
        dirty_n=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        [[ "$path" == "$current" ]] && marker="◉" || marker="○"
        [[ "$dirty_n" -gt 0 ]] && dirty="✗${dirty_n}" || dirty="✔ "
        # Pad for alignment, tab-separate hidden path for extraction
        lines+=("$(printf '%s  %-34s  %-8s  %s' "$marker" "$branch" "$commit" "$dirty")	$path")
    done < <(__wt_parse)

    [[ ${#lines[@]} -eq 0 ]] && { echo "[wt] No worktrees found"; return; }

    local selected path

    if command -v fzf &>/dev/null; then
        selected=$(printf '%s\n' "${lines[@]}" | fzf \
            --ansi \
            --prompt="  worktree> " \
            --pointer="▶" \
            --marker="✓" \
            --height=60% \
            --layout=reverse \
            --border=rounded \
            --info=inline \
            --delimiter=$'\t' \
            --with-nth=1 \
            --preview='git -C {2} log --oneline --graph --color --decorate -12 2>/dev/null;
                       echo "";
                       git -C {2} status --short 2>/dev/null | head -8' \
            --preview-window="right:45%:wrap" \
            --header="  BRANCH                              COMMIT    STATUS")
        [[ -z "$selected" ]] && return
        path=$(awk -F'\t' '{print $2}' <<< "$selected")
    else
        echo -e "\n  ${_B}Select worktree:${_R}\n"
        local display_lines=()
        for line in "${lines[@]}"; do
            display_lines+=("$(cut -f1 <<< "$line")")
        done
        select sel in "${display_lines[@]}" "Cancel"; do
            [[ "$sel" == "Cancel" || -z "$sel" ]] && return
            local idx=$(( REPLY - 1 ))
            path=$(awk -F'\t' '{print $2}' <<< "${lines[$idx]}")
            break
        done
    fi

    [[ -n "$path" ]] && cd "$path" \
        && printf "\n  ${_GRN}✔${_R}  Switched to  ${_B}$(git branch --show-current)${_R}\n\n"
}

# ── wtst ──────────────────────────────────────────────────────────────────────
# Status dashboard across all worktrees. Interactive if fzf available.

wtst() {
    local current
    current=$(git rev-parse --show-toplevel 2>/dev/null)
    local project
    project=$(__wt_project 2>/dev/null)

    printf "\n  ${_B}${_CYN}%-34s${_R}  ${_B}%-8s${_R}  ${_B}%-10s${_R}  ${_B}%-7s${_R}  ${_B}%s${_R}\n" \
        "BRANCH" "COMMIT" "STATUS" "↑↓" "PATH"
    printf "  ${_GRY}%s${_R}\n" "$(printf '─%.0s' {1..78})"

    while IFS='|' read -r path branch commit; do
        local is_current=0
        [[ "$path" == "$current" ]] && is_current=1
        __wt_row "$path" "$branch" "$commit" "$is_current"
    done < <(__wt_parse)

    printf "\n"

    # Interactive: if fzf available, offer to switch
    if command -v fzf &>/dev/null; then
        printf "  ${_GRY}Press enter to switch, Esc to exit${_R}\n\n"
        wts
    fi
}

# ── wtd ───────────────────────────────────────────────────────────────────────
# wtd <branch>   remove worktree + branch
# wtd -f ...     force (unmerged ok)
# wtd -k ...     keep branch, remove worktree only

wtd() {
    local force="" keep_branch=""
    while [[ "$1" == -* ]]; do
        case "$1" in -f) force="--force" ;; -k) keep_branch=1 ;; esac
        shift
    done

    local branch="$1"
    [[ -z "$branch" ]] && { echo -e "${_YLW}Usage:${_R} wtd [-f] [-k] <branch>" >&2; return 1; }

    local wt_path
    wt_path="$WT_BASE/$(__wt_project)/$branch"

    if [[ ! -d "$wt_path" ]]; then
        # Porcelain emits `worktree <path>` before `branch <ref>`, so the path
        # has to be carried forward and printed on the branch match. Matching
        # the branch first and printing the next `worktree` line resolves to
        # the *following* worktree — a force-remove of the wrong tree.
        wt_path=$(git worktree list --porcelain 2>/dev/null \
            | awk -v b="$branch" '
                /^worktree / { path=$2 }
                /^branch / && $2 == "refs/heads/"b { print path; exit }
            ')
        [[ -z "$wt_path" ]] \
            && { printf "  ${_RED}✗${_R}  Worktree '%s' not found\n" "$branch" >&2; return 1; }
    fi

    printf "  ${_YLW}Removing${_R}  ${_B}%s${_R}\n" "$branch"
    git worktree remove $force "$wt_path" && {
        printf "  ${_GRN}✔${_R}  Worktree removed\n"
        if [[ -z "$keep_branch" ]]; then
            git branch -d "$branch" 2>/dev/null \
                && printf "  ${_GRN}✔${_R}  Branch deleted\n" \
                || printf "  ${_YLW}⚠${_R}  Branch has unmerged commits — use ${_B}git branch -D %s${_R}\n" "$branch"
        fi
    }
}

# ── wtp ───────────────────────────────────────────────────────────────────────

wtp() {
    printf "  ${_CYN}Pruning metadata...${_R}\n"
    git worktree prune -v
    printf "  ${_CYN}Fetching + pruning remote refs...${_R}\n"
    git fetch --prune
}

# ── wtclean ───────────────────────────────────────────────────────────────────
# Remove worktrees for merged branches. fzf multi-select if available.
#
# wtclean       prompt when interactive; list-and-refuse when not
# wtclean -y    remove without prompting (required non-interactively)
# wtclean -n    list what would be removed, change nothing

wtclean() {
    local assume_yes="" dry_run=""
    while [[ "$1" == -* ]]; do
        case "$1" in
            -y | --yes) assume_yes=1 ;;
            -n | --dry-run) dry_run=1 ;;
            *) printf "  ${_YLW}Usage:${_R} wtclean [-y] [-n]\n" >&2; return 1 ;;
        esac
        shift
    done

    local main_branch
    main_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's|origin/||')
    [[ -z "$main_branch" ]] && main_branch="main"

    local candidates=() merged=() branch
    mapfile -t candidates < <(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
        | grep -vE "^(${main_branch}|main|master|develop|HEAD)$" \
        | grep -v "^$")

    for branch in "${candidates[@]}"; do
        __wt_branch_merged "$branch" "$main_branch" && merged+=("$branch")
    done

    if [[ ${#merged[@]} -eq 0 ]]; then
        printf "\n  ${_GRN}✔${_R}  Nothing to clean up\n\n"; return
    fi

    printf "\n  ${_YLW}Merged branches:${_R}\n"
    printf "    ${_GRY}•${_R} %s\n" "${merged[@]}"
    printf "\n"

    [[ -n "$dry_run" ]] && { printf "  ${_GRY}Dry run — nothing removed${_R}\n\n"; return; }

    local to_remove=()

    if [[ -n "$assume_yes" ]]; then
        to_remove=("${merged[@]}")
    elif [[ ! -t 0 ]]; then
        # `read` on a closed stdin returns empty, which the old code read as
        # "declined" — an agent calling wtclean got a silent no-op that looked
        # like success. Refuse loudly and say what would have happened.
        printf "  ${_YLW}⚠${_R}  Not a terminal — refusing to remove without ${_B}-y${_R}\n\n"
        return 2
    elif command -v fzf &>/dev/null; then
        mapfile -t to_remove < <(printf '%s\n' "${merged[@]}" | fzf \
            --multi \
            --prompt="  select to remove> " \
            --pointer="▶" \
            --marker="✓" \
            --height=40% \
            --layout=reverse \
            --border=rounded \
            --header="  Tab to multi-select, Enter to confirm")
        [[ ${#to_remove[@]} -eq 0 ]] && { echo "  Cancelled"; return; }
    else
        read -rp "  Remove all listed? [y/N] " confirm
        [[ "$confirm" != "y" ]] && return
        to_remove=("${merged[@]}")
    fi

    for branch in "${to_remove[@]}"; do
        wtd -f "$branch" 2>/dev/null || printf "  ${_RED}✗${_R}  Could not remove '%s'\n" "$branch"
    done
    wtp
}

# ── tab completion ─────────────────────────────────────────────────────────────

_wtd_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    mapfile -t COMPREPLY < <(compgen -W "$(__wt_branch_list 2>/dev/null | tr '\n' ' ')" -- "$cur")
}
complete -F _wtd_complete wtd

_gwta_complete() {
    if [[ "${COMP_CWORD}" -eq 2 ]]; then
        local cur="${COMP_WORDS[COMP_CWORD]}"
        mapfile -t COMPREPLY < <(compgen -W "feat fix chore docs refactor test ci" -- "$cur")
    fi
}
complete -F _gwta_complete gwta
