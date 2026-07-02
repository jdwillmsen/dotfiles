# tests/lib.sh — shared chezmoi test harness (sourced, not executed)
# chezmoi's `execute-template --init` does not load .chezmoi.toml.tmpl's
# [data], and --promptString keys on the prompt text, not the data path.
# So tests do a real two-phase init into a sandbox: render the config once,
# then execute templates against that config.
: "${CHEZMOI_AGE_KEY:=dummy}"; export CHEZMOI_AGE_KEY
CHEZ_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
chez_apply() { chezmoi apply --source "$CHEZ_SRC" --config "$1" --destination "$2" --force; }
