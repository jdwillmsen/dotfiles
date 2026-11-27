#!/usr/bin/env bash
# fleet-update decides which devbox is behind, so its plan, its reading of the
# agentClis table and its probe parsing are pinned against fixtures, and its
# check/apply paths against a stub ssh and a local fixture origin. Nothing here
# reaches a real host.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
cli="$here/home/dot_local/bin/executable_fleet-update"
fx="$here/tests/scripts/fixtures/fleet-update"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$cli" ] || fail "fleet-update missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$cli" || fail "fleet-update does not parse"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ── unit: pure helpers against fixtures ──
python3 -I - "$cli" "$fx" <<'EOF' || fail "unit tests"
import importlib.machinery, importlib.util, sys
cli, fx = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("fleet_update", cli)
spec = importlib.util.spec_from_loader("fleet_update", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)

def eq(got, want, label):
    if got != want:
        print(f"{label}: got {got!r}, want {want!r}")
        sys.exit(1)

# Only agentClis rows count: a `version:` under another top-level key, and
# quoting and trailing comments, must not leak into the table.
clis = m.parse_agent_clis(open(f"{fx}/chezmoidata.yaml").read())
eq(clis, [("no-mistakes", "v1.99.1"), ("codex", "0.170.0"),
          ("cursor-agent", "2026.10.22-27dcf5f")], "parse_agent_clis")
eq(m.parse_agent_clis("other:\n  - name: x\n"), [], "no agentClis table")

probe = m.parse_probe(open(f"{fx}/probe-behind.txt").read())
eq(probe["t3"], "0.1.8", "probe t3")
eq(probe["clis"], {"no-mistakes": "1.97.0", "codex": "0.171.0", "cursor-agent": ""}, "probe clis")

eq(m.compare("1.97.0", "v1.99.1"), "behind", "older is behind")
eq(m.compare("1.111.0", "v1.99.1"), "ahead", "numeric, not lexical")
eq(m.compare("v1.99.1", "1.99.1"), "ok", "v prefix ignored")
eq(m.compare("2026.10.14-941492e", "2026.10.22-27dcf5f"), "behind", "dated build")
eq(m.compare("", "1.0"), "missing", "absent binary")
eq(m.compare("1.0.0-beta", "1.0.0-rc"), "differs", "same numbers, other suffix")
eq(m.compare_sha("a", "b"), "behind", "sha mismatch")

ref = {"dotfiles": "2" * 40, "t3": "0.1.13", "clis": clis}
rows = m.version_rows("devbox2", probe, ref)
eq([(r["item"], r["status"]) for r in rows],
   [("dotfiles", "behind"), ("no-mistakes", "behind"), ("codex", "ahead"),
    ("cursor-agent", "missing"), ("t3", "behind")], "version rows")
eq(m.behind_hosts(rows), ["devbox2"], "behind host")
ahead_only = [dict(r, status="ok") for r in rows]
ahead_only[2]["status"] = "ahead"
eq(m.behind_hosts(ahead_only), [], "ahead alone is not behind")

# The local box runs last, so its t3 restart cannot cut the run short before
# the remote hosts are done.
plan = m.build_plan(["devbox", "devbox2"], "devbox")
eq([(p["host"], p["via"], p["step"]) for p in plan],
   [("devbox2", "ssh", "dotfiles"), ("devbox2", "ssh", "agent-clis"), ("devbox2", "ssh", "t3"),
    ("devbox", "local", "dotfiles"), ("devbox", "local", "agent-clis"), ("devbox", "local", "t3")],
   "plan order")
eq([p["step"] for p in m.build_plan(["devbox2"], "devbox", skip_t3=True)],
   ["dotfiles", "agent-clis"], "--skip-t3")
eq([(p["host"], p["step"]) for p in m.build_plan(["devbox", "devbox2"], "devbox", local_t3_blocked=True)
    if p["step"] == "t3"], [("devbox2", "t3")], "local t3 blocked under T3")
eq(m.toon_value('a,"b"'), '"a,\\"b\\""', "toon quoting")
eq(m.toon_table("x", ["a"], []), ["x: none"], "definitive empty state")
EOF

# ── integration: stub ssh and a local fixture origin ──
origin="$tmp/origin"; src="$tmp/src"; bin="$tmp/bin"; log="$tmp/ssh.log"
mkdir -p "$origin/home" "$bin"
cp "$fx/chezmoidata.yaml" "$origin/home/.chezmoidata.yaml"
git -C "$origin" init -q -b main
git -C "$origin" add -A
git -C "$origin" -c user.email=t@t -c user.name=t commit -q -m data
git clone -q "$origin" "$src"
refsha="$(git -C "$origin" rev-parse HEAD)"

# The probe's PATH preamble and body arrive on stdin; the stub answers a probe
# with the host's fixture and records every other script as an applied step.
cat >"$bin/ssh" <<'EOF'
#!/usr/bin/env bash
host=""
while [ $# -gt 0 ]; do
    case "$1" in -o) shift 2 ;; *) host="$1"; break ;; esac
done
script="$(cat)"
case "$host" in unreachable*) echo "ssh: connect to host $host: timed out" >&2; exit 255 ;; esac
if printf '%s' "$script" | grep -q 'activeVersion'; then
    sed "s/REFSHA/$REFSHA/" "$FIXTURES/probe-$(cat "$STATE_DIR/$host" 2>/dev/null || echo behind).txt"
else
    printf '%s %s\n' "$host" "$(printf '%s' "$script" | tail -n1)" >>"$SSH_LOG"
    echo current >"$STATE_DIR/$host"
fi
EOF
chmod +x "$bin/ssh"
mkdir -p "$tmp/state"

run() {  # args → $out, $rc
    set +e
    out="$(PATH="$bin:$PATH" FIXTURES="$fx" REFSHA="$refsha" SSH_LOG="$log" STATE_DIR="$tmp/state" \
        FLEET_LOCAL_HOST=nothere FLEET_UNDER_T3=0 FLEET_T3_LATEST=0.1.13 \
        python3 "$cli" --source "$src" "$@")"
    rc=$?
    set -e
}

run
[ "$rc" = 0 ] || fail "dry run exit $rc" "$out"
grep -q '^mode: dry-run' <<<"$out" || fail "dry run is the default" "$out"
[ ! -e "$log" ] || fail "dry run reached a host"

run --check --host devbox2
[ "$rc" = 1 ] || fail "behind host must exit 1, got $rc" "$out"
grep -q '^  devbox2,no-mistakes,1.97.0,v1.99.1,behind$' <<<"$out" || fail "behind row" "$out"
grep -q '^summary: 1 of 1 host(s) not current: devbox2$' <<<"$out" || fail "behind summary" "$out"
[ ! -e "$log" ] || fail "--check ran an update step"

run --check --host unreachable1
[ "$rc" = 1 ] || fail "unreachable host must exit 1" "$out"
grep -q '^unreachable\[1\]' <<<"$out" || fail "unreachable table" "$out"

run --apply --host devbox2
[ "$rc" = 0 ] || fail "apply then check should pass, got $rc" "$out"
grep -q '^summary: all 1 host(s) current$' <<<"$out" || fail "post-apply summary" "$out"
[ "$(cut -d' ' -f2- "$log" | sed -n 1p)" = "chezmoi update --no-tty" ] || fail "first step" "$(cat "$log")"
grep -q 'run_onchange_43-install-agent-clis.sh.tmpl' "$log" || fail "agent-clis step" "$(cat "$log")"
grep -q 'npx --yes t3@latest update' "$log" || fail "t3 step" "$(cat "$log")"

run --apply --check
[ "$rc" = 2 ] || fail "conflicting modes must be a usage error, got $rc" "$out"
grep -q '^error:' <<<"$out" || fail "usage error goes to stdout" "$out"

echo "PASS"
