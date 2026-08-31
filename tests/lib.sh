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

# Every temp path a test creates hangs off this one per-run root, so teardown is
# a single sweep and no call site has to remember to register anything. mktemp
# makes it unique per run, which is also what makes the process sweep below safe
# to run while other test runs are in flight on the same machine.
CHEZ_TMP_ROOT="$(mktemp -d)"; export CHEZ_TMP_ROOT

# RUNNER_TEMP must be a path both bash (writing the key, via run_before) and
# the native Windows chezmoi.exe (reading it) resolve to the same location.
# Plain "/tmp" diverges: bash's MSYS mount vs. chezmoi.exe's literal C:\tmp.
# The local fallback nests under CHEZ_TMP_ROOT so the *decrypted* age identity
# run_before writes there is swept with everything else instead of being left
# in system temp. On CI the runner presets RUNNER_TEMP, so this does not fire.
: "${RUNNER_TEMP:=$(cygpath -w "$(mktemp -d "$CHEZ_TMP_ROOT/runner.XXXXXXXX")" 2>/dev/null || mktemp -d "$CHEZ_TMP_ROOT/runner.XXXXXXXX")}"; export RUNNER_TEMP
CHEZ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# pids of every process whose command line mentions the run's temp root.
# ps rather than pgrep -f: pgrep is not installed everywhere, and its own argv
# would then have to be excluded from its own match.
chez_pids_under() {
    ps -eo pid=,args= 2>/dev/null | while read -r pid args; do
        case "$args" in *"$1"*) printf '%s\n' "$pid" ;; esac
    done
}

# A full apply does not only place files. run_once_43 pipes the agent-CLI vendor
# installer to sh, and that installer ends by starting a no-mistakes daemon
# rooted at whatever HOME it installed into. Under a sandbox HOME the daemon's
# systemd unit is written to $HOME/.config/systemd/user, which the already
# running `systemd --user` never scans — its unit search path was fixed from the
# real home when the session started — so `systemctl --user enable` fails and the
# binary falls back to a detached process that reparents to init. Unlinking the
# tree without stopping that process would only turn a leaked daemon into a
# leaked daemon writing to deleted files, so the sweep always stops first.
chez_reap() {
    local sig pids deadline
    for sig in TERM KILL; do
        pids="$(chez_pids_under "$CHEZ_TMP_ROOT")"
        [ -n "$pids" ] || return 0
        # TERM first so the daemon closes its SQLite WAL; KILL only escalates
        # for whatever ignored it.
        # shellcheck disable=SC2086  # word splitting is the point: pids is a list
        kill -"$sig" $pids 2>/dev/null || true
        deadline=$((SECONDS + 15))
        while [ -n "$(chez_pids_under "$CHEZ_TMP_ROOT")" ] && [ "$SECONDS" -lt "$deadline" ]; do
            sleep 0.2
        done
    done
    pids="$(chez_pids_under "$CHEZ_TMP_ROOT")"
    [ -z "$pids" ] || echo "WARN: processes survived cleanup under $CHEZ_TMP_ROOT: $pids" >&2
}

chez_teardown() {
    local rc=$?
    [ -n "${CHEZ_TMP_ROOT:-}" ] || return "$rc"
    chez_reap || true
    rm -rf -- "$CHEZ_TMP_ROOT" || true
    return "$rc"
}

# EXIT alone is not enough: bash does not run it when the shell dies on a signal
# it has not trapped, so an interrupted run would keep both the tree and the
# daemon. Each signal trap sweeps, then re-raises so callers still observe a
# signal death rather than a clean exit.
trap chez_teardown EXIT
trap 'chez_teardown; trap - INT; kill -INT $$' INT
trap 'chez_teardown; trap - TERM; kill -TERM $$' TERM
trap 'chez_teardown; trap - HUP; kill -HUP $$' HUP

# chez_sandbox — print a fresh throwaway HOME inside the run's temp root.
# The name is kept short on purpose: an apply starts a daemon that binds a unix
# socket at $HOME/.no-mistakes/socket, and sun_path caps the whole path near 108
# bytes — a longer sandbox path fails the bind instead of the test.
chez_sandbox() { mktemp -d "$CHEZ_TMP_ROOT/home.XXXXXXXX"; }

# Full-apply tests need a real age identity (encrypted files abort apply otherwise).
chez_require_key() {
    [ "$CHEZ_HAS_KEY" = 1 ] && return 0
    echo "SKIP: no age identity — set CHEZMOI_AGE_KEY or create ~/.config/chezmoi/key.txt (see docs/secrets.md)"
    exit 0
}

# chez_init [role] [installDevTooling] — prints path to a config rendered for
# that role. CI-detection env vars are stripped so results are deterministic
# everywhere. Every prompt the config template declares must be answered here:
# an unanswered one under --no-tty aborts init rather than taking its default.
chez_init() {
    local tmp; tmp="$(mktemp -d "$CHEZ_TMP_ROOT/init.XXXXXXXX")"
    env -u CI -u REMOTE_CONTAINERS -u CODESPACES chezmoi init \
        --source "$CHEZ_SRC" --destination "$tmp/dest" \
        --config "$tmp/chezmoi.toml" \
        --promptString "machineRole=${1:-personal}" \
        --promptBool "installDevTooling=${2:-false}" --no-tty >/dev/null
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
#
# NO_MISTAKES_LINK_DIR is pinned because the agent-CLI vendor installer picks
# its link directory from $PATH: it only uses $HOME/.local/bin when that exact
# path is already on PATH, which a sandbox HOME never is, and otherwise falls
# through to `sudo ln -s /usr/local/bin/no-mistakes` — a root-owned symlink on
# the real machine pointing at a sandbox that is about to be deleted.
chez_apply() {
    HOME="$2" NO_MISTAKES_LINK_DIR="$2/.local/bin" \
        chezmoi apply --source "$CHEZ_SRC" --config "$1" --destination "$2" --force
}

# chez_verify CONFIG DEST — verify DEST with the same HOME override as
# chez_apply. On Linux .chezmoi.homeDir follows $HOME, and templates may
# embed it in file *content*, so verify must render in the same context apply did —
# otherwise every homeDir-embedding file reports drift against the sandbox.
# --exclude=scripts: always-run scripts (no run_once_ state) would report as
# pending "new file" regardless of destination state; tests/scripts/*.sh
# cover the scripts themselves.
chez_verify() { HOME="$2" chezmoi verify --source "$CHEZ_SRC" --config "$1" --destination "$2" --exclude=scripts; }
