# T3 Code — driving devbox agents from a phone

T3 Code is an agent harness: a web/desktop/mobile front end over the agent
CLIs already installed here (Claude Code, Codex, Cursor, Grok and OpenCode —
see [Providers](#providers)). It runs as a headless server on the devbox and
reuses each CLI's own credentials — for Claude Code that is `~/.claude`, so
there is no second login and no second subscription.

What it adds over `ssh` + `tmux` is a touch-usable surface. Reading a diff,
approving a step, or starting a thread from a phone works in a way a terminal
emulator on a 6-inch screen does not. It does not replace the tmux/linger
stack in [`persistence.md`](persistence.md); it sits beside it as a fourth way
into the same box.

## Where it fits

| Layer | Purpose |
|---|---|
| `tailscaled` (system service) | Reachable identity for the box from any network |
| Tailscale Serve | TLS termination and tailnet identity check at the edge, proxying to the loopback server |
| `t3code.service` (systemd **user** unit) | The agent harness server, bound to `127.0.0.1:3773` |
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
`devbox` with Tailscale SSH on; prints an auth URL to visit once. See
[`provisioning.md`](provisioning.md#tailnet-access) for the script's
environment overrides and re-run behaviour.

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

After pairing, access is session-based for 30 days. That TTL is hard — nothing
in T3 Code's environment-auth path renews, refreshes, or extends a live
session, so it does not slide forward with use and day 31 is a re-pair rather
than a prompt. Re-pairing means running `t3 pair` again, which needs a shell on
the devbox. If the phone that just expired is the only device to hand, the
terminal-free way back in is Tailscale's browser SSH console from the admin
console — which is the reason the provisioner enables `--ssh` at all. It keeps
"T3 Code is wedged" and "I cannot reach the box" from being the same failure.

Run this in your own terminal rather than through an agent — the token is a
credential and there is no reason to widen where it has been.

`npx t3@latest auth` lists and revokes credentials and sessions.

### 4. Expiry warning

Day 31 arrives silently, so a timer watches for it. `~/.local/bin/t3-session-expiry`
reports any session inside a threshold — 7 days by default, overridable
per-run or through `T3_SESSION_EXPIRY_DAYS` in the service unit:

```bash
t3-session-expiry        # default 7-day window
t3-session-expiry 14     # widen it for a one-off look
```

Exit codes are the contract: `0` nothing due, `1` a session is inside the
window or has already lapsed, `2` the check could not run. That last split
matters — a check that could not reach T3 Code must never read as an
all-clear. A non-zero exit is deliberately left to surface as a *failed* unit
rather than masked, so the verdict shows up without reading the journal:

```bash
systemctl --user list-timers t3-session-expiry.timer
systemctl --user status t3-session-expiry.service
```

A due run also drops `~/.local/state/t3-session-expiry.warn` naming the
affected sessions; only a conclusive all-clear clears it, so an inconclusive
run leaves a standing warning alone. The check re-derives nvm's node path for
the same reason the generated `t3code.service` hardcodes one (see Operating
notes): a systemd user unit inherits no interactive `PATH`.

`chezmoi apply` reloads and enables the timer; by hand, `systemctl --user
daemon-reload && systemctl --user enable --now t3-session-expiry.timer`.

## Providers

T3 Code drives each provider as a child process: every CLI below is spawned by
bare binary name, except Antigravity's ACP server, which T3 downloads and runs
from its own tools directory. It sells nothing and stores no
credential of its own: every CLI below is installed and authenticated
separately, and the harness only launches what is already working.

| Provider | Binary | Installed by | Sign-in |
|---|---|---|---|
| Claude Code | `claude` | vendor installer (`~/.local/bin`) | already signed in via `~/.claude` |
| Codex | `codex` | `@openai/codex`, npm row in `agentClis` | `codex login` (ChatGPT plan or `OPENAI_API_KEY`) |
| Cursor | `cursor-agent` | `https://cursor.com/install`, script row in `agentClis` | `cursor-agent login` |
| Grok | `grok` | `@xai-official/grok`, npm row in `agentClis` | `grok` on first run, or `XAI_API_KEY` |
| OpenCode | `opencode` | `opencode-ai`, npm row in `agentClis` | `opencode auth login`, plus the providers in `~/.config/opencode/opencode.json` |
| Antigravity | `agy_acp_server.par` | T3 itself — an action in its settings | Google account, Gemini API key, or Gemini Enterprise, chosen in T3's settings |

Versions are pinned in the `agentClis` table described in
[`provisioning.md`](provisioning.md#agent-cli-versions); upgrading any of them
is a one-line edit there.

**Sign-ins run in your own terminal, never through an agent.** Each command
above prints or exchanges a credential, and an agent's shell tool persists that
output into a transcript. Open a separate SSH login or tmux pane and run them
there.

### Enabling them in T3

T3 ships Cursor, Grok, OpenCode and Antigravity disabled, and it owns
`userdata/settings.json` — the server rewrites that file itself, so chezmoi
does not manage it. Script `52` merges the enable flags and any missing
provider instance into it instead, leaving every other key the server has
written alone. The wanted set lives in the `t3Providers` table in
`home/.chezmoidata.yaml`.

Antigravity is the one provider T3 installs for you rather than expecting on
`PATH`. Its settings carry an optional binary path where blank means automatic,
and choosing Install fetches the official ACP server from `dl.google.com` —
around 680 MB compressed, unpacking to roughly 2 GB under `~/.t3/tools`,
SHA-256 verified against a digest baked into the release. Leave the binary path
empty: naming one pins a file T3 manages.

Antigravity carries a `minVersion` there. It gained a provider driver after
0.0.38, where the same name meant only the "open in editor" target, so the
script leaves the row out entirely until `runtime/service-state.json` reports a
runtime new enough to decode it — an older T3 meeting a driver its schema has
never heard of risks the whole provider config. That version is rendered into
the script, so the first apply after a T3 upgrade is what switches the row on.

Neither the script nor an apply restarts the service. `t3code.service` owns
every agent session on this box, so a restart is deliberate:

```bash
systemctl --user restart t3code.service
```

### PATH

A systemd user unit inherits none of an interactive shell's `PATH`. The default
reaches neither `~/.local/bin` nor the version-managed npm prefix, which is
every provider binary here — so without help each one fails to spawn.
`~/.config/systemd/user/t3code.service.d/10-provider-path.conf` supplies a
`PATH` covering both. It is a drop-in rather than an edit to the unit because
`npx t3@latest service update` regenerates the unit and would drop the setting.

That file is static, and the moving part sits behind a name that is not:
`~/.local/npm-bin` is a symlink script `52` points at the real npm global bin,
which lives under a version-managed node install. An earlier version resolved
the prefix at render time instead, which made a managed file's content depend
on the environment rendering it — an apply and a verify disagreed, and CI
failed on drift that was real. After an nvm major-version change, run
`chezmoi apply` alongside `npx t3@latest service update`: the apply repoints
the symlink, the update regenerates the unit's own hardcoded node path.

### OpenCode models

OpenCode is bring-your-own-model. `~/.config/opencode/opencode.json` declares
the two endpoints that need wiring by hand: the LAN `gpu-stack` server, which
needs no credential, and NVIDIA NIM, which reads
`PLATFORMCTL_JDWLABS_NVIDIA_API_KEY` from the environment. Anything OpenCode
already knows from its own catalog — Anthropic, OpenAI, OpenRouter — is reached
through `opencode auth login` instead and needs nothing in that file.

The `gpu-stack` model carries an explicit `limit`. OpenCode otherwise requests
32000 output tokens, which alone overruns that server's 32768-token window and
fails every call.

## Voice input

Voice input exists on the **iOS app only**, and it needs nothing from this box.

On an iPhone running iOS 26 or later, the composer has a microphone button.
Recording and transcription both happen on the phone, using Apple's
`SpeechAnalyzer`/`SpeechTranscriber`; the first use downloads a speech model
and needs network, after which it works offline for that language. A recording
caps at five minutes, the local audio file is deleted after transcription or
cancellation, and only the resulting message text is submitted. There is no
setting to turn on, on the phone or on the server.

Web and desktop have no voice input. The upstream design note states it
plainly: "Environment-provided transcription and transcription on web and
desktop are not implemented." So the Electron app and a browser tab get
nothing, and OS-level dictation (`Win+H` on Windows) into the composer is the
whole workaround.

### The devbox never records audio

This is a deliberate upstream boundary, not a gap waiting to be filled. From
the same design note:

> Local means the client device, regardless of which machine hosts the
> environment.

> Remote service configuration and API keys belong to the environment. The
> environment calls the external service.

This box is the *environment*. Even in the planned remote-transcription path,
its role is to hold a credential and proxy audio to an external service — it
never opens a capture device. That matters because it has none: `/dev/snd`
carries only `seq` and `timer`, and no PulseAudio or PipeWire daemon is
installed.

The SSH microphone forward that once carried a client mic to this box was
**not** a dependency of T3 Code voice input — it existed because Claude Code's
CLI recorder runs on whatever host `claude` runs on, which is the opposite of
the boundary above. It has since been retired;
[`voice-mode-ssh.md`](voice-mode-ssh.md) records why. Do not rebuild it for T3
Code.

For the same reason there is nothing to add to any `.devcontainer` — passing
`--device /dev/snd` into a container whose host has no capture device maps
nothing, and there is no PulseAudio socket to bind.

### When web voice does arrive

The prerequisite is already satisfied. `getUserMedia()` requires a secure
context, and Tailscale Serve publishes this server at
`https://<machine>.<tailnet>.ts.net` with a real certificate. A plain LAN or
tailnet-IP origin such as `http://100.x.y.z:3773` would **not** work — there is
no private-address exemption to the secure-context rule, and the failure is
opaque (`navigator.mediaDevices` is `undefined` rather than a permission
error). `ssh -L 3773:127.0.0.1:3773` is the fallback, because `127.0.0.1` is
trustworthy unconditionally.

Upstream work to watch, all unmerged as of 2026-09-02: `pingdotgg/t3code`
[#5213](https://github.com/pingdotgg/t3code/pull/5213) (web, desktop and
server, BYOK through a `/api/transcription` proxy),
[#8928](https://github.com/pingdotgg/t3code/pull/8928) (desktop-local capture)
and [#9028](https://github.com/pingdotgg/t3code/pull/9028)
(environment-backed, which unlocks Android and pre-26 iOS). Forking the client
to add a microphone ahead of these is a poor trade: the package ships multiple
releases a week plus nightlies, and #5213 already implements the design the
maintainers' own note specifies.

Sources: [voice input on
iPhone](https://github.com/pingdotgg/t3code/blob/main/docs/user/composer.md#voice-input-on-iphone),
[voice input
internals](https://github.com/pingdotgg/t3code/blob/main/docs/internals/voice-input.md).

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

**Provider binaries must be on the server's `PATH`**, which the systemd unit
does not inherit from any shell. The drop-in described under
[PATH](#path) supplies one; the alternative, if you ever need a binary outside
it, is an explicit path set per provider in T3's settings.

**The generated unit hardcodes an nvm-versioned node path** in `ExecStart`.
Removing that node version breaks the service at next start, with no warning
until then. `npx t3@latest service update` regenerates the unit against the
current node; run it after any nvm major-version change.

## State on disk

Everything lives under `~/.t3`:

| Path | Contents |
|---|---|
| `userdata/state.sqlite` | Threads, sessions, settings |
| `userdata/logs/` | `server.log`, per-terminal logs, provider events. The unit appends its own stdout/stderr here as `boot-service.log`, which nothing rotates — `server.trace.ndjson` does, around 10 MB |
| `userdata/secrets/` | Provider env values marked sensitive |
| `worktrees/` | Per-thread git worktrees |

Back up or wipe `~/.t3/userdata` to reset; the service reinstalls clean.
