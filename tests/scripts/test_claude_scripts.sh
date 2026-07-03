#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
. "$here/tests/lib.sh"
cfg="$(chez_init personal)"
render() { chez_render "$cfg" "$here/$1"; }
mcp="$(render home/run_onchange_30-install-claude-mcp.sh.tmpl)"
echo "$mcp" | shellcheck -s bash -
echo "$mcp" | grep -q 'mcp.atlassian.com' || { echo "FAIL: atlassian url missing"; exit 1; }
plug="$(render home/run_onchange_31-install-claude-plugins.sh.tmpl)"
echo "$plug" | shellcheck -s bash -
echo "$plug" | grep -q 'caveman' || { echo "FAIL: caveman missing"; exit 1; }
echo "PASS"
