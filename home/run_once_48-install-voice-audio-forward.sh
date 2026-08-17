#!/usr/bin/env bash
set -euo pipefail
# Claude Code voice mode's SoX recorder needs a working ALSA default device;
# these packages redirect that to PulseAudio so a reverse-tunnelled remote mic
# (see docs/voice-mode-ssh.md) works over plain SSH. Linux/WSL only — macOS
# uses CoreAudio and native Windows has no ALSA to redirect.
if [ "$(uname -s)" != "Linux" ]; then
    echo "voice-audio-forward: not Linux — skipping"; exit 0
fi
if pactl --version &>/dev/null && arecord --version &>/dev/null; then
    echo "voice-audio-forward packages already installed — skipping"; exit 0
fi
if ! command -v apt-get &>/dev/null || ! sudo -n true 2>/dev/null; then
    echo "voice-audio-forward requires apt-get with passwordless sudo — install pulseaudio-utils libasound2-plugins alsa-utils manually"
    exit 0
fi
# Root-executed packages are reviewed explicitly, not inferred from a list —
# see tests/scripts/test_toolchain_scripts.sh.
APT_PKGS='pulseaudio-utils libasound2-plugins alsa-utils'
# shellcheck disable=SC2086  # deliberate word-splitting: space-separated package list
DEBIAN_FRONTEND=noninteractive sudo -n apt-get install -y -qq $APT_PKGS ||
    { echo "voice-audio-forward apt install failed"; exit 0; }
echo "voice-audio-forward packages installed"
