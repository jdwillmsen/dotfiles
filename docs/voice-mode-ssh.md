# Claude Code Voice Mode Over SSH

Voice mode's dictation recorder (SoX) runs on whatever host the `claude`
process runs on. Over a plain SSH + tmux session that's the remote box — which
has no microphone. This forwards the client's mic to the remote box over the
SSH connection so voice mode works there anyway.

Client and server need matching PulseAudio-over-TCP setup. `sox`,
`libasound2-plugins`, `pulseaudio-utils`, and `dot_asoundrc.tmpl` (redirects
ALSA's default device to PulseAudio) are provisioned by this repo — see
[`provisioning.md`](provisioning.md).

## Linux/WSL2 client → Linux server

**Client** (wherever the mic lives — a native Linux box, or Windows 11's
WSL2, which bridges the Windows mic in via WSLg automatically):

1. Enable PipeWire-Pulse's TCP listener:
   ```
   cp /usr/share/pipewire/pipewire-pulse.conf ~/.config/pipewire/pipewire-pulse.conf
   ```
   Edit the copy's `server.address` to add `"tcp:127.0.0.1:4713"` alongside
   `"unix:native"`, then `systemctl --user restart pipewire pipewire-pulse`.
2. Add to `~/.ssh/config`:
   ```
   Host <remote-host>
       RemoteForward 4713 127.0.0.1:4713
   ```
3. `ssh <remote-host>` as usual — the forward comes up with the connection.

**Server** (this repo already provisions the packages and `~/.asoundrc`):

- `PULSE_SERVER` is exported automatically inside SSH sessions (see
  `dot_config/shell/exports.sh`), pointing at the forwarded port.
- Verify: `pactl info` should report the client's Pulse server, not "Connection refused".

## Caveat

The tunnel binds `127.0.0.1` on both ends — nothing but that SSH session can
reach the forwarded mic. Don't widen this to `0.0.0.0` without knowing why.

Source: [javedab.com/.../claude-code-voice-over-ssh](https://javedab.com/en/pub/ai/ai-editors/claude-code-voice-over-ssh/)
