# Devbox auto-maintenance — design

## Problem

On 2026-10-15 the login banner read `*** System restart required ***`: the box
had run `6.8.0-142-generic` for 8 days with `6.8.0-147-generic` installed, and
60 non-security updates were pending. unattended-upgrades was enabled but
allowed only `-security` origins and had `Automatic-Reboot` off.

## Decisions

- **Install all stable updates.** Add `-updates` to the allowed origins. A
  devbox tolerates the small regression risk better than drift.
- **Guarded reboot, not a fixed-time one.** unattended-upgrades' own
  `Automatic-Reboot-Time` would reboot under a live overnight agent run. A
  root timer runs a guard hourly in a quiet window (08–12 UTC); it reboots only
  when a reboot is required and the box is idle.
- **Idle means:** no apt/dpkg or `/usr/bin/unattended-upgrade` process; no
  agent transcript (Claude, Codex, OpenCode) written in 60 minutes; no
  keyboard input on any of the user's ptys in 60 minutes (tty atime, as `w`
  reports). Attached-but-idle tmux is the normal overnight state, so attachment
  alone would block every reboot.
- **Two signals rejected after a live dry run:** `pgrep -x unattended-upgr`
  matches the always-running `unattended-upgrade-shutdown` helper (names are
  truncated to 15 characters), and tmux 3.4's `client_activity` stays at the
  attach time rather than tracking input.
- **Escalate, don't force.** If a reboot keeps getting deferred for 7 days, a
  login line says so and gives the command. The guard never overrides activity.
- **Verify after boot.** A user timer runs `devbox-health` five minutes after
  boot and leaves failing lines in a marker the login shell prints.
- **No ticket automation.** The `OPS` project takes only relay-filed alerts,
  and a scheduled ticket would be noise; the login line is the escalation.

## Out of scope

- T3 Code re-pairing: it mints a credential and needs the device in hand.
- agent-metrics' per-session call threshold flagging long, interactive sessions.

## Layout

| File | Role |
|---|---|
| `scripts/provision-auto-maintenance.sh` | Root, run once: apt drop-in, installs the guard and its system timer |
| `scripts/devbox-reboot-guard` | The decision; `--dry-run` prints it without acting |
| `home/dot_config/systemd/user/devbox-health-boot.{service,timer}` | Post-boot check |
| `home/dot_local/bin/executable_devbox-health-boot` | Runs `devbox-health`, writes or clears the marker |
| `maintenance_notice` in `home/dot_config/shell/functions.sh` | Login line from either marker |
