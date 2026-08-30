#!/usr/bin/env bash
# Every other test here shellchecks the one script it covers, which made
# "has a test" and "gets linted" the same fact: a script shipped without a test
# was also never linted, and neither gap announced itself. This test decouples
# them — it lints every shell file in the repo unconditionally, and separately
# asserts that each machine-mutating script has a test somewhere.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$here"

# Both halves always run: a script added without a test is usually also the one
# that fails lint, and reporting one gap at a time turns that into two round trips.
problems=0
fail() { echo "FAIL: $1"; problems=$((problems + 1)); }

# Sourced rc files declare no shebang and end in no extension, so neither
# discovery rule below can see them. dot_zshrc is deliberately not here — there
# is no zsh dialect to lint it against.
unshebanged_bash=(home/dot_bashrc)

is_bash_file() {
    case "$1" in
        # Go template source: only the rendered output is valid shell, so the
        # render-and-shellcheck belongs in a test, not in the sweep below.
        *.tmpl) return 1 ;;
        *.sh) return 0 ;;
    esac
    head -1 "$1" | LC_ALL=C grep -qE '^#!.*\b(ba)?sh\b'
}

# --others so a brand-new script fails here before it is ever committed, which
# is the whole point; --exclude-standard keeps gitignored scratch files out.
repo_files() { git ls-files --cached --others --exclude-standard; }

lintable() {
    local f
    while IFS= read -r f; do
        if is_bash_file "$f"; then printf '%s\n' "$f"; fi
    done < <(repo_files)
    printf '%s\n' "${unshebanged_bash[@]}"
}

lint_failures=0
while IFS= read -r f; do
    shellcheck -s bash "$f" || lint_failures=$((lint_failures + 1))
done < <(lintable | sort -u)
[ "$lint_failures" = 0 ] ||
    fail "$lint_failures shell file(s) above fail shellcheck -s bash; fix them, or add a scoped '# shellcheck disable=' with the cause"

# A lint pass is not coverage for anything that runs against a real machine, so
# these additionally need a test asserting what they do.
needs_test() {
    repo_files | grep '^home/run_' || true
    lintable | grep '^scripts/' || true
}

# Coverage means "some file under tests/ names this path" rather than "a
# similarly-named test file exists": several tests deliberately cover a group
# of scripts at once (test_toolchain_scripts.sh, test_claude_scripts.sh,
# test_agent_toolchain_scripts.sh), and a name-derived rule would report every
# script in those groups as uncovered.
uncovered=()
while IFS= read -r f; do
    grep -rqF -- "$f" tests/ || uncovered+=("$f")
done < <(needs_test | sort -u)

if [ "${#uncovered[@]}" -gt 0 ]; then
    for f in "${uncovered[@]}"; do
        echo "UNCOVERED: $f — no file under tests/ references this path"
    done
    echo "Add tests/scripts/test_<name>_script.sh asserting what the script does"
    echo "(render it via chez_render first if it is a .tmpl), or extend an"
    echo "existing multi-script test to cover it by its repo-relative path."
    fail "${#uncovered[@]} machine-mutating script(s) have no test"
fi

[ "$problems" = 0 ] || exit 1
echo "PASS"
