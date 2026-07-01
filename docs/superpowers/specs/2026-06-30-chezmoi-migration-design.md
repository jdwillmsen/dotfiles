# Chezmoi Migration — Design

Date: 2026-06-30
Status: Approved (design), pending implementation plan
Branch: `feat/chezmoi-migration`

## Summary

Migrate the dotfiles repo from its custom feature-based `install.sh` framework
to [chezmoi](https://www.chezmoi.io/) as the dotfile manager. This is a **full
re-model**: the bespoke installer (`install.sh`, `features/`, `lib/`) is retired
and every concern is expressed the chezmoi-native way — managed files, templates,
`run_` scripts, and age-encrypted secrets.

## Motivation

The current installer is well-built (idempotent, modular, backs up files, CI'd)
but lacks three capabilities that matter as the setup scales across machines:

1. **Secrets** — no encryption strategy; `credential.helper = store` writes git
   credentials in plaintext to `~/.git-credentials`.
2. **Per-host / per-OS divergence** — one config for all machines; no templating.
3. **Cross-platform symlink correctness** — on Windows git-bash, `ln -sf` silently
   *copies* instead of symlinking (verified: `MSYS` unset → 7287-byte regular
   file, not a link). chezmoi renders real files into `$HOME`, eliminating this
   entire class of bug.

chezmoi is the community-standard tool for exactly this profile (multi-machine,
templated, encrypted, one-line bootstrap).

## Target environments

| Target | Detection |
|---|---|
| Linux native | `.chezmoi.os == "linux"` and kernel osrelease lacks `microsoft` |
| WSL | `.chezmoi.kernel.osrelease` contains `microsoft`/`WSL` |
| Windows native | `.chezmoi.os == "windows"` |
| Devcontainer / CI | env `$CI` / `$REMOTE_CONTAINERS` / `$CODESPACES` or `/.dockerenv`, captured into chezmoi data at init |

No macOS target.

## Decisions (locked)

- **Tool:** chezmoi.
- **Migration depth:** full re-model (retire custom installer entirely).
- **Repo layout:** Option A — `.chezmoiroot` subtree. chezmoi source lives under
  `home/`; repo root keeps meta (README, `.github/`, `docs/`), build (`scripts/`),
  and CI outside the `$HOME`-bound tree. Single repo.
- **Secrets:** age at rest, with `pass` (GPG) as the key backend on interactive
  machines and env-var injection on CI. GPG key `80F1...` is the existing root of
  trust — no new trust anchor introduced.
- **Git identity:** role-templated gitconfig. Default = personal
  (`jdwillmsen@gmail.com`, signing key `80F11F099D474F1F`, GPG signing on). A
  work-identity slot is templated and ready to fill; not populated now.

## Architecture

### Repo layout

```
dotfiles/
├── .chezmoiroot                 → "home"
├── README.md  LICENSE  .github/  docs/     (unchanged meta)
├── scripts/claude-status/       Go source (built by a run_ script, not a dotfile)
└── home/                        ← chezmoi source-state root
    ├── .chezmoi.toml.tmpl       init prompts → local config (machineRole, CI flag)
    ├── .chezmoidata.yaml        static data (MCP list, plugin list, tool lists)
    ├── .chezmoiignore           per-target exclusions
    ├── dot_zshrc.tmpl  dot_bashrc.tmpl
    ├── dot_gitconfig.tmpl       role identity; per-OS credential helper
    ├── dot_tmux.conf
    ├── dot_gitignore_global
    ├── dot_config/shell/        aliases.sh exports.sh functions.sh
    ├── private_dot_claude/
    │   ├── CLAUDE.md  commands/  hooks/
    │   └── modify_settings.json.tmpl   deep-merge; existing runtime values win
    ├── private_dot_config/chezmoi/ (age recipient config, non-secret)
    ├── encrypted_private_*.age  age-encrypted secrets (work identity, future tokens)
    └── run_*.sh.tmpl            side-effect scripts (see mapping)
```

### Templating & data model

`.chezmoi.toml.tmpl` prompts once at `chezmoi init`, persisting to the machine's
local chezmoi config (never committed):

- `machineRole` = `personal` | `work` | `ephemeral`
- git identity fields derived from role
- ephemeral/CI flag derived from environment detection

Templating is used **only where values genuinely vary** (YAGNI):

- `dot_gitconfig.tmpl` — identity per role; GPG signing on for personal/work, off
  for ephemeral; `credential.helper` → `libsecret` (Linux) / `manager`
  (WSL→Windows Credential Manager) / disabled (ephemeral). Plaintext `store`
  helper is removed.
- `dot_zshrc.tmpl` / `dot_bashrc.tmpl` — guard OS-specific PATH entries
  (pyenv, sdkman, GOPATH); skip interactive-only setup on CI.
- `.chezmoiignore` — skip `tmux.conf`, GPG, and heavy `run_` scripts on
  ephemeral/CI.

Everything else stays a plain static managed file.

### Runtime-mutated files

`~/.claude/settings.json` is written by Claude Code at runtime, so it cannot be a
plain managed file (chezmoi would clobber runtime edits on `apply`). It maps to
`modify_settings.json.tmpl`: chezmoi feeds the current on-disk file to the script
on stdin; the script emits a deep-merge where **existing runtime values win** and
the repo only fills missing keys — the chezmoi-native equivalent of the current
python merge. `model: fable` is contributed as a default key.

### Secret architecture

One encryption mechanism (age at rest), two key-delivery paths:

- Secrets committed as `encrypted_*.age` in the chezmoi source.
- **age key delivery:**
  - Interactive (Linux/WSL): age key stored in `pass`; chezmoi config template
    pulls it (`{{ pass "chezmoi/age-key" }}`). GPG unlocks `pass`.
  - Ephemeral (CI/devcontainer): age key from env var `CHEZMOI_AGE_KEY`
    (GitHub Actions / Codespaces secret). No GPG/`pass` required.
- Irreducible one-time step per interactive machine: import the GPG key (YubiKey
  or manual) — already required for git signing.

There are no plaintext secrets in the repo today; age infrastructure is
established with a ready slot rather than manufacturing secrets that do not exist.

### Side-effect scripts (feature → run_ mapping)

| Current feature | chezmoi script | Trigger |
|---|---|---|
| `claude-status.sh` (build Go binary) | `run_onchange_after_20-build-claude-status.sh.tmpl` | hash of `main.go` → rebuild on change |
| `claude-mcp.sh` | `run_onchange_30-install-claude-mcp.sh` | on MCP list change |
| `claude-plugins*.sh` | `run_onchange_31-install-claude-plugins.sh` | on plugin list change |
| `claude-rtk.sh` | `run_once_40-install-rtk.sh` | one-time |
| `*skills-personal.sh` | `run_onchange_32-install-skills.sh` | on change |
| `tmux.sh` (TPM) | `run_once_10-install-tpm.sh` | one-time |
| `shell.sh` / `git.sh` / `codex.sh` (pure files) | managed dotfiles | none |

Numeric prefixes give deterministic order (chezmoi runs scripts alphabetically).
`.chezmoiignore` excludes heavy scripts on ephemeral/CI.

## Testing & CI

- `chezmoi execute-template` unit tests for each template.
- `chezmoi apply` into a throwaway `$HOME` in a container; then `chezmoi verify`
  and `chezmoi doctor`.
- shellcheck on `run_*` scripts; gofmt on Go source (retained from current CI).
- CI matrix: ubuntu native + a container simulating the devcontainer/ephemeral
  target.

### Parity gate (critical)

A migration test applies chezmoi into a temp `$HOME` and **diffs the result
against what the current `install.sh` produces**, proving zero regression before
cutover. Cutover does not proceed until this is green.

## Bootstrap

```
sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply jdwillmsen
```

(after the GPG key is present on interactive machines; CI injects
`CHEZMOI_AGE_KEY`).

## Safe cutover

1. Tag current state `pre-chezmoi`.
2. Build the chezmoi source-state alongside the existing installer.
3. Keep `install.sh` until the parity gate is green.
4. Final commit deletes `install.sh`, `features/`, and `lib/`.

## Out of scope

- macOS support.
- Populating actual work-identity credentials or API tokens (slots only).
- Any change to the Go `claude-status` tool's own source beyond its build script.

## Open risks

- age bootstrap chicken-egg is inherent: the GPG key (interactive) or
  `CHEZMOI_AGE_KEY` (CI) must exist before first apply. Documented, not
  eliminable.
- Windows *native* (non-WSL) chezmoi behavior is lower-priority; WSL is the
  primary Windows path.
