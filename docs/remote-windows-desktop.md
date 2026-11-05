# Seeing and Driving the Gaming Rig's Windows Desktop

Findings from the 2026-11 overclock session on `jakegamingpc` (Windows 10 Pro,
Ryzen 9 3900X, RTX 2070, three 1920x1080 monitors = a 5760x1080 desktop). The
rig is reached over SSH on its Tailscale IP; this note covers what to use when a
task needs the **screen**, and whether stream encoding can move to another box.

## What works today with nothing installed

SSH lands in a non-interactive session with no desktop, so GUI programs started
from it never show. A scheduled task whose principal is the logged-in user with
`-LogonType Interactive -RunLevel Highest` runs in the live desktop session.
That is enough for:

- **Launch a GUI app on the user's screen** (installers, TestMem5, CoreCycler).
- **Screenshot all monitors**: a task running a script that
  `Graphics.CopyFromScreen`s the `SystemInformation.VirtualScreen` rectangle to
  a PNG, then `scp` it back. Verified: full 5760x1080 capture of the live
  desktop in about 10 s.

Limits learned the hard way:

- The screenshot task with `RunLevel Limited` ended with `LastTaskResult`
  `4294770688` (`0xFFFD0000`) and wrote no file; the same script with
  `Highest` worked. The cause was not diagnosed, so `Highest` is what is known
  to work, not proof that elevation is required.
- Delete the PNG after reading it. A capture contains whatever is on screen
  (chat, browser tabs, accounts); never keep or attach it.
- Script files via `scp`, never inline SSH quoting. Never kill all `powershell`.
- This is look-and-launch, not control. No clicks or typing without an input
  tool (below).

## Options for real remote control

| Tool | Shares the live console | Notes |
|---|---|---|
| **TightVNC server** | Yes, mirrors the physical screen | Best fit for "watch and take over". (TigerVNC's own wiki says official Windows server support ended in 2020, so it is not recommended here.) Agent side: `vncdotool` for screenshots and clicks. Bind to the Tailscale interface only; set a password. No GPU capture, so heavy motion is laggy. |
| **Sunshine + Moonlight** | Yes | GPU (NVENC) capture, lowest latency, built for games. Moonlight is a client app, not scriptable, so it suits the human, not an agent. |
| **RDP** | No: connecting locks or replaces the console session | Unsuitable while streaming. `TermService` is stopped on the rig and RDP is off (`fDenyTSConnections = 1`); leave it that way. |
| **PowerShell screenshot + input injection** (AutoHotkey or `SendInput` inside an Interactive task) | Yes | Zero install and nothing listening. Fiddly for input; fine for occasional clicks. |

Recommendation: start with the zero-install screenshot path (already works), and
if clicking is needed add **TightVNC bound to Tailscale** plus `vncdotool` on the
devbox. Keep Sunshine/Moonlight for the human playing remotely. The devbox has
`x11vnc` but no VNC viewer, so a viewer or `vncdotool` has to be provisioned.

Open risks, unverified: whether Riot Vanguard or other anti-cheat flags a VNC
server or input injection while a game runs. Test with the game closed first and
do not leave input tools running during ranked play.

Every install on the rig needs the owner's say-so (standing rule: nothing that
restarts the PC or touches the stream), and an agent must not remove the devbox
SSH key from `administrators_authorized_keys`.

## Hosting the stream encode elsewhere (dual streaming)

Facts: the rig has 12 cores and an RTX 2070 (NVENC); the devbox is a local VM
(about 0.9 ms to the rig) with 8 vCPUs, 15 GB RAM and **no GPU**.

Three ways to send the same game to two destinations (for example Twitch
horizontal plus TikTok vertical):

1. **Two outputs from OBS on the rig (simplest).** OBS Studio has one canvas;
   horizontal plus vertical at once needs a plugin (Aitum Vertical or Restream's
   Vertical plugin), or a second OBS instance. NVENC handles two encodes on this
   card. TikTok LIVE Studio is a separate app that can run beside OBS, but it
   captures the screen on its own, so it adds GPU and CPU load while gaming.
2. **Relay on the devbox.** OBS sends one high-bitrate stream to the devbox
   (RTMP to nginx-rtmp or MediaMTX, or SRT to MediaMTX; nginx-rtmp is RTMP
   only) and `ffmpeg` fans it out to each platform. Copy mode costs almost
   nothing; a **vertical** re-encode is x264 on 8 vCPUs and is the part that may
   not keep up. The rig-to-devbox hop is LAN and uses no home upload; WAN upload
   must still cover the sum of the platform bitrates plus overhead, the same as
   sending them straight from the rig.
3. **Run OBS itself on another PC.** Possible only by sending it the game
   picture: NDI or SRT from the rig's OBS, or a capture card. That adds a hop and
   puts a second encode on the other machine. OBS can encode with x264 on a CPU,
   so a GPU is not strictly required, but a CPU-only host needs lower
   resolution, frame rate or preset. Whether the 8-vCPU devbox VM can sustain
   that is untested and likely insufficient.

Current pick: option 1 for dual format; option 2 if the same picture goes to
several platforms and the rig must stay light. Option 3 needs another PC with a
stronger encoder (a GPU or a faster CPU). Not decided or built; the rig has OBS
Studio 33.0.1 installed and is not configured for any of this.

Twitch's dual-format streaming and Restream's vertical OBS plugin both have
first-party documentation; check account, plan and eligibility requirements on
each platform's own help pages before building on them.
