#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
cfg="$(chez_init personal)"
render() { chez_render "$cfg" "$here/$1"; }
mcp="$(render home/run_onchange_30-install-claude-mcp.sh.tmpl)"
echo "$mcp" | shellcheck -s bash -
# Atlassian and playwright are both marketplace plugins now, not hand-rolled
# mcp-remote/npx shims. Both paths would register the same tools, so a shim
# coming back would double-load them rather than fail loudly.
echo "$mcp" | grep -q 'mcp.atlassian.com' && { echo "FAIL: atlassian mcp-remote shim is back in .chezmoidata.yaml"; exit 1; }
echo "$mcp" | grep -q '@playwright/mcp' && { echo "FAIL: playwright npx shim is back in .chezmoidata.yaml"; exit 1; }

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

plugin_script="$here/home/run_onchange_before_31-install-claude-plugins.sh.tmpl"
plug="$(chez_render "$cfg" "$plugin_script")"
echo "$plug" | shellcheck -s bash -
echo "$plug" | grep -q 'caveman' || { echo "FAIL: caveman missing"; exit 1; }
echo "$plug" | grep -q 'mattpocock/skills' || { echo "FAIL: mattpocock/skills missing"; exit 1; }
# The other half of the move: Atlassian has to be installed from somewhere, and
# a plugin id is inert without the marketplace that serves it.
echo "$plug" | grep -q 'anthropics/claude-plugins-official' || { echo "FAIL: official plugin marketplace missing"; exit 1; }
echo "$plug" | grep -q 'atlassian@claude-plugins-official' || { echo "FAIL: atlassian plugin not installed"; exit 1; }
echo "$plug" | grep -q 'playwright@claude-plugins-official' || { echo "FAIL: playwright plugin not installed"; exit 1; }

# A fresh apply must end with the template's forced-off plugins disabled.
# `claude plugin install` enables what it installs, so the install script has
# to run before the settings modify, not merely somewhere in the same apply.
# Applied for real from a two-file source with a fake claude that records
# installs the way the real one does, because the ordering is chezmoi's and
# only an apply exercises it.
order_src="$(mktemp -d "$CHEZ_TMP_ROOT/order.XXXXXXXX")"
order_home="$(chez_sandbox)"
fake_bin="$(mktemp -d "$CHEZ_TMP_ROOT/bin.XXXXXXXX")"
mkdir -p "$order_src/private_dot_claude"
cp "$plugin_script" "$order_src/"
cp "$here/home/private_dot_claude/modify_settings.json.json.tmpl" "$order_src/private_dot_claude/"
cat > "$order_src/.chezmoidata.yaml" <<'YAML'
claudePlugins:
  marketplaces: []
  install:
    - ralph-loop@claude-plugins-official
    - superpowers@claude-plugins-official
YAML
cat > "$fake_bin/claude" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "plugin install" ] || exit 0
f="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
python3 -c 'import json,os,sys
f=sys.argv[1]
d=json.load(open(f)) if os.path.exists(f) else {}
d.setdefault("enabledPlugins",{})[sys.argv[2]]=True
json.dump(d,open(f,"w"))' "$f" "$3"
SH
chmod 755 "$fake_bin/claude"
HOME="$order_home" PATH="$fake_bin:$PATH" chezmoi apply --source "$order_src" \
    --config "$cfg" --destination "$order_home" --force >/dev/null
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["enabledPlugins"]; \
 assert p["ralph-loop@claude-plugins-official"] is False, "forced-off plugin left enabled after a fresh apply"; \
 assert p["superpowers@claude-plugins-official"] is True, "unforced plugin not installed"' \
    "$order_home/.claude/settings.json"

skills_dir="$(render home/run_onchange_32-install-claude-skills-dir.sh.tmpl)"
echo "$skills_dir" | shellcheck -s bash -
echo "PASS"
