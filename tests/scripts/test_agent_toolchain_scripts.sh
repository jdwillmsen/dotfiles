#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
cfg="$(chez_init personal)"
render() { chez_render "$cfg" "$here/$1"; }

skills="$(render home/run_onchange_33-install-agent-skills.sh.tmpl)"
echo "$skills" | shellcheck -s bash -
for want in kunchenguid/axi kunchenguid/lavish-axi vercel-labs/skills; do
    echo "$skills" | grep -qF "$want" || { echo "FAIL: $want missing from skills script"; exit 1; }
done

# no-mistakes ships its own skill via `no-mistakes init`. Installing it from the
# skills CLI as well is what puts a duplicate on disk, so it must not be listed
# as a source — but it must still be treated as declared, or every reconcile
# reports it as drift.
echo "$skills" | grep -q 'skills add.*no-mistakes' && { echo "FAIL: no-mistakes must not install via the skills CLI"; exit 1; }
echo "$skills" | grep -q 'no-mistakes' || { echo "FAIL: no-mistakes missing from the declared allowlist"; exit 1; }

# Same trap in the other direction: mattpocock arrives via its own plugin
# marketplace (claudePlugins), and listing it here too is what made every one
# of its skills load twice.
echo "$skills" | grep -q 'skills add.*mattpocock' && { echo "FAIL: mattpocock must not be in agentSkills"; exit 1; }

# The CLI resolves global-vs-project from the working directory, so a missing
# cd silently installs into whatever repo the apply ran from.
echo "$skills" | grep -q 'cd "$HOME"' || { echo "FAIL: skills script must cd to \$HOME before installing"; exit 1; }

clis="$(render home/run_once_43-install-agent-clis.sh.tmpl)"
echo "$clis" | shellcheck -s bash -
echo "$clis" | grep -q 'docs/install' || { echo "FAIL: no-mistakes installer url missing"; exit 1; }
echo "$clis" | grep -q 'npm install -g' || { echo "FAIL: gnhf npm install missing"; exit 1; }

# Both scripts run under `set -e`, where a trailing `cond && echo` aborts the
# script whenever the condition is false — silently skipping everything after it.
for s in "$skills" "$clis"; do
    printf '%s\n' "$s" | grep -qE '^[[:space:]]*(command -v|\[ -n).*&&$' &&
        { echo "FAIL: trailing '&&' continuation aborts under set -e"; exit 1; }
done

echo "PASS"
