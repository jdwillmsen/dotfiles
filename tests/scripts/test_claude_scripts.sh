#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
cfg="$(chez_init personal)"
render() { chez_render "$cfg" "$here/$1"; }
mcp="$(render home/run_onchange_30-install-claude-mcp.sh.tmpl)"
echo "$mcp" | shellcheck -s bash -
echo "$mcp" | grep -q 'mcp.atlassian.com' || { echo "FAIL: atlassian url missing"; exit 1; }

# Regression: a single (or double) quote in an mcp data value must not break
# the generated script. Overlay a temp source tree with a quote-bearing mcp
# value, since the real .chezmoidata.yaml shouldn't be polluted for this.
quote_src="$(mktemp -d)"
cp "$here/.chezmoiroot" "$quote_src/"
cp -r "$here/home" "$quote_src/home"
cat > "$quote_src/home/.chezmoidata.yaml" <<'YAML'
mcp:
  Test:
    command: npx
    args:
      - "it's a test"
      - 'has "double" quotes too'
claudePlugins:
  marketplaces: []
  install: []
YAML
quote_mcp="$(chezmoi execute-template --source "$quote_src" --config "$cfg" < "$quote_src/home/run_onchange_30-install-claude-mcp.sh.tmpl")"
echo "$quote_mcp" | shellcheck -s bash -
echo "$quote_mcp" | grep -qF "it's a test" || { echo "FAIL: single-quote value missing from rendered script"; exit 1; }
bash -n <(echo "$quote_mcp") || { echo "FAIL: script with quoted mcp value fails syntax check"; exit 1; }
rm -rf "$quote_src"

plug="$(render home/run_onchange_31-install-claude-plugins.sh.tmpl)"
echo "$plug" | shellcheck -s bash -
echo "$plug" | grep -q 'caveman' || { echo "FAIL: caveman missing"; exit 1; }
echo "PASS"
