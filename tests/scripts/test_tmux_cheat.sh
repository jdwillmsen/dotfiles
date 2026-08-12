#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
script="$here/home/dot_local/bin/executable_tmux-cheat"
conf="$here/home/dot_tmux.conf"
shellcheck -s bash "$script"

fail() {
  echo "FAIL: $1"
  exit 1
}
run() { TMUX_CHEAT_CONF="$conf" bash "$script" "$@"; }

[ "$(run --version)" = "$(grep -m1 '^VERSION=' "$script" | cut -d'"' -f2)" ] ||
  fail "--version does not match VERSION"

# Config bindings must be parsed, not just stock tmux ones.
out="$(run --plain --custom)"
grep -q 'Ctrl+a |' <<<"$out" || fail "vertical split binding missing"
grep -q 'Ctrl+a -' <<<"$out" || fail "horizontal split binding missing (dash key eaten as a flag?)"
grep -q 'Alt+Left' <<<"$out" || fail "root-table pane navigation missing"
grep -q 'Ctrl+a H' <<<"$out" || fail "repeatable resize binding missing"
grep -qv 'select-pane -L' <<<"$out" || fail "raw tmux command leaked instead of a description"

# The remapped prefix must be read from the config, never assumed.
grep -q 'prefix Ctrl+a' <<<"$(run --plain)" || fail "prefix not read from config"

# Stock bindings the config leaves alone are merged in; rebound keys are not
# duplicated by their stock meaning.
grep -q 'Ctrl+a d' <<<"$(run --plain --defaults)" || fail "stock detach binding missing"
[ "$(run --plain 'Ctrl+a c' | grep -c 'New window')" -eq 1 ] ||
  fail "config binding shadowed or duplicated by the stock default"

# Plugin bindings follow the @plugin declarations in the config.
grep -q 'Ctrl+a Ctrl+r' <<<"$(run --plain)" || fail "tmux-resurrect binding missing"

# Machine-readable formats.
run --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["count"]>20, d["count"]' ||
  fail "--json is not valid JSON with a plausible count"
# Captured first: piping the script straight into `grep -q` makes it exit on
# SIGPIPE, which pipefail then reports as a failure.
toon="$(run --toon)"
grep -q '^prefix: Ctrl+a' <<<"$toon" || fail "--toon missing prefix header"
grep -qF '{key,action,group,source}:' <<<"$toon" || fail "--toon header malformed"

# Search covers the raw tmux command, not just the rendered description.
grep -q 'Ctrl+a H' <<<"$(run resize --plain)" || fail "search does not match the underlying tmux command"

# Errors are structured, on stdout, with usage exit codes.
run --nope >/dev/null 2>&1 && fail "unknown flag accepted"
[ "$(
  run --nope >/dev/null 2>&1
  echo $?
)" -eq 2 ] || fail "unknown flag did not exit 2"
grep -q '^error: unknown flag' <<<"$(run --nope 2>/dev/null || true)" || fail "unknown-flag error not on stdout"

# An empty result is a definitive answer, not a failure.
[ "$(
  run zzznope >/dev/null
  echo $?
)" -eq 0 ] || fail "no-match search should exit 0"
grep -q '^bindings: 0 matches' <<<"$(run zzznope)" || fail "no-match search lacks a definitive empty state"

# The config must actually bind the cheatsheet, or none of this is reachable.
grep -q 'bind ? run-shell "tmux-cheat --popup"' "$conf" || fail "prefix ? not bound to the cheatsheet"
grep -q "alias tk='tmux-cheat'" "$here/home/dot_config/shell/aliases.sh" || fail "tk alias missing"

echo "PASS"
