#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"

fail() { echo "FAIL: $1"; exit 1; }

tmpl="$here/home/dot_config/clone-repos/repos.tsv.tmpl"
script="$here/home/dot_local/bin/executable_clone-repos"

# The rendered list is driven through the real command in --dry-run, so the
# assertions are on what a machine of each role would actually clone.
selection() {
    local list
    list="$(mktemp "$CHEZ_TMP_ROOT/repos.XXXXXXXX")"
    chez_render "$1" "$tmpl" >"$list"
    HOME="$(chez_sandbox)" bash "$script" --list "$list" --dry-run "${@:2}" |
        sed -n 's/^  \([^,]*\),[^,]*,would-clone$/\1/p' | sort
}

gaming="$(chez_init gaming </dev/null)"
personal="$(chez_init personal)"

want_gaming="$(printf '%s\n' jdwillmsen/dotfiles jdwillmsen/gaming-rig)"
got="$(selection "$gaming")"
[ "$got" = "$want_gaming" ] || fail "gaming default must be gaming-rig + dotfiles, got: $got"

got="$(selection "$personal")"
[ "$(wc -l <<<"$got")" = 13 ] || fail "personal default must be every repo, got: $got"
got="$(selection "$gaming" --group all)"
[ "$(wc -l <<<"$got")" = 13 ] || fail "gaming --group all must still reach every repo, got: $got"

# Paths follow the stream layout, so `stream key` and the folder aliases work in
# a restored clone. The one owner outside the stream map is filed explicitly.
chez_render "$personal" "$tmpl" | while IFS=$'\t' read -r slug path _; do
    case "$slug" in '#'* | default-group | '') continue ;; esac
    if [ "$slug" = Dotablaze/dotablaze-tech ]; then
        [ "$path" = dotablaze-tech/dotablaze-tech ] || fail "$slug filed at $path"
    else
        [ "$path" = "$slug" ] || fail "$slug filed at $path, not <owner>/<repo>"
    fi
done

# The gaming role ignores most of ~/.config; this one it needs.
dest="$(chez_sandbox)"
for cfg in "$gaming" "$personal"; do
    chezmoi managed --source "$CHEZ_SRC" --config "$cfg" --destination "$dest" --exclude=dirs |
        grep -qxF .config/clone-repos/repos.tsv || fail "repos.tsv not managed under $cfg"
    chezmoi managed --source "$CHEZ_SRC" --config "$cfg" --destination "$dest" --exclude=dirs |
        grep -qxF .local/bin/clone-repos || fail "clone-repos not managed under $cfg"
done

echo "PASS"
