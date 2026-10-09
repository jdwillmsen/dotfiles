#!/usr/bin/env bash
# shellcheck disable=SC2015  # `A && B || fail`: fail exits, so it never runs after a true B
# stream decides which Jira project and worktree namespace every other helper
# uses, so its resolution rules are pinned here against real git repos, and its
# GitHub view against a stub gh.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
stream="$here/home/dot_local/bin/executable_stream"
map="$here/home/dot_config/streams.json"
trigger="$here/home/run_onchange_after_56-generate-claude-jira.sh.tmpl"

fail() {
    echo "FAIL: $1"
    if [ $# -gt 1 ]; then echo "$2"; fi
    exit 1
}

[ -x "$stream" ] || fail "stream missing or not executable"
python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$stream" || fail "stream does not parse"
python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$map" || fail "streams.json is not JSON"

# The harness owns teardown: its EXIT trap sweeps CHEZ_TMP_ROOT, and a second
# trap here would replace it and leak the rendered-config sandbox.
# shellcheck disable=SC1091  # dynamic path resolved at runtime; harness lives at tests/lib.sh
. "$here/tests/lib.sh"
tmp="$(mktemp -d "$CHEZ_TMP_ROOT/stream.XXXXXXXX")"
fx="$tmp/home"
stubs="$tmp/bin"
mkdir -p "$fx/.config" "$stubs" "$tmp/repos"
cp "$map" "$fx/.config/streams.json"

mkrepo() {  # $1 name, $2 optional origin url
    git init -q "$tmp/repos/$1"
    git -C "$tmp/repos/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    [ -z "${2:-}" ] || git -C "$tmp/repos/$1" remote add origin "$2"
}
run() {  # args → sets $out, $rc; runs in $cwd
    set +e
    out="$(cd "${cwd:-$tmp}" && HOME="$fx" PATH="$stubs:/usr/bin:/bin" STUB_LOG="$tmp/log" \
        STUB_GH="${STUB_GH:-ok}" python3 "$stream" "$@" 2>"$tmp/stderr")"
    rc=$?
    set -e
}
expect() {  # $1 expected stdout, $2 label
    [ "$rc" -eq 0 ] && [ "$out" = "$1" ] || fail "$2: expected '$1', got rc=$rc '$out'" "$(cat "$tmp/stderr")"
}

# ── slug: every remote URL shape yields owner/repo ──
mkrepo platform git@github.com:jdwlabs/platform.git
mkrepo gameops https://github.com/jdwillmsen/gameops
mkrepo career https://github.com/jdwillmsen/career.git/
mkrepo dota ssh://git@github.com:22/dotablaze-tech/platform.git
mkrepo fork git@github.com:kunchenguid/no-mistakes.git
mkrepo orphan

cwd="$tmp/repos/platform" run slug;  expect "jdwlabs/platform" "ssh shorthand remote"
cwd="$tmp/repos/gameops" run slug;   expect "jdwillmsen/gameops" "https remote without .git"
cwd="$tmp/repos/career" run slug;    expect "jdwillmsen/career" "https remote with .git and trailing slash"
cwd="$tmp/repos/dota" run slug;      expect "dotablaze-tech/platform" "ssh:// remote with a port"
cwd="$tmp/repos/orphan" run slug;    expect "orphan" "no remote falls back to the basename"
run slug "$tmp/repos/platform";      expect "jdwlabs/platform" "slug takes a path argument"

# A linked worktree's own folder name must not leak into the slug.
git -C "$tmp/repos/platform" worktree add -q -b feat/x "$tmp/elsewhere" >/dev/null 2>&1
cwd="$tmp/elsewhere" run slug;       expect "jdwlabs/platform" "slug from inside a linked worktree"

# stream.owner is the explicit exception for a fork whose origin is upstream.
git -C "$tmp/repos/fork" config stream.owner jdwillmsen
cwd="$tmp/repos/fork" run slug;      expect "jdwillmsen/no-mistakes" "stream.owner overrides the remote owner"
git -C "$tmp/repos/orphan" config stream.owner jdwillmsen
cwd="$tmp/repos/orphan" run slug;    expect "jdwillmsen/orphan" "stream.owner applies with no remote"
git -C "$tmp/repos/orphan" config --unset stream.owner

# The slug becomes a directory under the worktree base, so a segment that could
# climb out of it is never used.
mkrepo climber git@github.com:../../escaped.git
cwd="$tmp/repos/climber" run slug;   expect "climber" "a remote with .. segments falls back to the basename"
git -C "$tmp/repos/platform" config stream.owner ../..
cwd="$tmp/repos/platform" run slug;  expect "jdwlabs/platform" "a stream.owner with .. is ignored"
git -C "$tmp/repos/platform" config stream.owner a/b
cwd="$tmp/repos/platform" run slug;  expect "jdwlabs/platform" "a stream.owner with a slash is ignored"
git -C "$tmp/repos/platform" config --unset stream.owner

# GitHub logins are case-insensitive, so the map lookup must be too.
mkrepo cased https://github.com/JDWLabs/Platform.git
cwd="$tmp/repos/cased" run key;      expect "JDWLABS" "owner lookup ignores case"

cwd="$tmp" run slug
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "slug outside a repo must be a structured error" "$out"

# ── key: owner picks the project, repoOverrides wins ──
cwd="$tmp/repos/platform" run key;   expect "JDWLABS" "jdwlabs key"
cwd="$tmp/repos/gameops" run key;    expect "JDW" "jdwillmsen key"
cwd="$tmp/repos/career" run key;     expect "CAREER" "career override"
cwd="$tmp/repos/dota" run key;       expect "DOTA" "dotablaze-tech key"
cwd="$tmp/repos/fork" run key;       expect "JDW" "overridden owner picks its stream"
cwd="$tmp/repos/orphan" run key
[ "$rc" -eq 1 ] && grep -q '^error: .*not a known stream' <<<"$out" || fail "an ownerless repo must not guess a project" "$out"
grep -q '^help\[' <<<"$out" || fail "unknown-stream error should say what to do next" "$out"

# ── no args: live content, not help text ──
run
[ "$rc" -eq 0 ] || fail "bare stream should exit 0" "$out"
grep -q '^streams\[3\]{stream,jira,overrides}:' <<<"$out" || fail "bare stream should list the three streams" "$out"
grep -q 'jdwillmsen,JDW,career=CAREER' <<<"$out" || fail "bare stream should show overrides" "$out"
grep -q '^  jdwlabs,JDWLABS,none$' <<<"$out" || fail "a stream with no overrides should say none" "$out"
grep -q '^help\[' <<<"$out" || fail "bare stream should offer next steps" "$out"
cwd="$tmp/repos/gameops" run
grep -q '^here: jdwillmsen/gameops' <<<"$out" && grep -q '^here_jira: JDW' <<<"$out" \
    || fail "bare stream inside a repo should say where it is" "$out"

for sub in "" slug key jira-config status; do
    # shellcheck disable=SC2086  # an empty $sub must vanish, not become an empty argument
    run $sub --help
    [ "$rc" -eq 0 ] && grep -qi 'usage' <<<"$out" || fail "'stream $sub --help' should print usage" "$out"
done
run --version
[ "$rc" -eq 0 ] && [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--version should print a bare version" "$out"
run bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown command' <<<"$out" || fail "unknown command must be a usage error" "$out"
run key --bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown flag --bogus' <<<"$out" || fail "unknown flags must be rejected, not treated as a path" "$out"
run jira-config --bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown flag --bogus' <<<"$out" || fail "jira-config must reject unknown flags" "$out"

# ── a missing or broken map is an error, never an empty answer ──
mv "$fx/.config/streams.json" "$tmp/streams.bak"
cwd="$tmp/repos/platform" run key
[ "$rc" -eq 1 ] && grep -q '^error: .*streams.json' <<<"$out" || fail "missing map must be a structured error" "$out"
echo '{"streams": {"x": {"jira": "lower"}}}' >"$fx/.config/streams.json"
run
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "an invalid key in the map must be rejected" "$out"
# Owners are sent to GitHub as search terms and arguments, so only a login shape is accepted.
echo '{"jiraSite": "https://x.example", "streams": {"--web": {"jira": "ABC"}}}' >"$fx/.config/streams.json"
run
[ "$rc" -eq 1 ] && grep -q '^error: .*invalid owner' <<<"$out" || fail "an owner that is not a login must be rejected" "$out"
echo '{"jiraSite": "https://x.example", "streams": {"ok": {"jira": "ABC", "repoOverrides": ["a"]}}}' >"$fx/.config/streams.json"
run
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "a malformed repoOverrides must be a structured error, not a traceback" "$out$(cat "$tmp/stderr")"
cp "$tmp/streams.bak" "$fx/.config/streams.json"

# ── jira-config: generated allowlist for cj and the statusline ──
cfg="$fx/.config/claude-jira.json"
run jira-config
[ "$rc" -eq 0 ] || fail "jira-config should exit 0" "$out"
python3 - "$out" <<'PY' || fail "jira-config printed the wrong document" "$out"
import json, sys
j = json.loads(sys.argv[1])
assert j["siteBase"] == "https://jdwillmsen.atlassian.net", j
assert j["projects"] == ["CAREER", "DOTA", "JDW", "JDWLABS"], j
assert j["generatedFrom"] == "streams.json", j
PY
[ ! -e "$cfg" ] || fail "jira-config without --write must not create the file"
run jira-config --write
[ "$rc" -eq 0 ] && grep -q '^status: written' <<<"$out" && [ -f "$cfg" ] || fail "--write should create the file" "$out"
run jira-config --write
grep -q '^status: unchanged' <<<"$out" || fail "a second --write should be a no-op" "$out"

# A config someone wrote by hand names an employer's site; it is not ours to replace.
echo '{"siteBase": "https://work.example.net", "projects": ["ABC"]}' >"$cfg"
run jira-config --write
[ "$rc" -eq 0 ] && grep -q '^status: kept' <<<"$out" || fail "a hand-written config must be kept" "$out"
grep -q 'work.example.net' "$cfg" || fail "a hand-written config was overwritten"
grep -q 'stream jira-config --write' <<<"$out" || fail "the kept message should name the command that regenerates the file" "$out"
rm -f "$cfg"
# Anything unexpected still reaches the caller as a structured error on stdout.
chmod 500 "$fx/.config"
run jira-config --write
chmod 700 "$fx/.config"
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "an unwritable config dir must be a structured error" "$out$(cat "$tmp/stderr")"

# ── status: GitHub's view of one stream, against a stub gh ──
cat >"$stubs/gh" <<'STUB'
#!/usr/bin/env python3
# Modes: ok (fixture), fail (every call errors), many (more PRs than one page),
# full (an alerts page comes back full).
import json, os, re, sys
args = sys.argv[1:]
open(os.environ["STUB_LOG"], "a").write(" ".join(args) + "\n")
mode = os.environ.get("STUB_GH", "ok")
if mode == "fail":
    sys.stderr.write("HTTP 401: Bad credentials\n"); sys.exit(1)
def pr(repo, n, title, state, decision="REVIEW_REQUIRED"):
    return {"number": n, "title": title, "url": f"https://github.com/x/{repo}/pull/{n}",
            "reviewDecision": decision, "repository": {"name": repo},
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": state} if state else None}}]}}
if args[:2] == ["api", "graphql"]:
    owner = re.search(r"open=.*user:(\S+)", " ".join(args)).group(1)
    nodes = {"jdwlabs": [pr("platform", 7, "feat: a, b", "SUCCESS"), pr("apps", 9, "1e5", "FAILURE", "APPROVED"),
                         pr("apps", 11, "x" * 90, None)],
             "jdwillmsen": [pr("gameops", 3, "-lead", "PENDING")]}.get(owner, [])
    mine = [n for n in nodes if n["number"] == 7]
    count = 250 if mode == "many" else len(nodes)
    print(json.dumps({"data": {"open": {"issueCount": count, "nodes": nodes}, "mine": {"nodes": mine}}}))
    sys.exit(0)
if args[:2] == ["repo", "list"]:
    print(json.dumps({"jdwlabs": ["apps", "platform"], "jdwillmsen": ["gameops"]}.get(args[2], [])))
    sys.exit(0)
if args[0] == "api":
    path = next(a for a in args if a.startswith("repos/"))
    if path == "repos/jdwlabs/apps/dependabot/alerts": print(100 if mode == "full" else 3); sys.exit(0)
    if path == "repos/jdwlabs/apps/code-scanning/alerts": print(0); sys.exit(0)
    if path == "repos/jdwlabs/platform/dependabot/alerts": print(0); sys.exit(0)
    sys.stderr.write("HTTP 404: Not Found\n"); sys.exit(1)
sys.exit(1)
STUB
chmod +x "$stubs/gh"

run status jdwlabs
[ "$rc" -eq 0 ] || fail "status jdwlabs should exit 0" "$out$(cat "$tmp/stderr")"
grep -q '^summary: "3 open, 1 awaiting your review, 1 failing"' <<<"$out" || fail "status summary wrong" "$out"
grep -q '^pull_requests\[3\]{repo,number,checks,review,title}:' <<<"$out" || fail "PR table header wrong" "$out"
grep -q '^  platform,7,passing,requested,"feat: a, b"$' <<<"$out" || fail "review-requested PR row wrong" "$out"
# A bare 1e5 or a leading hyphen would be read back as a number or a list item.
grep -q '^  apps,9,failing,approved,"1e5"$' <<<"$out" || fail "a number-shaped title must be quoted" "$out"
grep -q '^  apps,11,none,' <<<"$out" || fail "a PR with no checks should read 'none'" "$out"
grep -q 'x\{57\}…' <<<"$out" || fail "long titles should be clipped" "$out"
grep -q '^alerts\[1\]{repo,dependabot,code_scanning}:' <<<"$out" && grep -q '^  apps,3,0$' <<<"$out" \
    || fail "alert table should list only repos with open alerts" "$out"
# platform's code-scanning endpoint 404s: that is unmeasured, not zero.
grep -q '^alerts_unmeasured: 1 of 2 repos' <<<"$out" || fail "an unreadable alerts endpoint must be reported" "$out"
grep -q '^help\[' <<<"$out" || fail "status should offer next steps" "$out"
grep -q 'user:jdwlabs' "$tmp/log" || fail "PR search not scoped to the owner"
grep -q 'jdwillmsen' <<<"$out" && fail "status jdwlabs leaked another stream" "$out"

run status jdwlabs --no-alerts
[ "$rc" -eq 0 ] && grep -q '^summary: ' <<<"$out" || fail "--no-alerts should still report PRs" "$out"
grep -q '^alerts' <<<"$out" && fail "--no-alerts should skip alerts" "$out"

run status jdwillmsen --no-alerts
grep -q '^  gameops,3,pending,needed,"-lead"$' <<<"$out" || fail "a title starting with a hyphen must be quoted" "$out"

run status dotablaze-tech
[ "$rc" -eq 0 ] && grep -q '^pull_requests: 0 open' <<<"$out" && grep -q '^alerts: 0 open across 0 repos' <<<"$out" \
    || fail "an empty stream must say so explicitly" "$out"

run status
[ "$rc" -eq 0 ] || fail "status should exit 0" "$out"
grep -q '^streams\[3\]{stream,jira,open_prs,review_requested,failing,alerts,alerts_unmeasured}:' <<<"$out" \
    || fail "overview header wrong" "$out"
grep -q '^  jdwlabs,JDWLABS,3,1,1,3,1 of 2 repos$' <<<"$out" || fail "jdwlabs overview row wrong" "$out"
# gameops's alert endpoints both 404: the overview must say unmeasured, not a clean zero.
grep -q '^  jdwillmsen,JDW,1,0,0,0,1 of 1 repos$' <<<"$out" || fail "unreadable alerts must not read as zero" "$out"
grep -q '^  dotablaze-tech,DOTA,0,0,0,0,0 of 0 repos$' <<<"$out" || fail "empty stream overview row wrong" "$out"

# A full page means "at least this many", never exactly this many.
STUB_GH=full run status jdwlabs
grep -q '^  apps,100+,0$' <<<"$out" || fail "a full alerts page must read 100+" "$out"
STUB_GH=full run status
grep -q '^  jdwlabs,JDWLABS,3,1,1,100+,1 of 2 repos$' <<<"$out" || fail "the overview total must carry the + of a capped count" "$out"

STUB_GH=many run status jdwlabs --no-alerts
grep -q '^summary: "250 open' <<<"$out" && grep -q '^truncated: "showing 3 of 250' <<<"$out" \
    || fail "more PRs than one page must be counted and flagged" "$out"

# The overview counts reviews and failures from one page; past it they are a floor.
STUB_GH=many run status --no-alerts
grep -q '^  jdwlabs,JDWLABS,250,1+,1+$' <<<"$out" || fail "overview counts past one page must be marked as a floor" "$out"

STUB_GH=fail run status jdwlabs
[ "$rc" -eq 1 ] && grep -q '^error: "GitHub request failed: HTTP 401' <<<"$out" \
    || fail "a gh failure must be a structured error, not empty results" "$out"
run status nosuch
[ "$rc" -eq 2 ] && grep -q '^error: unknown stream nosuch' <<<"$out" || fail "unknown stream must be rejected" "$out"
run status jdwlabs --bogus
[ "$rc" -eq 2 ] && grep -q '^error: unknown flag --bogus' <<<"$out" || fail "unknown flags must be rejected" "$out"
rm "$stubs/gh"
# With no gh at all the answer is an error, never an empty stream.
mkdir "$tmp/minbin"
ln -s "$(command -v python3)" "$tmp/minbin/python3"
ln -s "$(command -v git)" "$tmp/minbin/git"
set +e
out="$(cd "$tmp" && HOME="$fx" PATH="$tmp/minbin" python3 "$stream" status jdwlabs 2>"$tmp/stderr")"
rc=$?
set -e
[ "$rc" -eq 1 ] && grep -q '^error: gh not installed' <<<"$out" || fail "missing gh must be a structured error" "$out"

# ── the chezmoi trigger regenerates the allowlist only on a personal machine ──
chez_render "$(chez_init personal)" "$trigger" >"$tmp/trigger-personal.sh"
# chezmoi re-runs a run_onchange script only when its rendered content changes,
# so a different map must render a different script.
mkdir "$tmp/src"
cp -R "$here/.chezmoiroot" "$here/home" "$tmp/src/"
echo '{"streams": {"jdwlabs": {"jira": "JDWLABS"}}}' >"$tmp/src/home/dot_config/streams.json"
CHEZ_SRC="$tmp/src" chez_render "$(chez_init personal)" "$trigger" >"$tmp/trigger-other-map.sh"
[ -s "$tmp/trigger-other-map.sh" ] || fail "trigger did not render against a second source tree"
cmp -s "$tmp/trigger-personal.sh" "$tmp/trigger-other-map.sh" \
    && fail "trigger must re-run when the stream map changes"
chez_render "$(chez_init work)" "$trigger" >"$tmp/trigger-work.sh"
shellcheck -s bash "$tmp/trigger-personal.sh" "$tmp/trigger-work.sh"
mkdir -p "$fx/.local/bin"
cp "$stream" "$fx/.local/bin/stream"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-work.sh" >/dev/null
[ ! -e "$cfg" ] || fail "a work machine must not get the personal Jira allowlist"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null
[ -f "$cfg" ] || fail "trigger did not generate claude-jira.json on a personal machine"
# Through the trigger too, a hand-written config survives.
echo '{"siteBase": "https://work.example.net", "projects": ["ABC"]}' >"$cfg"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null
grep -q 'work.example.net' "$cfg" || fail "the trigger overwrote a hand-written config"
rm -f "$cfg"
# A CI job or dev container is ephemeral even under the personal role, and the
# source tree's ignore rules already keep this file off such machines.
eph="$(mktemp -d "$CHEZ_TMP_ROOT/eph.XXXXXXXX")"
CI=true chezmoi init --source "$CHEZ_SRC" --destination "$eph/dest" --config "$eph/chezmoi.toml" \
    --promptString "machineRole=personal" --promptBool "installDevTooling=false" --no-tty >/dev/null
chez_render "$eph/chezmoi.toml" "$trigger" >"$tmp/trigger-ephemeral.sh"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-ephemeral.sh" >/dev/null
[ ! -e "$cfg" ] || fail "an ephemeral machine must not get the Jira allowlist"
rm -rf "$fx/.local"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null \
    || fail "trigger must exit 0 when stream is not installed yet"

echo "PASS"
