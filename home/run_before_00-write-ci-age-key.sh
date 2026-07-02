#!/usr/bin/env bash
# CI has no `pass`/on-disk age identity; it exports CHEZMOI_AGE_KEY instead.
# Write it to the temp path .chezmoi.toml.tmpl configured as [age].identity
# so decryption of encrypted_ source files has a key to use during apply.
# Runs unconditionally but is a no-op locally, where CHEZMOI_AGE_KEY is unset
# and the on-disk ~/.config/chezmoi/key.txt identity is used instead.
set -euo pipefail

if [ -n "${CHEZMOI_AGE_KEY:-}" ]; then
    printf '%s' "$CHEZMOI_AGE_KEY" > "${RUNNER_TEMP:-/tmp}/chezmoi-age-key.txt"
fi
