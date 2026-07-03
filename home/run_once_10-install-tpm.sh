#!/usr/bin/env bash
set -euo pipefail
command -v tmux &>/dev/null || { echo "tmux not found — skipping TPM"; exit 0; }
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ ! -d "$TPM_DIR" ]; then
    git clone --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR" || { echo "TPM clone failed — skipping"; exit 0; }
fi
