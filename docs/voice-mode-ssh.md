# Claude Code Voice Mode Over SSH

Voice mode's dictation recorder (SoX) runs on whatever host the `claude`
process runs on. Over a plain SSH + tmux session that's the remote box — which
has no microphone. This forwards the client's mic to the remote box over the
SSH connection so voice mode works there anyway.

Client and server need matching PulseAudio-over-TCP setup. `sox`,
`libasound2-plugins`, `pulseaudio-utils`, and `dot_asoundrc.tmpl` (redirects
ALSA's default device to PulseAudio) are provisioned by this repo — see
[`provisioning.md`](provisioning.md).

## WSL2 (WSLg) client → Linux server

WSLg ships its own PulseAudio server at `unix:/mnt/wslg/PulseServer` — that's
what bridges the Windows mic into WSL. There's no PipeWire involved; don't
install or configure `pipewire-pulse` for this path, it isn't there.

**Client (inside WSL):**

1. Load a TCP listener onto WSLg's existing Pulse server, loopback-only:
   ```
   pactl load-module module-native-protocol-tcp listen=127.0.0.1 port=4713 auth-ip-acl=127.0.0.1 auth-anonymous=1
   ```
   `auth-anonymous=1` is required — cookie-based auth over this path doesn't
   cleanly reject on mismatch, it **hangs** (`pactl info` times out instead of
   refusing). Copying `~/.config/pulse/cookie` to the server is not a
   reliable fix (WSLg regenerates the cookie on module reload); anonymous
   auth is safe here because the listener is already restricted to loopback
   + `auth-ip-acl=127.0.0.1`, and nothing reaches that port except through
   the SSH tunnel below. Verify:
   ```
   PULSE_SERVER=tcp:127.0.0.1:4713 pactl info
   ```
   Want a normal info dump (check `Default Source:`), not "Connection
   refused" or a hang.

2. Persist across WSL restarts — module loads don't survive a reboot.
   `dot_bashrc` in this repo already carries a guarded loader for this
   (search `WSL_DISTRO_NAME` there); it polls for `/mnt/wslg/PulseServer`
   for up to 5s before giving up, since a one-shot check can run before
   WSLg's Pulse socket exists yet and would otherwise skip loading for the
   rest of that shell's life. `chezmoi apply` deploys it — no manual edit
   needed.

3. Add to `~/.ssh/config`:
   ```
   Host <remote-host>
       RemoteForward 4713 127.0.0.1:4713
   ```
   The forward only comes up for the lifetime of that SSH connection — reconnect
   after adding it.

4. `ssh <remote-host>` as usual.

**Server (this repo already provisions the packages and `~/.asoundrc`):**

- `PULSE_SERVER` is exported automatically inside SSH sessions (see
  `dot_config/shell/exports.sh`), pointing at the forwarded port.
- Verify: `pactl info` should report the client's Pulse server (`Host Name:`
  will be the Windows/WSL box), not "Connection refused" or a hang. A hang
  here almost always means step 1's `auth-anonymous=1` is missing on the
  client.
- `arecord -d 2 -f cd /tmp/mictest.wav` should produce a non-trivial file if
  the whole chain works.

## Native Linux client → Linux server

Client runs PipeWire-Pulse rather than WSLg's bundled server:

1. Enable PipeWire-Pulse's TCP listener:
   ```
   cp /usr/share/pipewire/pipewire-pulse.conf ~/.config/pipewire/pipewire-pulse.conf
   ```
   Edit the copy's `server.address` to add `"tcp:127.0.0.1:4713"` alongside
   `"unix:native"`, then `systemctl --user restart pipewire pipewire-pulse`.
2. Same `~/.ssh/config` `RemoteForward` and server-side verification as above.

## Caveat

The tunnel binds `127.0.0.1` on both ends — nothing but that SSH session can
reach the forwarded mic. Don't widen this to `0.0.0.0` without knowing why.

Source: [javedab.com/.../claude-code-voice-over-ssh](https://javedab.com/en/pub/ai/ai-editors/claude-code-voice-over-ssh/)
