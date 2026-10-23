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

Packages: `xvfb`, `x11vnc`, `websockify`, `novnc`, `google-chrome-stable`, plus `uv` for
`check`. Runtime state (pids, logs) lives in `$XDG_RUNTIME_DIR/agent-browser`.

## Use

```bash
agent-browser start https://github.com/login   # prints the viewer link
agent-browser check github                     # logged_in: yes|no, user
agent-browser stop                             # closes the viewer, keeps sessions
agent-browser wipe --yes                       # forget every login
```

## Logging in with less friction

The profile persists, so each site needs a login roughly once per session lifetime
(weeks for most sites with "remember me"). To make that one login quick without an agent
ever touching a secret, install your password manager's extension in this profile, or
use a passkey: the secret goes from the manager to the site directly.

## Security model

- Agents never type, read or store credentials or cookies; `check` decides from what a
  page renders (for GitHub, the `user-login` meta tag), not from the cookie store.
- The viewer has no VNC password; the tailnet is the access control, so `stop` after each
  task.
- Anyone with shell access as this user can reach CDP on loopback and act as every
  logged-in session. Treat the devbox account as holding those sessions.
