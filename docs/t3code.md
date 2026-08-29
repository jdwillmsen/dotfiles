# T3 Code — driving devbox agents from a phone

T3 Code is an agent harness: a web/desktop/mobile front end over the agent
CLIs already installed here (Claude Code, and optionally Codex, Cursor, Grok,
OpenCode). It runs as a headless server on the devbox and reuses the existing
`~/.claude` credentials — there is no second login and no second subscription.

What it adds over `ssh` + `tmux` is a touch-usable surface. Reading a diff,
approving a step, or starting a thread from a phone works in a way a terminal
emulator on a 6-inch screen does not. It does not replace the tmux/linger
stack in [`persistence.md`](persistence.md); it sits beside it as a fourth way
into the same box.

## Where it fits

| Layer | Purpose |
|---|---|
| `tailscaled` (system service) | Reachable identity for the box from any network |
| `t3code.service` (systemd **user** unit) | The agent harness server, port 3773 |
| tmux + linger | Interactive SSH sessions, unchanged |

The T3 Code server is a daemon nobody attaches to, so it belongs in systemd
rather than a tmux pane — a `kill-server` or a botched reattach would
otherwise take phone access down with it.

## Setup

### 1. Tailscale

```bash
sudo scripts/provision-tailscale.sh
```

Installs the package, enables `tailscaled`, and joins the tailnet as
`devbox` with Tailscale SSH on. Prints an auth URL to visit once.

Then, in the Tailscale admin console under DNS, enable **MagicDNS** and
**HTTPS Certificates**. Both are required: T3 Code serves over the MagicDNS
name, and the hosted client at `app.t3.codes` is an HTTPS page that browsers
forbid from talking to a plain `http://` backend.

Install Tailscale on the phone and sign in with the same account.

There is deliberately no LAN-facing bind. On the home network Tailscale
connects peer-to-peer across the local switch, so a second `0.0.0.0` listener
would add reachable surface without adding reach — the same URL works at home
and away.

### 2. T3 Code

```bash
npx t3@latest service install
```

Writes `~/.config/systemd/user/t3code.service` and enables lingering (already
on here — see [`persistence.md`](persistence.md)). The service survives logout
and starts at boot.

Leave the server bound to `127.0.0.1:3773` — its default — and put Tailscale
Serve in front of it:

```bash
sudo tailscale serve --bg http://127.0.0.1:3773
```

The server is then at `https://devbox.<tailnet>.ts.net/`. Serve config
persists across reboots; `tailscale serve --https=443 off` removes it.

Fronting a loopback listener beats binding the Tailnet address directly:
there is no HTTP listener on the tailnet at all, TLS is terminated with a
real certificate rather than not at all, and tailnet identity is checked at
the proxy before a request reaches T3 Code. The first HTTPS request after
enabling Serve takes ~20s while the certificate is issued; subsequent ones
are single-digit milliseconds.

### 3. Pairing a device

```bash
npx t3@latest pair --tailscale --label iphone --ttl 15m
```

`--tailscale` pairs through the tailnet HTTPS URL rather than the loopback
origin, which is the difference between a link the phone can use and one it
cannot. Prints a one-time token, a pairing URL, and a QR code; the token
defaults to a 5 minute TTL. Scan it on the phone with Tailscale connected.
After pairing, access is session-based for 30 days.

Run this in your own terminal rather than through an agent — the token is a
credential and there is no reason to widen where it has been.

`npx t3@latest auth` lists and revokes credentials and sessions.

## Operating notes

**Pairing tokens are passwords.** The token rides in the URL fragment, so it
is not sent to the hosted app server — but it does persist in browser history,
screenshots, and clipboards. Anyone holding a valid one can open a session
until it expires or is revoked.

**Threads default to Full access**, meaning the agent runs commands and edits
files unattended. This is the intended mode here because every thread gets its
own branch and worktree under `~/.t3/worktrees`, which satisfies the
throwaway-sandbox condition that mode assumes. The mode is per-thread, chosen
in the composer; it is not a server-wide setting.

**Provider binaries must be on the server's `PATH`.** `claude` resolves from
`~/.local/bin`, which is stable. Anything installed through a version manager
needs an explicit binary path set per provider in Settings, since the systemd
unit does not inherit an interactive shell's `PATH`.

**The generated unit hardcodes an nvm-versioned node path** in `ExecStart`.
Removing that node version breaks the service at next start, with no warning
until then. `npx t3@latest service update` regenerates the unit against the
current node; run it after any nvm major-version change.

## State on disk

Everything lives under `~/.t3`:

| Path | Contents |
|---|---|
| `userdata/state.sqlite` | Threads, sessions, settings |
| `userdata/logs/` | `server.log`, per-terminal logs, provider events |
| `userdata/secrets/` | Provider env values marked sensitive |
| `worktrees/` | Per-thread git worktrees |

Back up or wipe `~/.t3/userdata` to reset; the service reinstalls clean.
