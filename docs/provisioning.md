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

## Tailnet access

A first run on an unauthenticated node prints a one-time login URL — an
authorization credential, since whoever opens it attaches this node to a
tailnet. Run it in your own terminal, not an agent's shell tool, which would
persist that URL in a transcript and its logs.

```bash
sudo scripts/provision-tailscale.sh
```

Idempotent; re-run it any time. Environment overrides: `TS_HOSTNAME` (defaults
to `devbox`), plus `OS_RELEASE`, `KEYRING`, `SOURCES` and `BASE_URL`, which
exist so the script's real behaviour can be exercised against stubs without
root.

Installs Tailscale from the vendor apt repo, enables `tailscaled`, and joins
the tailnet as `devbox` with Tailscale SSH on. This is the reach layer for
[`t3code.md`](t3code.md) — an agent harness server that a phone drives over the
tailnet — and it deliberately opens no router port and adds no LAN-facing
bind.

Two things here are less obvious than they look. The re-run check is
capability-based rather than liveness-based: `tailscale status` succeeding only
proves the node is authenticated, not that it carries the pinned hostname and
has SSH enabled, so the script compares the reported MagicDNS name and the
`RunSSH` pref against what it wants and re-runs `tailscale up` with the full
flag set whenever either has drifted. Skipping on liveness alone would leave a
node joined under an inferred hostname — which moves the HTTPS URL out from
under every paired device — and without the SSH break-glass that re-pairing
depends on once a T3 Code session hits its hard 30-day TTL.

The keyring and sources list are also published by atomic rename rather than
streamed into place. `curl >dest` truncates the destination before the body
arrives, so an interrupted transfer would leave partial bytes that still
satisfy the "already present" guard, and apt would then fail GPG verification
on every later run until someone deleted the file by hand.

## User-level toolchain

These run as part of `chezmoi apply` and need no root:

| Script | Installs |
|---|---|
| `run_once_42-install-cli-tools.sh` | ripgrep, delta, fd, eza, zoxide, starship, fzf, direnv, nvim, sox (Claude Code voice mode's audio recorder), cmake |
| `run_onchange_43-install-agent-clis.sh.tmpl` | the CLIs the agent skills drive — version-pinned, see below |
| `run_once_45-install-python-tools.sh` | uv, pipx |
| `run_once_46-install-cloud-clis.sh` | terraform, aws, gcloud, az |
| `run_once_47-install-go.sh` | Go toolchain |
| `run_once_49-install-dev-tools.sh.tmpl` | docker, node/pnpm, rust, helm, gh, kubectl, talosctl, sops, age, Java — opt-in only |

`42` is table-driven across brew, winget, scoop, apt, and cargo, in that order —
prebuilt-binary managers first, cargo last because it compiles from source. The
apt branch is used only when `sudo -n` succeeds, so a machine without
passwordless sudo falls through to the next manager rather than hanging the
apply on a password prompt. Where a Debian package installs a tool under a
different binary name than upstream (`fd-find` ships `fdfind`), the table
carries a `pkg>binary` override and the script symlinks the expected name into
`~/.local/bin`; without that, every apply would see the tool as missing and
reinstall it.

ripgrep sits in that table rather than in a script of its own because it is a
hard dependency of rtk, which shells out to it on every search. As its own
script it knew only brew/winget/scoop/cargo, so an apt-only machine got
`ripgrep requires brew, winget, scoop, or cargo` and rtk then warned on every
call. The cargo branch installs `--locked`: without it cargo re-resolves every
transitive dependency to its newest semver-compatible release, so a crate the
tool never pinned can break a build that succeeds from the tool's own lockfile.
That is exactly how eza failed to compile `palette` on a toolchain where
`--locked` built the same version fine.

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

## Dev tooling catalog

`49` is the layer above `42`: the tooling a machine needs to build and operate
things — Docker, Node via nvm with pnpm through corepack, Rust via rustup, helm,
gh, kubectl, talosctl, sops, age and a JDK. It exists because provisioning a dev
VM otherwise meant installing eleven tools by hand over SSH, one at a time.

It is **opt-in**, gated on an `installDevTooling` prompt answered at `chezmoi
init` time. A personal laptop has no business growing a Docker daemon and a
kubectl because it applied dotfiles. The script is a template
(`run_once_49-install-dev-tools.sh.tmpl`) whose first lines are
`{{ if not .installDevTooling }}exit 0{{ end }}`: chezmoi does not skip a
`run_once_` script's *execution* for an entry matched only by
`.chezmoiignore` (confirmed against a minimal reproduction — the CI skips on
`42`/`46`/`47` are only saved by their own `[ -z "${CI:-}" ]` runtime guard,
the ignore rule never actually kept them from running), so a template guard
baked into the rendered script is what actually stops the install here. `49`
also lists itself in `.chezmoiignore`, same as `42`/`46`/`47` do for `CI` —
that keeps it out of `chezmoi status`/`ignored` run-once bookkeeping so
opting in later still installs, since a `run_once_` script that exited 0 to
say "skipping" is otherwise recorded as having run.

That template guard reads the value with `get` rather than a bare
`.installDevTooling`, because a machine initialised before the prompt existed
has no such key in its persisted config — a direct reference is a hard
template error there, which would break every apply on every older machine
instead of leaving the catalog off. Answering the prompt on an existing
machine means re-running `chezmoi init`.

Like `42` it is a table, but each row also carries an install *kind*, because
these tools do not share one distribution channel:

| Kind | Used by | Why |
|---|---|---|
| `apt` | age, Java | The distro package is current enough and needs no new trust root. |
| `apt-repo` | gh, kubectl | Vendor ships a signed apt repo and the distro package trails it by releases. The key lands in `/etc/apt/keyrings` and the source is pinned to it with `signed-by=`, so no other key on the machine can sign for that repo. |
| `script` | docker, node (nvm), rust (rustup), helm | Vendor publishes only a curl-pipe installer. |
| `binary` | talosctl, sops | A bare release asset, with no packaged repo at all. |

A kind may carry a `+root` suffix (docker, helm) for an installer that elevates
internally, so that fact lives in the row rather than as a tool name hardcoded
in the dispatcher. Everything needing root still goes through `sudo -n` and
skips rather than prompting, so an apply on a machine without passwordless sudo
degrades to a list of skips instead of hanging.

`binary` rows are pinned to a version and verified against the vendor's own
checksum file, refusing anything unverifiable — a release asset has no signed
repository behind it, and talosctl in particular has to match the cluster it
talks to rather than track latest. Go is deliberately *not* in this table: `47`
already owns it from the upstream tarball, and an `apt` row would quietly
reintroduce the older distro toolchain that `go.mod` outruns.

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
again. An ignored script leaves no such state behind. `49` is ignored under `CI`
on the same grounds — a Docker daemon and a cluster CLI are dead weight in a CI
container. The runtime guards remain
for anyone running a script directly.

## Agent CLI versions

`43` installs the CLIs the agent skills drive, from the `agentClis` table in
`home/.chezmoidata.yaml`. Each row declares a `version`, and that declaration
does two jobs: it is the version the script converges the machine to, and —
because it is rendered into the script — it is also what makes the script run
again. Upgrading is a one-line edit to the table, reviewed in a diff like any
other change, rather than a machine-local act nobody else can see.

It guards on *version*, not on presence. The guard used to be `command -v`, so
any installed build read as done and no apply ever advanced a tool again: a
machine sat months behind while the CLI itself printed an upgrade banner on
every invocation. Every row now prints its installed-versus-declared pair
before deciding anything, so a machine that is behind says so even in the cases
where nothing can be done about it automatically.

`run_onchange_` rather than `run_once_`, because of rollbacks. `run_once_` keys
its state on every content hash it has *ever* run, so bumping a pin re-runs but
putting it back does not — the one case where a pin must not be a no-op.
`run_onchange_` keys on the script name and re-runs whenever the contents
differ from the last run, in either direction.

The declared version is then enforced as far as each channel allows, and no
further:

| Kind | Pin | Why |
|---|---|---|
| `npm` | exact, `npm install -g <pkg>@<version>` | the registry addresses versions directly |
| `script` | checked afterwards, not passed in | the vendor ships a curl-pipe installer that resolves its own "latest" and accepts no version input |

That asymmetry is announced rather than hidden: a `script` row re-reads the
tool's version after installing and reports a mismatch against the declared
value, so an installer that overshot the pin is visible instead of quietly
redefining it. Reconciling that means bumping the declared version, which is
again a repo edit. Pinning such a row properly would mean this repo
reimplementing the vendor's installer around a checksummed release asset — the
`binary` shape `49` already uses — which is worth doing only if the vendor
keeps publishing latest-only installers.

Nothing here fails an apply: a missing `curl` or `npm`, a failed install and an
overshoot all print and continue, since `chezmoi apply` runs unattended. An
installer runs only when a tool is absent or its version differs from the
declared one, so a converged machine touches no network and no package manager.

## Download integrity

Two of these scripts fetch an archive and put its contents on `PATH`, so both
verify it against the vendor's own digest and refuse an artifact they cannot
check, rather than installing it anyway:

| Artifact | Digest source |
|---|---|
| Go tarball (`47`) | the `sha256` field of the object naming that file in the version index — not the first `sha256` in the document, which belongs to the source archive |
| terraform zip (`46`) | `terraform_<version>_SHA256SUMS` alongside the release |
| talosctl and sops binaries (`49`) | the checksum file published alongside each pinned release |

Go's pinned fallback version carries a pinned digest with it, so a machine that
cannot reach the version index still installs a verified archive. Go earns the
stricter treatment because it lands ahead of the system directories on `PATH`
*and* builds `claude-status`, which Claude Code executes on every statusline
render — a swapped archive there compromises every later build.

Four paths remain unverified, and knowingly so: the uv installer is a
pipe-to-shell, the AWS CLI publishes only a detached GPG signature (which needs
a key imported before it means anything), `az` comes from PyPI through uv, and
the agent CLI installers in `43` are vendor pipe-to-shell scripts that resolve
their own version. All are HTTPS fetches from vendor-controlled hosts, so the
exposure is a vendor or CDN compromise rather than anything a network attacker
can reach.

## Testing

All layers are covered by the script unit tests, which run in CI:

```bash
bash tests/scripts/test_provision_swap_script.sh
bash tests/scripts/test_toolchain_scripts.sh
bash tests/scripts/test_provision_persistence_script.sh
bash tests/scripts/test_provision_tailscale_script.sh
bash tests/scripts/test_tmux_plugins_script.sh
bash tests/scripts/test_agent_toolchain_scripts.sh
```

They shellcheck each script and assert the invariants that are easy to break by
accident: the zram tier outranking the swapfile, `linux-generic` rather than a
version-pinned module package, six fields per row in the tool table, `sudo -n`
on every privileged call, no `cond && action` line continuations (which abort
the whole script under `set -e` whenever the condition is false), the
persistence script's root check running before it enables linger with a
`$SUDO_USER` fallback, seven fields per row in the dev tooling table with every
apt package *and* every vendor host on a reviewed allowlist and every `binary`
row pinned and checksum-backed, and the tmux plugin installer being keyed to
`dot_tmux.conf` changes with resurrect/continuum actually declared and
auto-restore on.
`tests/scripts/test_shell_script_coverage.sh` keeps that list honest: it
shellchecks every shell file in the repo and fails if a new `scripts/` or
`home/run_*` script has no test referencing it, so a provisioner cannot ship
untested and unlinted the way one silently could before. The two halves are
deliberately asymmetric about templates: a `.sh.tmpl` is skipped by the lint
sweep, because Go template source is not valid shell until chezmoi renders it,
but it is still required to have a test — one that renders it via `chez_render`
and asserts behaviour, which is where its shellcheck coverage comes from.

`tests/scripts/test_agent_toolchain_scripts.sh` covers `43` the same way: it
renders the template and runs it against stub `curl`, `npm` and CLI binaries on
a sealed `PATH`, asserting that an absent tool installs at the declared
version, a tool already at that version invokes no installer at all, a stale
one advances rather than being skipped, and a vendor installer landing past the
declared version is reported. Reading the script's source could not have caught
the bug it exists for — a presence check and a version check look alike until
you run them against a tool that is present but old.

Sealing a test's own `PATH` is not sufficient on its own, though, because every
`chez_apply` caller — two template tests, `tests/smoke.sh` and CI's verify
step — does a full `chezmoi apply` into a throwaway `HOME`, and that runs the
real install scripts. `HOME` does not contain them: `npm install -g` takes its
prefix from the node installation rather than from `HOME`, and a vendor
installer that cannot write its link directory escalates with sudo — on a box
with passwordless sudo that leaves a root-owned symlink in `/usr/local/bin`
pointing into the throwaway `HOME`, which outlives the test and then dangles.
Both escaped that way once the agent CLI installer started converging versions
instead of skipping any tool that was merely present. `chez_apply` now pins
`npm_config_prefix` inside the destination and puts a failing `sudo` ahead of
the real one, which lands every privileged script on the "needs passwordless
sudo — skipping" path it already handles. That covers the npm prefix, the
vendor link directory and anything needing elevation — but not an install
channel that writes a shared prefix without it: where `brew`, `winget` or
`scoop` is on `PATH`, `42`'s CLI-tool installs still reach that prefix, so the
containment is real but partial and a full-apply test on such a machine can
still install into it.

The Tailscale test is the pattern to copy for anything new. Rather than reading
the script's source, it puts stub `id`, `curl`, `apt-get`, `systemctl` and
`tailscale` binaries on a sealed `PATH` and runs the real script against them,
asserting on what the run does: that the root and Ubuntu guards fire before
anything is mutated, that a converged node touches neither apt nor `tailscale
up`, that an authenticated node with SSH off or an inferred hostname is still
converged, and that a truncated keyring download leaves no file behind to
poison the next run. Sealing the `PATH` matters — inheriting the caller's would
let a real `tailscale` on the test machine answer for the stub, and the cases
that matter would silently assert nothing.
