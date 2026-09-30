#!/usr/bin/env bash
# node-fallback.sh must put an installed node on PATH when nvm left none, which
# happens once the lts alias names a release that is not installed, and must
# never displace a node nvm did choose.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
fallback="$here/home/dot_config/shell/node-fallback.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_node() {
    mkdir -p "$1/.nvm/versions/node/$2/bin"
    for b in node npx; do
        printf '#!/bin/sh\necho %s\n' "$2" >"$1/.nvm/versions/node/$2/bin/$b"
        chmod +x "$1/.nvm/versions/node/$2/bin/$b"
    done
}

# A system npx in /usr/bin would satisfy the fallback's guard, so the inner
# shells get a PATH holding only the tools the code under test needs.
tools="$tmp/tools"
mkdir -p "$tools"
for t in bash cat find sort tail; do ln -s "$(command -v "$t")" "$tools/$t"; done

# Expanded by the inner shell after sourcing, not by this one.
# shellcheck disable=SC2016
path_after_sourcing() {
    env -i HOME="$1" PATH="${2:-$tools}" "$tools/bash" -c '. "$0" && printf %s "$PATH"' "$fallback"
}

home="$tmp/versions"
fake_node "$home" v9.11.2
fake_node "$home" v10.24.1
fake_node "$home" v22.23.2
fake_node "$home" v24.19.0
# An interrupted install leaves a newer directory with no binary in it.
mkdir -p "$home/.nvm/versions/node/v25.0.0/bin"
nvm_entries="$(path_after_sourcing "$home" | tr : '\n' | grep '\.nvm' || true)"
[ "$nvm_entries" = "$home/.nvm/versions/node/v24.19.0/bin" ] \
    || { echo "FAIL: expected only the newest installed node on PATH, got: $nvm_entries"; exit 1; }
# shellcheck disable=SC2016  # expanded by the inner shell
[ "$(env -i HOME="$home" PATH="$tools" "$tools/bash" -c '. "$0" && node' "$fallback")" = v24.19.0 ] \
    || { echo "FAIL: node does not resolve after sourcing node-fallback.sh"; exit 1; }

# A node and npx already on PATH, however they got there, are left alone.
existing="$tmp/existing-node"
mkdir -p "$existing"
for b in node npx; do
    printf '#!/bin/sh\necho existing\n' >"$existing/$b"
    chmod +x "$existing/$b"
done
[ "$(path_after_sourcing "$home" "$existing:$tools")" = "$existing:$tools" ] \
    || { echo "FAIL: PATH changed although node and npx were already on it"; exit 1; }

# A distro node without npm (Ubuntu's nodejs package) still leaves no npx, so
# the fallback must apply anyway.
distro="$tmp/distro-node"
mkdir -p "$distro"
printf '#!/bin/sh\necho distro\n' >"$distro/node"
chmod +x "$distro/node"
[ "$(path_after_sourcing "$home" "$distro:$tools")" = "$home/.nvm/versions/node/v24.19.0/bin:$distro:$tools" ] \
    || { echo "FAIL: no fallback when node is on PATH without npx"; exit 1; }

for case in no-nvm empty; do
    case_home="$tmp/$case"
    mkdir -p "$case_home"
    [ "$case" = empty ] && mkdir -p "$case_home/.nvm/versions/node"
    path_after_sourcing "$case_home" | grep -q '\.nvm' \
        && { echo "FAIL: $case: an nvm path was added with no node installed"; exit 1; }
done

# Through the real bashrc, against a stand-in nvm.sh that reproduces the one
# behaviour that matters here: an nvm node already on PATH is kept, and the
# default alias is consulted only when there is none.
mkdir -p "$home/.config/shell" "$home/.nvm/alias"
cp "$fallback" "$home/.config/shell/node-fallback.sh"
# shellcheck disable=SC2016  # expanded when the rc file sources the stub
printf '%s\n' \
    'case "$(command -v node 2>/dev/null)" in' \
    '    "$NVM_DIR"/*) ;;' \
    '    *) v="$(cat "$NVM_DIR/alias/default")"' \
    '       [ -x "$NVM_DIR/versions/node/$v/bin/node" ] && PATH="$NVM_DIR/versions/node/$v/bin:$PATH" ;;' \
    'esac' >"$home/.nvm/nvm.sh"
node_via_bashrc() {
    env -i HOME="$home" PATH="$tools" "$tools/bash" --rcfile "$here/home/dot_bashrc" -i -c 'node' 2>/dev/null | tail -n 1
}
echo v22.23.2 >"$home/.nvm/alias/default"
[ "$(node_via_bashrc)" = v22.23.2 ] \
    || { echo "FAIL: bashrc: a resolvable nvm default did not win over the fallback"; exit 1; }
echo v24.21.0 >"$home/.nvm/alias/default"
[ "$(node_via_bashrc)" = v24.19.0 ] \
    || { echo "FAIL: bashrc: no fallback node when the nvm default is not installed"; exit 1; }
echo "PASS"
