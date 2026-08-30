# Service inventory — what runs on this box when nobody is logged in

[`persistence.md`](persistence.md) explains the *model*: tmux, linger and
resurrect, and why a plain SSH session dies. This is the *census*: the
long-lived daemons that model keeps alive, who owns each one, and the single
command that tells you whether it is healthy.

The gap this closes is an incident one. When something remote stops answering,
the question is never "how does linger work" — it is "what is supposed to be
running, and which layer just went away." Re-deriving that from `ps` under
pressure is how a five-minute outage becomes an hour.

## The inventory

| Service | Scope | Owned by | Enabled | Listens on | Health check |
|---|---|---|---|---|---|
| `tailscaled` | system | `scripts/provision-tailscale.sh` (root step, not `chezmoi apply`) | yes | UDP `41641` all interfaces; TCP `443` on the tailnet addresses (Serve); a random high port per family for the peer API | `tailscale status` |
| `t3code.service` | user | `npx t3@latest service install` — **vendor-generated, no repo owner** | yes | `127.0.0.1:3773` | `systemctl --user status t3code` |
| `no-mistakes-daemon-<hash>.service` | user | `no-mistakes daemon start` — **unit vendor-generated**; the binary is repo-owned | yes | unix socket only (`~/.no-mistakes/socket`) | `no-mistakes daemon status` |
| `ssh.socket` → `ssh.service` | system | apt (`openssh-server`) | socket enabled, service `disabled` by design | `0.0.0.0:22`, `[::]:22` | `systemctl status ssh.socket` |
| `docker.service`, `containerd.service` | system | `run_once_49-install-dev-tools.sh.tmpl` (opt-in, via `chezmoi apply`) | yes | nothing — no containers, `docker0` is DOWN | `docker info` |
| `user@1000.service` + linger | system/user | `scripts/provision-persistence.sh` (root step) | `Linger=yes` | — | `loginctl show-user dev-admin -p Linger` |

Everything else in `systemctl list-units` is stock Ubuntu (journald, resolved,
logind, udev, cron, rsyslog, oomd, qemu-guest-agent, unattended-upgrades). No
timer on this box comes from this repo — the user timer list holds only
`launchpadlib-cache-clean.timer`, and the system list is apt/fwupd/logrotate
housekeeping. A timer you do not recognise there is new, not baseline.

## Three tiers of recoverability

"Managed by this repo" is not one thing, and the distinction is what this
document exists to preserve. Sorted by how much a rebuild gets for free:

**1. `chezmoi apply` recreates it.** Only `docker`/`containerd`, and only on a
machine that answered `installDevTooling`. Nothing else on the list.

**2. The repo can rebuild it, but you have to ask.** `tailscaled` and linger
are both `sudo scripts/provision-*.sh` steps. They are deliberately not
`run_` scripts — apt and `tailscale up` need root, and `chezmoi apply` runs
unattended in CI and first-boot bootstrap where a sudo prompt would hang it
(see [`provisioning.md`](provisioning.md#tailnet-access)). `chezmoi status`
will never tell you these are missing, so a rebuild that stops at `apply` is a
box with no tailnet.

**3. Nothing in the repo recreates it.** Two services and one pile of state:

- **`t3code.service`** is written by `npx t3@latest service install`. There is
  no `t3` binary on `PATH`; the runtime is vendored under `~/.t3/runtime` and
  updates itself in place (active version 0.0.36, rewritten on its own on
  2026-08-29). [`t3code.md`](t3code.md) is the owner's manual — this document
  only claims the daemon exists and how to tell if it is up.
- **The `no-mistakes` unit** is written by `no-mistakes daemon start`. The
  *binary* is repo-owned (the `agentClis` table in `home/.chezmoidata.yaml`,
  installed by `run_once_43-install-agent-clis.sh.tmpl`), so a rebuild gets the
  CLI and no daemon. That split is deliberate upstream of us — consistent with
  `no-mistakes init` gating a repo rather than a machine — it just means the
  daemon is one more thing to start by hand.
- **The tailnet node's identity and authorisation**, in root-only
  `/var/lib/tailscale/tailscaled.state`. `provision-tailscale.sh` *joins* a
  machine to the tailnet; it cannot restore an existing node. Rebuilding means
  a fresh auth and a new node, with the old one left to be removed from the
  admin console. The Tailscale Serve mapping lives in that same state file, and
  the MagicDNS and HTTPS-certificate toggles the setup depends on are
  tailnet-wide admin-console settings that no repo can hold.

## Tailscale — the only way in that isn't the LAN

`tailscaled` is the load-bearing one. It provides Tailscale SSH (`RunSSH` is
true in its prefs, which is what `provision-tailscale.sh` converges), and its
Serve listener on `:443` is the sole path to the code server —
[`t3code.md`](t3code.md#where-it-fits) lays out that stack.

`tailscale serve status` shows a single `/ proxy http://127.0.0.1:3773` and no
Funnel, so nothing here is published to the public internet. That config is
stored in `tailscaled.state` rather than a config file, and it demonstrably
survives a daemon restart: Tailscale auto-updates itself
(`AutoUpdate.Apply` is true), restarted the daemon on 2026-08-29 when it
upgraded to 1.102.3, and came back with Serve intact.

If `tailscaled` dies, every remote path except plain SSH from the LAN goes with
it. That fallback exists and is worth knowing about before you need it: `sshd`
listens on `0.0.0.0:22`, the box is reachable at `192.168.1.56` and on a
routable IPv6 address, and `ufw` is inactive. Key-only auth
(`PasswordAuthentication no`) is what makes that acceptable rather than
alarming.

The peer-API ports (`44334` and `55615` at the time of writing) are assigned
per daemon start. Do not treat those numbers as stable or firewall them by
value.

## t3code — the code server behind Serve

A `Type=simple` user unit with `Restart=always`, `RestartSec=5` and a
five-restarts-per-300s ceiling, so a crash loop stops rather than spinning. It
binds loopback only, which means a t3code outage and a Tailscale outage look
identical from a browser and are told apart by `curl` on the box:

```bash
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3773/   # want 200
```

Two operational properties are not visible from the unit's `active (running)`
line:

- **Application output does not reach the journal.** Both `StandardOutput` and
  `StandardError` are `append:` to `~/.t3/userdata/logs/boot-service.log`, so
  `journalctl --user -u t3code` shows lifecycle lines and nothing else. That
  file has no rotation (the separate `server.trace.ndjson` does rotate around
  10 MB); check its size before assuming a full disk is someone else's fault.
- **`ExecStart` hardcodes an nvm-versioned interpreter path**, currently
  `.../node/v24.19.0/bin/node`, and nvm has exactly that one version installed.
  A Node upgrade that prunes the old version breaks the service at its next
  start with no warning until then. `npx t3@latest service update` regenerates
  the unit; see [`t3code.md`](t3code.md#operating-notes).

## no-mistakes daemon — background half of the ship pipeline

Backs the `/no-mistakes` pipeline's out-of-band work (PR babysitting and
similar) between invocations. State is a SQLite database at
`~/.no-mistakes/state.sqlite`; the control channel is a unix socket, so this
daemon opens no port at all. It forks a `daemon log-sink` child — two processes
in `ps` is normal, not a duplicate.

The unit name carries a hash of `--root`, so each root gets its own unit. One
root, one unit, today. If you ever see two `no-mistakes-daemon-*` units, the
second one has a different root and is almost certainly unintended.

Version drift is silent here: `run_once_43` skips the install entirely when the
binary already exists, so the CLI never advances on its own. `no-mistakes
daemon status` prints the available upgrade alongside the running state, which
makes it the honest health check to run.

## The interactive layer

`Linger=yes` for `dev-admin` is what allows any of the user units above — and
the tmux server — to exist with zero logins. It is set once per machine by
`sudo scripts/provision-persistence.sh`. If `loginctl show-user dev-admin -p
Linger` ever reports `no`, both user services are already gone and so is every
detached tmux session; that is a single-cause outage worth checking first.
[`persistence.md`](persistence.md) covers the model in full.

## Long-lived processes that are not services

These show up in `ps` next to the real daemons and get mistaken for them.
Classifying them fast is most of the value of this section.

- **VS Code Remote-SSH server** — `~/.vscode-server/code-<hash> … agent host`
  on `127.0.0.1:35813`. Started by a Remote-SSH connection and deliberately
  outlives it; the instance running now dates from 2026-08-21. No unit, no
  restart policy. Killing it is safe and costs the next connection a
  reconnect.
- **`sshd` holding `127.0.0.1:4713`** — this is the reverse-forwarded
  PulseAudio port from [`voice-mode-ssh.md`](voice-mode-ssh.md), alive only for
  the SSH connection that requested it. In `ss -tlnp` it reads like a resident
  audio daemon. It is not one, and it is not something to restart.
- **An orphaned `no-mistakes` daemon under `/tmp`** — rooted at
  `/tmp/tmp.<random>/.no-mistakes`, parented to PID 1, under no systemd unit,
  and still running ten days after it started. `tests/smoke.sh` applies chezmoi
  into a `mktemp -d` HOME; the vendor installer that `run_once_43` pipes to
  `sh` starts a daemon under whatever HOME it was installed into, and the smoke
  test has no cleanup trap. Every smoke run leaks one. Kill it by PID — nothing
  restarts it, and it holds a SQLite database in a temp directory that will
  vanish under it at the next `/tmp` sweep.
- **Headless Chrome trees under `~/.cache/ms-playwright-mcp`** — spawned by the
  Playwright MCP server inside a Claude Code session and reaped with it. Several
  hundred MB resident each; they are agent state, not infrastructure.

## One sweep

```bash
loginctl show-user dev-admin -p Linger
systemctl --user list-units --type=service --state=running
systemctl status tailscaled ssh.socket docker --no-pager
tailscale status && tailscale serve status
curl -sf -o /dev/null -w 't3code %{http_code}\n' http://127.0.0.1:3773/
no-mistakes daemon status
ss -tlnp
```

`ss -tlnp` is last on purpose: it is the check that catches something listening
that no line of this document explains.
