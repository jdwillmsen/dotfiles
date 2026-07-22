# tests/lib.sh — shared chezmoi test harness (sourced, not executed)
# chezmoi's `execute-template --init` does not load .chezmoi.toml.tmpl's
# [data], and --promptString keys on the prompt text, not the data path.
# So tests do a real two-phase init into a sandbox: render the config once,
# then execute templates against that config.
#
# CHEZMOI_AGE_KEY needs to be a *working* age identity, not just a non-empty
# string: a full apply decrypts encrypted_ source files (e.g. work-identity),
# and chezmoi aborts the whole apply on the first decrypt failure — so an
# invalid key here would fail every full-apply test, not just crypto-specific
# ones. Prefer the real local dev identity (never committed) when present;
# fall back to a placeholder for CI/other machines, where CHEZMOI_AGE_KEY is
# expected to already be set to the real secret by the environment.
CHEZ_HAS_KEY=1
if [ -z "${CHEZMOI_AGE_KEY:-}" ]; then
    CHEZMOI_AGE_KEY="$(cat "$HOME/.config/chezmoi/key.txt" 2>/dev/null)" || CHEZ_HAS_KEY=0
    [ -n "$CHEZMOI_AGE_KEY" ] || { CHEZMOI_AGE_KEY=dummy; CHEZ_HAS_KEY=0; }
fi
export CHEZMOI_AGE_KEY CHEZ_HAS_KEY
# RUNNER_TEMP must be a path both bash (writing the key, via run_before) and
# the native Windows chezmoi.exe (reading it) resolve to the same location.
# Plain "/tmp" diverges: bash's MSYS mount vs. chezmoi.exe's literal C:\tmp.
: "${RUNNER_TEMP:=$(cygpath -w "$(mktemp -d)" 2>/dev/null || mktemp -d)}"; export RUNNER_TEMP
CHEZ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Full-apply tests need a real age identity (encrypted files abort apply otherwise).
chez_require_key() {
    [ "$CHEZ_HAS_KEY" = 1 ] && return 0
    echo "SKIP: no age identity — set CHEZMOI_AGE_KEY or create ~/.config/chezmoi/key.txt (see docs/secrets.md)"
    exit 0
}

# chez_init [role] — prints path to a config rendered for that role.
# CI-detection env vars are stripped so results are deterministic everywhere.
chez_init() {
    local tmp; tmp="$(mktemp -d)"
    env -u CI -u REMOTE_CONTAINERS -u CODESPACES chezmoi init \
        --source "$CHEZ_SRC" --destination "$tmp/dest" \
        --config "$tmp/chezmoi.toml" \
        --promptString "machineRole=${1:-personal}" --no-tty >/dev/null
    echo "$tmp/chezmoi.toml"
}

# chez_tmpl CONFIG 'TEMPLATE' — render an inline probe template.
chez_tmpl() { chezmoi execute-template --source "$CHEZ_SRC" --config "$1" "$2"; }

# chez_render CONFIG FILE — render a source template file via stdin.
chez_render() { chezmoi execute-template --source "$CHEZ_SRC" --config "$1" < "$2"; }

# chez_apply CONFIG DEST — apply the full source state into DEST.
# HOME is overridden to DEST for the apply itself: run_once/run_onchange
# scripts read $HOME directly (e.g. ~/.local/bin, ~/.claude, ~/.tmux), so
# --destination alone still lets them write into the real home directory.
# RUNNER_TEMP is deliberately left untouched: CONFIG's [age].identity was
# already resolved to an absolute path under RUNNER_TEMP's *current* value
# back when chez_init rendered it, and run_before_00-write-ci-age-key.sh
# writes the decrypted key to that same RUNNER_TEMP-derived path during this
# apply — repointing RUNNER_TEMP here would desync the two and break
# decryption. RUNNER_TEMP already lives outside $HOME (system temp), so it
# poses none of the leak risk HOME does.
chez_apply() { HOME="$2" chezmoi apply --source "$CHEZ_SRC" --config "$1" --destination "$2" --force; }

# chez_verify CONFIG DEST — verify DEST with the same HOME override as
# chez_apply. On Linux .chezmoi.homeDir follows $HOME, and templates may
# embed it in file *content* (e.g. dot_claude-code-router/config.json.tmpl's
# transformer path), so verify must render in the same context apply did —
# otherwise every homeDir-embedding file reports drift against the sandbox.
# --exclude=scripts: always-run scripts (no run_once_ state) would report as
# pending "new file" regardless of destination state; tests/scripts/*.sh
# cover the scripts themselves.
chez_verify() { HOME="$2" chezmoi verify --source "$CHEZ_SRC" --config "$1" --destination "$2" --exclude=scripts; }
