# Claude Code Voice Mode Over SSH — Retired

This box forwarded a client microphone to itself over SSH so Claude Code's CLI
dictation would work in a remote session. That chain is gone. This note stays
so the absence is a decision on the record rather than a gap someone rebuilds.

## What it was

Voice mode's recorder (SoX) runs on whatever host the `claude` process runs on.
Over SSH that is this box, which has no capture device — `/dev/snd` carries
only `seq` and `timer`. So the client ran a loopback PulseAudio TCP listener,
`ssh` reverse-forwarded port 4713 to it, `PULSE_SERVER` pointed at the
forwarded port inside SSH sessions, and `~/.asoundrc` redirected ALSA's default
device to PulseAudio so SoX found something to record from.

## Why it went

- It was broken: the client no longer runs the PulseAudio tools the chain
  needs, so the recorder had nothing to reach.
- It announced that breakage on every login, as a failed-port-forward warning
  from a forward nothing was listening for.
- Its setup was written against WSLg's bundled PulseAudio server, which is a
  client-side assumption this repo cannot see and had already drifted.
- The capability it provided arrived by a path that asks nothing of this box:
  the agent harness in [`t3code.md`](t3code.md#voice-input) takes voice input on
  the iOS app, recording and transcribing on the phone and submitting text.

What is lost is dictation into the `claude` CLI *specifically*, in a session
hosted here. Voice mode on a machine that has its own microphone is unaffected
— `sox` is still provisioned for that.

## What was removed

The provisioning script for `pulseaudio-utils`, `libasound2-plugins` and
`alsa-utils`; `dot_asoundrc.tmpl`; the `PULSE_SERVER` export in
`dot_config/shell/exports.sh`; and the WSL-guarded PulseAudio TCP loader in
`dot_bashrc`. `home/.chezmoiremove` deletes the deployed `~/.asoundrc` on the
next apply.

## The client-side leftover

The forward itself was never in this repo — it lives in the client's
`~/.ssh/config` as a `RemoteForward 4713 127.0.0.1:4713` line under the devbox
host. Delete that line; until it is gone, each connection still asks for a
forward this box no longer serves, and `ss -tlnp` here still shows `sshd`
holding `127.0.0.1:4713`.
