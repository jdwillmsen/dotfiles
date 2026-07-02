#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$repo/tests/lib.sh"

# 1. Old installer into a fake HOME.
old_home="$(mktemp -d)"
HOME="$old_home" bash "$repo/install.sh" >/dev/null 2>&1 || true

# 2. chezmoi apply into a fresh fake HOME (two-phase sandboxed init via harness).
new_home="$(mktemp -d)"
chez_apply "$(chez_init personal)" "$new_home" >/dev/null 2>&1

# 3. Compare the file *sets* (names + relative paths), ignoring known-intentional diffs.
# Manifests are written outside the trees being scanned — writing them inside
# would race the `find` that produces them (the redirect target can exist by
# the time `find` reaches it) and make each tree diff against its own listing.
manifests="$(mktemp -d)"
( cd "$old_home" && find . -type f | sort ) > "$manifests/old"
( cd "$new_home" && find . -type f | sort ) > "$manifests/new"

# Floor check: if the legacy installer crashed before creating files, old manifest
# would be near-empty and the comparison would report "PARITY OK" despite failure.
old_count="$(wc -l < "$manifests/old")"
[ "$old_count" -gt 10 ] || { echo "PARITY FAILED: legacy installer produced only $old_count files — install.sh likely crashed"; exit 1; }

echo "=== files only under OLD installer ==="
comm -23 "$manifests/old" "$manifests/new" || true
echo "=== files only under chezmoi ==="
comm -13 "$manifests/old" "$manifests/new" || true

# Windows checkouts of the pre-migration top-level dotfiles (no .gitattributes
# eol pin, unlike *.sh/*.tmpl) get CRLF from core.autocrlf=true; chezmoi's
# home/ sources are LF. Strip \r on both sides so that checkout artifact
# never masks — or is masked by — a real content diff.
nocr() { tr -d '\r' < "$1"; }

# 4. Content diff for the files present in both (excluding known-intentional diffs).
status=0
while read -r f; do
    case "$f" in
        ./.gitconfig) # store helper intentionally changed — compare with that line stripped
            diff <(nocr "$old_home/$f" | grep -v 'helper = store') \
                 <(nocr "$new_home/$f" | grep -vE 'helper = (libsecret|manager)?$') >/dev/null || { echo "DIFF: $f (beyond credential helper)"; status=1; } ;;
        ./.claude/settings.json|./.claude/mcp.json) : ;;  # key-order/merge volatile — checked by unit tests
        ./.bashrc|./.zshrc) : ;;  # shell rc intentionally rewritten to source ~/.config/shell/* instead of a ~/dotfiles checkout — checked by test_rc.sh/test_shell_files.sh
        ./.codex/config.toml) : ;;  # legacy feature runs `python3` with no real-interpreter fallback and silently no-ops on Windows' python3 Store stub; chezmoi's modify_ script probes for a working interpreter (see test_codex_config.sh)
        *) diff <(nocr "$old_home/$f") <(nocr "$new_home/$f") >/dev/null || { echo "DIFF: $f"; status=1; } ;;
    esac
done < <(comm -12 "$manifests/old" "$manifests/new")

[ "$status" -eq 0 ] && echo "PARITY OK" || echo "PARITY FAILED"
exit "$status"
