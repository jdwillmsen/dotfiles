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

## User-level toolchain

These run as part of `chezmoi apply` and need no root:

| Script | Installs |
|---|---|
| `run_once_41-install-rg.sh` | ripgrep (hard dependency of rtk) |
| `run_once_42-install-cli-tools.sh` | delta, fd, eza, zoxide, starship, fzf, direnv, nvim |
| `run_once_45-install-python-tools.sh` | uv, pipx |
| `run_once_46-install-cloud-clis.sh` | terraform, aws, gcloud, az |

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

`46` is skipped on ephemeral machines (see `home/.chezmoiignore`) and again at
runtime whenever `CI` is set. Both are needed: the ignore rule covers machines
initialised with the ephemeral role, while the runtime check catches the smoke
test, which deliberately applies with a real machine role into a throwaway
`HOME`. The gcloud tarball alone is a few hundred megabytes, so without the
second guard every CI run would pay for it.

## Testing

Both layers are covered by the script unit tests, which run in CI:

```bash
bash tests/scripts/test_provision_swap_script.sh
bash tests/scripts/test_toolchain_scripts.sh
```

They shellcheck each script and assert the invariants that are easy to break by
accident: the zram tier outranking the swapfile, `linux-generic` rather than a
version-pinned module package, six fields per row in the tool table, `sudo -n`
on every privileged call, and no `cond && action` line continuations, which
abort the whole script under `set -e` whenever the condition is false.
