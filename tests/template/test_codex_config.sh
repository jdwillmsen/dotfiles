#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "--- $2"; exit 1; }

# Resolved by glob rather than named: the attribute prefixes on this entry are
# exactly what the chezmoi assertions below exist to police, and hardcoding the
# filename here means a wrong rename dies on this line with a bare "No such
# file or directory" before those assertions ever run — catching the bug, but
# reporting it as a missing file rather than as the broken contract it is.
script="$(echo "$here"/home/private_dot_codex/*modify*config.toml.toml)"
[ -f "$script" ] || fail "no modify entry for the codex config in the source tree" \
    "$(ls "$here/home/private_dot_codex")"

existing='[tui]
status_line = ["old"]

[other]
x = 1'
# Plain modify script (no template directives) — run directly, stdin = current file.
out="$(printf '%s' "$existing" | bash "$script")"
echo "$out" | grep -q 'model-with-reasoning' || fail "status_line not set"
echo "$out" | grep -q '\[other\]' || fail "other section lost"
echo "$out" | grep -c 'status_line' | grep -qx 1 || fail "duplicate status_line"
# Idempotency: piping the output back through the script must be byte-identical.
out2="$(printf '%s' "$out" | bash "$script")"
[ "$out" = "$out2" ] || fail "not idempotent"

# Everything below asks chezmoi itself what this source entry means, because
# both ways it can break are invisible in the file's own contents. The name
# encodes two independent decisions and each has its own failure:
#   * modify_ makes it a script whose stdout becomes the target. Attributes
#     bind *after* the type prefix, so private_modify_config.toml.toml is not
#     a modify script at all — chezmoi reads it as a plain file named
#     private_modify_..., leaves .codex/config.toml unmanaged, and deploys the
#     script's own source as a stray ~/.codex/modify_config.toml.toml.
#   * private_ makes the result 0600. Without it chezmoi deploys 0664, and
#     because Codex rewrites its own config at 0600, every apply loosens the
#     file and Codex tightens it back — permanent MM drift in chezmoi status.
# Neither raises an error, so only chezmoi's own answer distinguishes them.
cfg="$(chez_init)"
dest="$(chez_sandbox)"

# Captured before matching, not piped into grep: under `set -o pipefail` a
# `grep -q` that exits on its first match closes the pipe, and a chezmoi still
# writing its listing dies on SIGPIPE — which pipefail would report as this
# assertion failing. It is the assertion guarding the prefix-order bug, so it
# must fail only for that reason. Compared literally rather than by pattern,
# because the dots here are filename dots, not regex.
managed="$(chezmoi managed --source "$CHEZ_SRC" --config "$cfg" --destination "$dest")"
printf '%s\n' "$managed" | grep -qxF '.codex/config.toml' \
    || fail "chezmoi does not manage .codex/config.toml from this source entry" "$managed"

# Reproduces the reported drift: seed the destination at the mode the unfixed
# entry deployed and require the apply to tighten it rather than restore it.
mkdir -p "$dest/.codex"
printf '[other]\nx = 1\n' >"$dest/.codex/config.toml"
chmod 664 "$dest/.codex/config.toml"
HOME="$dest" chezmoi apply --source "$CHEZ_SRC" --config "$cfg" \
    --destination "$dest" --force "$dest/.codex/config.toml"

grep -q 'model-with-reasoning' "$dest/.codex/config.toml" \
    || fail "the applied config was not produced by the modify script"

# Windows has no POSIX mode for chezmoi to set; the managed-target check above
# is the portable half of this contract.
case "$(uname -s)" in
    MINGW*|MSYS*) ;;
    *)
        mode="$(stat -c '%a' "$dest/.codex/config.toml")"
        [ "$mode" = 600 ] || fail "the codex config deployed world-readable" "mode $mode"
        ;;
esac

echo "PASS"
