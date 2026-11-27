# agent-browser

A logged-in browser that agents drive while the human does every login. Built for
websites with no usable API: LinkedIn profile edits, GitHub settings pages (social
previews, org avatars), job sites.

## Pieces

| Piece | Binds to | Why |
|---|---|---|
| `Xvfb :99` | none (`-nolisten tcp`) | virtual display |
| Chrome, profile `~/.cache/agent-browser` | CDP on `127.0.0.1:9222` | CDP is full control of every logged-in session, so loopback only |
| `x11vnc` | `localhost:5900` | VNC never leaves the box |
| `websockify` + noVNC | tailnet IPv4 `:6080` | the human's viewer; refuses to start without a tailnet address |
| `~/.local/share/agent-browser/agent_browser.py` | none | Playwright helper that attaches a script to its lease's tab |

Packages: `xvfb`, `x11vnc`, `websockify`, `novnc`, `google-chrome-stable`, `curl`, `flock`,
plus `uv` for `check` and `py`. Runtime state (pids, logs, leases) lives in
`$XDG_RUNTIME_DIR/agent-browser`.

## Parallel agents: leases and slots

Several agent sessions use the browser at once. Before leases, every agent drove
`pages[-1]` (whichever tab was last, often another agent's) and the first agent to finish ran
`stop`, killing the browser under the rest.

- **Lease.** `start` records a lease (`$RUN/leases/<id>`) and opens a tab only that lease
  drives. `stop <lease>` closes that tab and stops the slot only when no live lease remains.
  A bare `stop` is refused while leases are live; `stop --force` overrides. `py`, `check` and
  `show` refresh a lease; one unused for `AGENT_BROWSER_LEASE_TTL` (2 h) expires, so a crashed
  agent cannot hold the browser up forever. `start`/`stop` serialise on a `flock`.
- **Slot.** Slot 0 is shared: the original ports and profile, which every plain `start` joins.
  `start --slot auto` takes the first free isolated slot (1 to `AGENT_BROWSER_MAX_SLOTS - 1`,
  default 3), preferring one whose profile already has logins. Slot N shifts every port by N
  (display `:99+N`, CDP `9222+N`, VNC `5900+N`, viewer `6080+N`) and uses profile
  `~/.cache/agent-browser-slotN`. Logins are per slot: profiles are never copied, since that
  would mean an agent handling cookies.

Use a slot when two agents could be on the same site with the same account at once (shared
cookies mean shared server-side state, such as one LinkedIn draft) or a task needs a clean
session. Otherwise share slot 0. Each Chrome costs roughly 300-500 MB of memory.

## Use

```bash
agent-browser start https://github.com/login   # prints lease:, viewer: and cdp:
agent-browser check github --lease <lease>     # logged_in: yes|no, user
agent-browser py <lease> script.py             # Playwright attached to the lease's tab
agent-browser show <lease>                     # bring that tab to the viewer's front
agent-browser stop <lease>                     # closes the tab; last lease stops the viewer
agent-browser start --slot auto <URL>          # an isolated browser, own viewer and profile
agent-browser wipe --yes [--slot N]            # forget every login in a slot
```

Scripts run through `py` get `AGENT_BROWSER_CDP`, `AGENT_BROWSER_TARGET` and
`AGENT_BROWSER_LEASE` in their environment; `from agent_browser import page` turns them into
the lease's Playwright page. Tools that keep their own CDP code, such as `claude-usage`, open a
fresh page and release the lease that their `start` printed.

## Logging in with less friction

The profile persists, so each site needs a login roughly once per session lifetime
(weeks for most sites with "remember me"). To make that one login quick without an agent
ever touching a secret, install your password manager's extension in this profile, or
use a passkey: the secret goes from the manager to the site directly.

## Security model

- Agents never type, read or store credentials or cookies; `check` decides from what a
  page renders (for GitHub, the `user-login` meta tag), not from the cookie store.
- The viewer has no VNC password; the tailnet is the access control, so release the lease
  after each task; the last release closes the viewer.
- Leases coordinate cooperating agents; they are not a security boundary. Any process as
  this user can reach every slot's CDP port.
- Anyone with shell access as this user can reach CDP on loopback and act as every
  logged-in session. Treat the devbox account as holding those sessions.
