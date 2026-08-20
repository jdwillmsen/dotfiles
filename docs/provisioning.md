# Machine provisioning

`chezmoi apply` handles everything that can be installed as the logged-in user.
Anything needing root lives in `scripts/` and is run explicitly, once per
machine, so that `apply` never blocks on a sudo password — it runs unattended in
CI, devcontainers, and first-boot bootstrap.

## Swap and OOM handling

```bash
sudo scripts/provision-swap.sh
```

Idempotent; re-run it after a rebuild or a kernel upgrade. Environment
overrides: `SWAPFILE`, `SWAPFILE_SIZE`, `SWAPFILE_PRIORITY`, `ZRAM_ALGO`,
`ZRAM_PERCENT`, `ZRAM_PRIORITY`, `SWAPPINESS`, `VFS_CACHE_PRESSURE`.

What it sets up, and why it is shaped this way:

| Layer | Setting | Rationale |
|---|---|---|
| zram | zstd, 25% of RAM, priority 100 | Compressed RAM-backed swap. First tier because a swap-out is a RAM-to-RAM compress rather than disk I/O. |
| Swapfile | 16 GiB at `/swapfile`, priority 10 | Absorbs true overflow only, after zram is exhausted. Persisted in `/etc/fstab`. |
| Tuning | `vm.swappiness=60`, `vm.vfs_cache_pressure=50` | Swappiness is deliberately *high*. The usual "set it low" advice assumes a disk-backed tier; with zram in front, the kernel should reach for swap freely. Lower cache pressure keeps dentry/inode cache warm across large source trees. |
| OOM | `systemd-oomd` enabled | Pressure-based (PSI) kills target the single runaway cgroup. The kernel OOM killer instead picks the largest process, which on a dev box is the editor or a mid-flight agent rather than the thing actually leaking. |

The non-obvious part is the kernel package. The `linux-image-virtual` flavour
that cloud images ship does not include the `zram` module, so `zram-tools`
fails to start with `modprobe: FATAL: Module zram not found`. The fix is
`linux-modules-extra-*`, which is versioned per kernel release — installing
only the running version means the next kernel upgrade silently drops zram
back to swapfile-only. The script installs the `linux-generic` meta-package,
which carries modules-extra forward across upgrades, plus the running kernel's
modules-extra so zram works before the reboot. There is no
`linux-modules-extra-virtual` meta-package to use instead.

This matters most on a machine running parallel agents across git worktrees:
each carries its own language servers, which are ideal swap candidates while
idle, and parallel builds spike hard but briefly. Without swap, any overshoot
became an abrupt OOM kill with no warning window.

## Session persistence

```bash
sudo scripts/provision-persistence.sh
```

Idempotent; re-run it any time (a no-op once linger is already enabled).
Environment override: `TARGET_USER` (defaults to the user that invoked
`sudo`).

Enables `loginctl enable-linger` for the target user, so their systemd
instance — and anything running under it, a detached tmux server included —
survives the last SSH session closing rather than being torn down with it.
Without this, a devbox with no other persistence layers still loses
everything the moment nobody is logged in, even with tmux in front of it: a
detached tmux server has no active login session to hide behind. See
[`persistence.md`](persistence.md) for how this combines with tmux and
tmux-resurrect/continuum into the full model, and why each layer alone is
insufficient.

## User-level toolchain

These run as part of `chezmoi apply` and need no root:

| Script | Installs |
|---|---|
| `run_once_41-install-rg.sh` | ripgrep (hard dependency of rtk) |
| `run_once_42-install-cli-tools.sh` | delta, fd, eza, zoxide, starship, fzf, direnv, nvim, sox (Claude Code voice mode's audio recorder) |
| `run_once_45-install-python-tools.sh` | uv, pipx |
| `run_once_46-install-cloud-clis.sh` | terraform, aws, gcloud, az |
| `run_once_47-install-go.sh` | Go toolchain |

`42` is table-driven across brew, winget, scoop, apt, and cargo, in that order —
prebuilt-binary managers first, cargo last because it compiles from source. The
apt branch is used only when `sudo -n` succeeds, so a machine without
passwordless sudo falls through to the next manager rather than hanging the
apply on a password prompt. Where a Debian package installs a tool under a
different binary name than upstream (`fd-find` ships `fdfind`), the table
carries a `pkg>binary` override and the script symlinks the expected name into
`~/.local/bin`; without that, every apply would see the tool as missing and
reinstall it.

`45` and `46` follow the same no-root rule. uv installs to `~/.local/bin` with
`INSTALLER_NO_MODIFY_PATH=1`, since the shell rc files are chezmoi-managed and
must not be edited by a vendor installer. pipx installs *through* uv: recent
distros mark the system interpreter externally-managed (PEP 668) and refuse
`pip install --user`. The cloud CLIs unpack under `~/.local/opt` with entry
points symlinked into `~/.local/bin`, deliberately avoiding the vendor
installers that would register root-owned apt repositories and signing keys.
`az` is a Python application, so it installs as a uv tool.

`47` exists because the statusline is a Go binary built from
`scripts/claude-status` during an apply: without a toolchain that build is
skipped and Claude Code silently falls back to its default statusline, so Go is
a dependency of this repo rather than a preference. It comes from the upstream
tarball, not a distro package — `go.mod` pins a toolchain that distro packages
trail by a release or more, which would fail the build rather than skip it. The
build script runs in its own process, so it prepends `~/.local/bin` to `PATH`
before probing for `go`; without that it cannot see a toolchain the same apply
just installed.

`46` is skipped on ephemeral machines (see `home/.chezmoiignore`), and both `46`
and `47` are skipped whenever `CI` is set. The ephemeral rule covers machines
initialised with that role; the `CI` rule catches the smoke test, which
deliberately applies with a real machine role into a throwaway `HOME`. The
gcloud tarball alone is a few hundred megabytes, so without it every CI run
would pay for that download. `47` is otherwise enabled for ephemeral machines,
which still render a statusline.

The `CI` skip is an ignore rule rather than only the runtime `[ -z "${CI:-}" ]`
guard the scripts still carry, because chezmoi records a `run_once_` script as
executed whenever it exits 0 — including the exit that reports "skipping". A
machine that ever applied with `CI` set would then never install those tools
again. An ignored script leaves no such state behind. The runtime guards remain
for anyone running a script directly.

## Download integrity

Two of these scripts fetch an archive and put its contents on `PATH`, so both
verify it against the vendor's own digest and refuse an artifact they cannot
check, rather than installing it anyway:

| Artifact | Digest source |
|---|---|
| Go tarball (`47`) | the `sha256` field of the object naming that file in the version index — not the first `sha256` in the document, which belongs to the source archive |
| terraform zip (`46`) | `terraform_<version>_SHA256SUMS` alongside the release |

Go's pinned fallback version carries a pinned digest with it, so a machine that
cannot reach the version index still installs a verified archive. Go earns the
stricter treatment because it lands ahead of the system directories on `PATH`
*and* builds `claude-status`, which Claude Code executes on every statusline
render — a swapped archive there compromises every later build.

Three paths remain unverified, and knowingly so: the uv installer is a
pipe-to-shell, the AWS CLI publishes only a detached GPG signature (which needs
a key imported before it means anything), and `az` comes from PyPI through uv.
All are HTTPS fetches from vendor-controlled hosts, so the exposure is a vendor
or CDN compromise rather than anything a network attacker can reach.

## Testing

All layers are covered by the script unit tests, which run in CI:

```bash
bash tests/scripts/test_provision_swap_script.sh
bash tests/scripts/test_toolchain_scripts.sh
bash tests/scripts/test_provision_persistence_script.sh
bash tests/scripts/test_tmux_plugins_script.sh
```

They shellcheck each script and assert the invariants that are easy to break by
accident: the zram tier outranking the swapfile, `linux-generic` rather than a
version-pinned module package, six fields per row in the tool table, `sudo -n`
on every privileged call, no `cond && action` line continuations (which abort
the whole script under `set -e` whenever the condition is false), the
persistence script's root check running before it enables linger with a
`$SUDO_USER` fallback, and the tmux plugin installer being keyed to
`dot_tmux.conf` changes with resurrect/continuum actually declared and
auto-restore on.
