# Work Streams Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every dotfiles helper derive a repo's business stream from its GitHub owner, so worktree paths, Jira project keys and GitHub views are per-stream.

**Architecture:** A tracked stream map (`~/.config/streams.json`) names each owner's Jira project. A new read-only `stream` command resolves a repo's `<owner>/<repo>` slug and Jira key, generates the machine-local `claude-jira.json` that `cj` and the statusline already read, and prints per-stream GitHub status. `worktree-helpers.sh` resolves the same slug natively in bash; a parity test keeps the two implementations identical.

**Tech Stack:** Python 3 (stdlib only), bash, `gh`, chezmoi templates, the repo's bash test harness (`tests/scripts/*.sh`).

**Spec:** `docs/superpowers/specs/2026-10-07-work-stream-boundaries-design.md`

This is plan 1 of 2. It ships as one dotfiles PR and changes no folder, worktree or Jira issue. Plan 2 (`2026-10-07-work-streams-rollout.md`) does the moves and depends on this being merged and applied.

## Global Constraints

- Work in the worktree `~/worktrees/chezmoi/docs/stream-boundaries` (branch `docs/stream-boundaries`); never edit deployed targets under `~/.config`, `~/.local`, `~/.claude`.
- Streams and keys, verbatim: `jdwillmsen` → `JDW` (repo `career` → `CAREER`), `jdwlabs` → `JDWLABS`, `dotablaze-tech` → `DOTA`. Jira site: `https://jdwillmsen.atlassian.net`.
- Slug rule: `<owner>/<repo>` parsed from `git remote get-url origin`; `git config stream.owner` overrides the owner; no remote and no override → the main checkout's basename alone.
- Worktree path: `$WT_BASE/<owner>/<repo>/<type>/<name>`, `WT_BASE` default `~/worktrees`.
- `stream` mutates nothing on GitHub or Jira. Its only write is `~/.config/claude-jira.json`, and only via `jira-config --write`.
- Agent-facing output follows AXI: TOON on stdout including errors, exit `0` ok / `1` error, no prompts, `help[]` next steps, `--help` on every subcommand. Invoke the `axi` skill before writing Task 1 and Task 3.
- Python: stdlib only, no new dependencies. Bash: must pass `shellcheck -s bash`.
- Comments explain why, never what; no ticket IDs or URLs in comments.
- Commits: conventional format, each ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Assisted-by: Claude Code:claude-opus-5-5` (a subagent on another model uses its own model name and ID).
- Run one test with `bash tests/scripts/<file>.sh`; it prints `PASS` on success.

## Review Focus

1. **Remote URL shapes** — `https://…/owner/repo`, `…/repo.git`, a trailing slash, `ssh://git@host:22/owner/repo.git`: every one yields `owner/repo`. Pinned in Task 1 Step 1 and Task 2 Step 1.
2. **A hand-written `claude-jira.json`** (a work machine's employer config) must survive `jira-config --write` untouched. Pinned in Task 1 Step 1.
3. **Run from inside a linked worktree** — slug and worktree path must match what the main checkout gives, not the worktree's own folder name. Pinned in Task 1 Step 1 and Task 2 Step 1.
4. **GitHub says no** — `gh` unauthenticated, or an alerts endpoint returning 403/404: `stream status` reports an error or "unmeasured", never a reassuring zero. Pinned in Task 3 Step 1.
5. **More open PRs than one page** — the total comes from GitHub's count and the output says it is truncated. Pinned in Task 3 Step 1.

---

### Task 1: Stream map and `stream` core (`slug`, `key`, `jira-config`)

**Files:**
- Create: `home/dot_config/streams.json`
- Create: `home/dot_local/bin/executable_stream` (mode 755)
- Create: `home/run_onchange_after_56-generate-claude-jira.sh.tmpl`
- Test: `tests/scripts/test_stream_script.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `~/.config/streams.json`: `{"jiraSite": str, "streams": {<owner>: {"jira": str, "repoOverrides"?: {<repo>: str}}}}`
  - `stream slug [path]` → prints `owner/repo` (or bare `repo`), exit 0; not a repo → TOON `error:` on stdout, exit 1
  - `stream key [path]` → prints the Jira key, exit 0; unknown owner → `error:`, exit 1
  - `stream jira-config [--write]` → prints the JSON, or writes `~/.config/claude-jira.json` and prints `status: written|unchanged|kept`
  - `stream` (no args) → TOON list of streams
  - Python internals Task 3 extends: `Fail(msg, help_=())`, `emit(obj)`, `load_map()`, `HELP` dict, `main(argv)` dispatch.

- [ ] **Step 1: Write the failing test**

Create `tests/scripts/test_stream_script.sh`:

```bash
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
helpers="$here/home/private_dot_claude/scripts/worktree-helpers.sh"

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
[ "$rc" -eq 1 ] && grep -q '^error: unknown command' <<<"$out" || fail "unknown command must be a structured error" "$out"

# ── a missing or broken map is an error, never an empty answer ──
mv "$fx/.config/streams.json" "$tmp/streams.bak"
cwd="$tmp/repos/platform" run key
[ "$rc" -eq 1 ] && grep -q '^error: .*streams.json' <<<"$out" || fail "missing map must be a structured error" "$out"
echo '{"streams": {"x": {"jira": "lower"}}}' >"$fx/.config/streams.json"
run
[ "$rc" -eq 1 ] && grep -q '^error: ' <<<"$out" || fail "an invalid key in the map must be rejected" "$out"
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
rm -f "$cfg"

# ── the chezmoi trigger regenerates the allowlist only on a personal machine ──
grep -q 'include "dot_config/streams.json" | sha256sum' "$trigger" \
    || fail "trigger must re-run when the stream map changes"
chez_render "$(chez_init personal)" "$trigger" >"$tmp/trigger-personal.sh"
chez_render "$(chez_init work)" "$trigger" >"$tmp/trigger-work.sh"
shellcheck -s bash "$tmp/trigger-personal.sh" "$tmp/trigger-work.sh"
mkdir -p "$fx/.local/bin"
cp "$stream" "$fx/.local/bin/stream"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-work.sh" >/dev/null
[ ! -e "$cfg" ] || fail "a work machine must not get the personal Jira allowlist"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null
[ -f "$cfg" ] || fail "trigger did not generate claude-jira.json on a personal machine"
rm -rf "$fx/.local"
HOME="$fx" PATH="/usr/bin:/bin" bash "$tmp/trigger-personal.sh" >/dev/null \
    || fail "trigger must exit 0 when stream is not installed yet"

echo "PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/scripts/test_stream_script.sh`
Expected: `FAIL: stream missing or not executable`

- [ ] **Step 3: Create the stream map**

Create `home/dot_config/streams.json`:

```json
{
  "jiraSite": "https://jdwillmsen.atlassian.net",
  "streams": {
    "jdwillmsen": { "jira": "JDW", "repoOverrides": { "career": "CAREER" } },
    "jdwlabs": { "jira": "JDWLABS" },
    "dotablaze-tech": { "jira": "DOTA" }
  }
}
```

- [ ] **Step 4: Write `stream`**

Create `home/dot_local/bin/executable_stream`, then `chmod 755` it:

```python
#!/usr/bin/env python3
"""stream — which business a repo belongs to, and what is in flight there.

A stream is the GitHub owner of a repo; ~/.config/streams.json maps each owner
to its Jira project. Agent-facing: stdout is TOON, errors included, and nothing
here changes GitHub or Jira.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

VERSION = "1.0.0"

# Fast path before any real work: harnesses probe --version constantly.
if len(sys.argv) == 2 and sys.argv[1] in ("-v", "-V", "--version"):
    print(VERSION)
    sys.exit(0)

HOME = Path(os.environ.get("HOME") or Path.home())
MAP_PATH = HOME / ".config/streams.json"
JIRA_CONFIG = HOME / ".config/claude-jira.json"
# Marks a config this tool wrote. One without it was written by hand, typically
# for an employer's site, and is never replaced.
GENERATED_FROM = "streams.json"
KEY_RE = re.compile(r"[A-Z][A-Z0-9]{1,9}")
REMOTE_RE = re.compile(r"^.*[:/]([^/:]+)/([^/]+?)(?:\.git)?$")

HELP = {
    None: """Usage: stream [command]

Which business stream a repo belongs to, and what is in flight there.

Commands:
  (none)               list the streams and where the current repo sits
  slug [path]          print <owner>/<repo> for a repo
  key [path]           print the Jira project key for a repo
  jira-config [--write]  print, or write, ~/.config/claude-jira.json
  status [owner]       open PRs, reviews and alerts per stream

Flags: --help, --version""",
    "slug": """Usage: stream slug [path]

Print <owner>/<repo> for the repo at path (default: cwd). The owner comes from
`git config stream.owner`, else the origin remote. A repo with neither prints
its folder name alone.""",
    "key": """Usage: stream key [path]

Print the Jira project key for the repo at path (default: cwd). Exits 1 when
the repo's owner is not a stream in ~/.config/streams.json.""",
    "jira-config": """Usage: stream jira-config [--write]

Print the Jira allowlist that cj and the statusline read. With --write, save it
to ~/.config/claude-jira.json; a file not generated by this command is kept.""",
}


class Fail(Exception):
    def __init__(self, msg, help_=()):
        super().__init__(msg)
        self.help = list(help_)


def scalar(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    s = str(v)
    if (s == "" or s in ("true", "false", "null") or s != s.strip()
            or re.search(r'[,:"\n\\\[\]{}]', s) or re.fullmatch(r"-?\d+(\.\d+)?", s)):
        return json.dumps(s, ensure_ascii=False)
    return s


def toon(obj, indent=0):
    pad = "  " * indent
    out = []
    for k, v in obj.items():
        if isinstance(v, dict):
            out += [f"{pad}{k}:", toon(v, indent + 1)]
        elif isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            cols = list(v[0])
            out.append(f"{pad}{k}[{len(v)}]{{{','.join(cols)}}}:")
            out += [pad + "  " + ",".join(scalar(r.get(c)) for c in cols) for r in v]
        elif isinstance(v, list):
            out.append(f"{pad}{k}[{len(v)}]: " + ",".join(scalar(x) for x in v))
        else:
            out.append(f"{pad}{k}: {scalar(v)}")
    return "\n".join(line.rstrip() for line in out)


def emit(obj):
    print(toon(obj))


def load_map():
    try:
        smap = json.loads(MAP_PATH.read_text())
    except OSError:
        raise Fail(f"no stream map at {MAP_PATH} (streams.json)", ["chezmoi apply"])
    except ValueError as e:
        raise Fail(f"{MAP_PATH} (streams.json) is not valid JSON: {e}")
    streams = smap.get("streams") if isinstance(smap, dict) else None
    if not isinstance(streams, dict) or not streams:
        raise Fail(f"{MAP_PATH} (streams.json) has no streams")
    for owner, s in streams.items():
        keys = [s.get("jira")] if isinstance(s, dict) else [None]
        keys += list((s.get("repoOverrides") or {}).values()) if isinstance(s, dict) else []
        for k in keys:
            if not isinstance(k, str) or not KEY_RE.fullmatch(k):
                raise Fail(f"{MAP_PATH} (streams.json): stream {owner} has an invalid Jira key {k!r}")
    return smap


def git(path, *args):
    r = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def slug(path):
    """<owner>/<repo>, or None outside a repo.

    Read from the main checkout, never the cwd: a linked worktree's folder is
    named after its branch.
    """
    listing = git(path, "worktree", "list", "--porcelain")
    root = next((ln[len("worktree "):] for ln in listing.splitlines() if ln.startswith("worktree ")), "")
    if not root:
        return None
    m = REMOTE_RE.match(git(path, "remote", "get-url", "origin").rstrip("/"))
    name = m.group(2) if m else Path(root).name
    owner = git(path, "config", "--get", "stream.owner") or (m.group(1) if m else "")
    return f"{owner}/{name}" if owner else name


def require_slug(path):
    s = slug(path)
    if s is None:
        raise Fail(f"not a git repository: {Path(path).resolve()}", ["stream"])
    return s


def jira_key(smap, sl):
    owner, _, repo = sl.rpartition("/")
    s = smap["streams"].get(owner)
    if not s:
        raise Fail(f"{sl}: owner {owner or '(none)'} is not a known stream",
                   ["stream", "git config stream.owner <owner>"])
    return (s.get("repoOverrides") or {}).get(repo, s["jira"])


def cmd_home():
    smap = load_map()
    out = {
        "bin": "~/.local/bin/stream",
        "description": "Business stream per GitHub owner: Jira key, worktree namespace, GitHub status",
        "streams": [{"stream": o, "jira": s["jira"],
                     "overrides": " ".join(f"{r}={k}" for r, k in (s.get("repoOverrides") or {}).items()) or "-"}
                    for o, s in smap["streams"].items()],
    }
    here = slug(".")
    if here:
        out["here"] = here
        try:
            out["here_jira"] = jira_key(smap, here)
        except Fail:
            out["here_jira"] = "none (owner is not a stream)"
    out["help"] = ["stream status", "stream status <owner>", "stream key"]
    emit(out)
    return 0


def cmd_slug(args):
    print(require_slug(args[0] if args else "."))
    return 0


def cmd_key(args):
    print(jira_key(load_map(), require_slug(args[0] if args else ".")))
    return 0


def cmd_jira_config(args):
    if set(args) - {"--write"}:
        raise Fail(f"unknown argument {sorted(set(args) - {'--write'})[0]}", ["stream jira-config --help"])
    smap = load_map()
    site = smap.get("jiraSite")
    if not isinstance(site, str) or not site.startswith("https://"):
        raise Fail(f"{MAP_PATH} (streams.json) has no https jiraSite")
    keys = sorted({k for s in smap["streams"].values()
                   for k in [s["jira"], *(s.get("repoOverrides") or {}).values()]})
    cfg = {"siteBase": site, "projects": keys, "generatedFrom": GENERATED_FROM}
    text = json.dumps(cfg, indent=2) + "\n"
    if "--write" not in args:
        sys.stdout.write(text)
        return 0
    status = "written"
    if JIRA_CONFIG.exists():
        try:
            cur = json.loads(JIRA_CONFIG.read_text())
        except (OSError, ValueError):
            cur = None
        if not isinstance(cur, dict) or cur.get("generatedFrom") != GENERATED_FROM:
            emit({"status": "kept", "path": str(JIRA_CONFIG),
                  "reason": "not generated by stream; delete it to adopt the stream map"})
            return 0
        if cur == cfg:
            status = "unchanged"
    if status == "written":
        JIRA_CONFIG.parent.mkdir(parents=True, exist_ok=True)
        # Replace atomically: the statusline re-reads this file every few seconds.
        fd, tmp = tempfile.mkstemp(dir=JIRA_CONFIG.parent, prefix=".claude-jira.")
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, JIRA_CONFIG)
    emit({"status": status, "path": str(JIRA_CONFIG), "projects": keys})
    return 0


COMMANDS = {"slug": cmd_slug, "key": cmd_key, "jira-config": cmd_jira_config}


def main(argv):
    args = [a for a in argv if a not in ("--help", "-h")]
    cmd = args[0] if args else None
    if len(args) != len(argv):
        print(HELP.get(cmd, HELP[None]))
        return 0
    try:
        if cmd is None:
            return cmd_home()
        if cmd not in COMMANDS:
            raise Fail(f"unknown command {cmd}", ["stream --help"])
        return COMMANDS[cmd](args[1:])
    except Fail as e:
        emit({"error": str(e), **({"help": e.help} if e.help else {})})
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

The test's `--help` loop includes `status`, which Task 3 adds. Until then `HELP.get("status", HELP[None])` prints the top-level usage, which satisfies the loop.

- [ ] **Step 5: Write the chezmoi trigger**

Create `home/run_onchange_after_56-generate-claude-jira.sh.tmpl`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Regenerate the Jira allowlist whenever the stream map changes, so cj and the
# statusline cannot drift from it.
# {{ include "dot_config/streams.json" | sha256sum }}
# {{ include "dot_local/bin/executable_stream" | sha256sum }}
{{ if ne .machineRole "personal" -}}
# The stream map names personal businesses; any other role keeps whatever Jira
# config it was given by hand.
echo "claude-jira: machine role is {{ .machineRole }} — skipping"
exit 0
{{ else -}}
stream="$HOME/.local/bin/stream"
if [ ! -x "$stream" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "claude-jira: stream or python3 unavailable — skipping"
    exit 0
fi
"$stream" jira-config --write
{{ end -}}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/scripts/test_stream_script.sh`
Expected: `PASS`

If the `chez_init work` render fails because `work` is not an accepted role, read `home/.chezmoi.toml.tmpl` for the accepted values and use a non-personal, non-ephemeral one in the test.

- [ ] **Step 7: Run the repo-wide script coverage test**

Run: `bash tests/scripts/test_shell_script_coverage.sh`
Expected: `PASS` (the new `run_onchange_` file is referenced by the test above, and lints clean once rendered).

- [ ] **Step 8: Commit**

```bash
git add home/dot_config/streams.json home/dot_local/bin/executable_stream \
    home/run_onchange_after_56-generate-claude-jira.sh.tmpl tests/scripts/test_stream_script.sh
git commit -m "feat(stream): resolve a repo's business stream and Jira project

One tracked map names each GitHub owner's Jira project. stream resolves
owner/repo and the key for any repo, and generates the allowlist cj and the
statusline read, which did not exist on this box.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Assisted-by: Claude Code:claude-opus-5-5"
```

---

### Task 2: Worktree helpers namespace by `<owner>/<repo>`

**Files:**
- Modify: `home/private_dot_claude/scripts/worktree-helpers.sh:7` (header comment), `:29` (`__wt_project`), `:53-54` (comment)
- Test: `tests/scripts/test_worktree_helpers.sh` (append before the final `echo "PASS"`)

**Interfaces:**
- Consumes: `stream slug` from Task 1 (parity check only; the helper does not call it).
- Produces: `__wt_project` prints `<owner>/<repo>` (or bare `<repo>`); `gwta <type>/<name>` creates `$WT_BASE/<owner>/<repo>/<type>/<name>`.

`wtd` already falls back to a porcelain lookup when the computed path is absent, so worktrees created under the old `$WT_BASE/<repo>/…` layout stay removable. Do not change `wtd`.

- [ ] **Step 1: Write the failing test**

In `tests/scripts/test_worktree_helpers.sh`, insert before the final `echo "PASS"`:

```bash
# Behavioural check: the project namespace is <owner>/<repo> from the origin
# remote, so two owners' same-named repos cannot share a worktree folder.
tmp="$(mktemp -d)"
slug_in() { (cd "$1" && bash -c '. "$0"; __wt_project' "$script"); }
mkrepo() {
    git init -q "$tmp/$1"
    git -C "$tmp/$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    [ -z "${2:-}" ] || git -C "$tmp/$1" remote add origin "$2"
}
mkrepo a git@github.com:jdwlabs/platform.git
mkrepo b https://github.com/dotablaze-tech/platform
mkrepo c https://github.com/jdwillmsen/career.git/
mkrepo d ssh://git@github.com:22/jdwillmsen/gameops.git
mkrepo e
mkrepo f git@github.com:kunchenguid/no-mistakes.git
git -C "$tmp/f" config stream.owner jdwillmsen
git -C "$tmp/a" worktree add -q -b wt-inside "$tmp/inside" >/dev/null 2>&1

stream_bin="$here/home/dot_local/bin/executable_stream"
for case in "a:jdwlabs/platform" "b:dotablaze-tech/platform" "c:jdwillmsen/career" \
    "d:jdwillmsen/gameops" "e:e" "f:jdwillmsen/no-mistakes" "inside:jdwlabs/platform"; do
    dir="${case%%:*}" want="${case#*:}"
    got="$(slug_in "$tmp/$dir")"
    [ "$got" = "$want" ] || { echo "FAIL: __wt_project in $dir gave '$got', expected '$want'"; exit 1; }
    # Two implementations of one rule: any disagreement sends a worktree and its
    # ticket key to different streams.
    py="$(cd "$tmp/$dir" && python3 "$stream_bin" slug)"
    [ "$py" = "$got" ] || { echo "FAIL: stream slug '$py' disagrees with __wt_project '$got' in $dir"; exit 1; }
done

(cd "$tmp/a" && WT_BASE="$tmp/wt" bash -c '. "$0"; gwta fix/thing' "$script" >/dev/null 2>&1)
[ -d "$tmp/wt/jdwlabs/platform/fix/thing" ] \
    || { echo "FAIL: gwta did not create the worktree under <owner>/<repo>"; exit 1; }
# From inside a linked worktree the namespace must still be the repo's.
(cd "$tmp/inside" && WT_BASE="$tmp/wt" bash -c '. "$0"; gwta fix/nested' "$script" >/dev/null 2>&1)
[ -d "$tmp/wt/jdwlabs/platform/fix/nested" ] \
    || { echo "FAIL: gwta from a linked worktree used the wrong namespace"; exit 1; }
rm -rf "$tmp"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/scripts/test_worktree_helpers.sh`
Expected: `FAIL: __wt_project in a gave 'a', expected 'jdwlabs/platform'`

- [ ] **Step 3: Implement**

In `home/private_dot_claude/scripts/worktree-helpers.sh`, change line 7 to:

```bash
# Worktrees: ~/worktrees/<owner>/<repo>/<type>/<name>   (override: export WT_BASE=...)
```

Replace line 29 (`__wt_project() { basename "$(__wt_repo_root 2>/dev/null)"; }`) with:

```bash
# <owner>/<repo>, so a worktree lands under its business stream and two owners'
# same-named repos cannot collide. `git config stream.owner` overrides the
# owner for a fork whose origin is upstream. Resolved from the remote and the
# main checkout, never the cwd: a linked worktree's folder is named after its
# branch. Must agree with `stream slug`.
__wt_project() {
    local url slug owner root
    url=$(git remote get-url origin 2>/dev/null)
    url="${url%/}"
    url="${url%.git}"
    slug=$(printf '%s' "$url" | sed -nE 's#^.*[:/]([^/:]+)/([^/]+)$#\1/\2#p')
    owner=$(git config --get stream.owner 2>/dev/null)
    if [[ -z "$slug" ]]; then
        root=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
        [[ -n "$root" ]] || return 1
        slug=$(basename "$root")
        [[ -z "$owner" ]] || slug="$owner/$slug"
    elif [[ -n "$owner" ]]; then
        slug="$owner/${slug#*/}"
    fi
    printf '%s\n' "$slug"
}
```

Change the comment above `__wt_path_display` (line 53) to:

```bash
# Short path: strips ~/worktrees/<owner>/<repo>/ prefix
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/scripts/test_worktree_helpers.sh && bash tests/scripts/test_stream_script.sh`
Expected: `PASS` twice.

- [ ] **Step 5: Commit**

```bash
git add home/private_dot_claude/scripts/worktree-helpers.sh tests/scripts/test_worktree_helpers.sh
git commit -m "feat(worktrees): namespace worktrees by owner and repo

The project folder was the cwd's basename, which collides for two owners'
same-named repos and resolved to the branch folder from inside a linked
worktree.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Assisted-by: Claude Code:claude-opus-5-5"
```

---

### Task 3: `stream status` — per-stream GitHub view

**Files:**
- Modify: `home/dot_local/bin/executable_stream` (add `HELP["status"]`, GitHub helpers, `cmd_status`, register in `COMMANDS`)
- Test: `tests/scripts/test_stream_script.sh` (insert before the `# ── the chezmoi trigger` section)

**Interfaces:**
- Consumes: `Fail`, `emit`, `load_map`, `HELP`, `COMMANDS` from Task 1.
- Produces:
  - `stream status` → TOON `streams[N]{stream,jira,open_prs,review_requested,failing,alerts}`
  - `stream status <owner>` → TOON with `summary`, `pull_requests[N]{repo,number,checks,review,title}`, `alerts`, `help[]`
  - `--no-alerts` skips the per-repo alert calls.

- [ ] **Step 1: Write the failing test**

In `tests/scripts/test_stream_script.sh`, insert before the line `# ── the chezmoi trigger regenerates…`:

```bash
# ── status: GitHub's view of one stream, against a stub gh ──
cat >"$stubs/gh" <<'STUB'
#!/usr/bin/env python3
# Modes: ok (fixture), fail (every call errors), many (more PRs than one page).
import json, os, re, sys
args = sys.argv[1:]
open(os.environ["STUB_LOG"], "a").write(" ".join(args) + "\n")
mode = os.environ.get("STUB_GH", "ok")
if mode == "fail":
    sys.stderr.write("HTTP 401: Bad credentials\n"); sys.exit(1)
def pr(repo, n, title, state, decision="REVIEW_REQUIRED"):
    return {"number": n, "title": title, "url": f"https://github.com/x/{repo}/pull/{n}", "isDraft": False,
            "reviewDecision": decision, "repository": {"name": repo},
            "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": state} if state else None}}]}}
if args[:2] == ["api", "graphql"]:
    owner = re.search(r"open=.*user:(\S+)", " ".join(args)).group(1)
    nodes = {"jdwlabs": [pr("platform", 7, "feat: a, b", "SUCCESS"), pr("apps", 9, "fix: c", "FAILURE", "APPROVED"),
                         pr("apps", 11, "x" * 90, None)],
             "jdwillmsen": [pr("gameops", 3, "feat: d", "PENDING")]}.get(owner, [])
    mine = [n for n in nodes if n["number"] == 7]
    count = 250 if mode == "many" else len(nodes)
    print(json.dumps({"data": {"open": {"issueCount": count, "nodes": nodes}, "mine": {"nodes": mine}}}))
    sys.exit(0)
if args[:2] == ["repo", "list"]:
    print(json.dumps({"jdwlabs": ["apps", "platform"], "jdwillmsen": ["gameops"]}.get(args[2], [])))
    sys.exit(0)
if args[0] == "api":
    path = next(a for a in args if a.startswith("repos/"))
    if path == "repos/jdwlabs/apps/dependabot/alerts": print(3); sys.exit(0)
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
grep -q '^  apps,9,failing,approved,' <<<"$out" || fail "failing PR row wrong" "$out"
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
grep -q '^alerts' <<<"$out" && fail "--no-alerts should skip alerts" "$out"

run status dotablaze-tech
[ "$rc" -eq 0 ] && grep -q '^pull_requests: 0 open' <<<"$out" && grep -q '^alerts: 0 open across 0 repos' <<<"$out" \
    || fail "an empty stream must say so explicitly" "$out"

run status
[ "$rc" -eq 0 ] || fail "status should exit 0" "$out"
grep -q '^streams\[3\]{stream,jira,open_prs,review_requested,failing,alerts}:' <<<"$out" || fail "overview header wrong" "$out"
grep -q '^  jdwlabs,JDWLABS,3,1,1,3$' <<<"$out" || fail "jdwlabs overview row wrong" "$out"
grep -q '^  jdwillmsen,JDW,1,0,0,0$' <<<"$out" || fail "jdwillmsen overview row wrong" "$out"
grep -q '^  dotablaze-tech,DOTA,0,0,0,0$' <<<"$out" || fail "empty stream overview row wrong" "$out"

STUB_GH=many run status jdwlabs --no-alerts
grep -q '^summary: "250 open' <<<"$out" && grep -q '^truncated: "showing 3 of 250' <<<"$out" \
    || fail "more PRs than one page must be counted and flagged" "$out"

STUB_GH=fail run status jdwlabs
[ "$rc" -eq 1 ] && grep -q '^error: GitHub request failed: HTTP 401' <<<"$out" \
    || fail "a gh failure must be a structured error, not empty results" "$out"
run status nosuch
[ "$rc" -eq 1 ] && grep -q '^error: unknown stream nosuch' <<<"$out" || fail "unknown stream must be rejected" "$out"
run status jdwlabs --bogus
[ "$rc" -eq 1 ] && grep -q '^error: unknown argument --bogus' <<<"$out" || fail "unknown flags must be rejected" "$out"
rm "$stubs/gh"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/scripts/test_stream_script.sh`
Expected: `FAIL: status jdwlabs should exit 0` followed by `error: unknown command status`.

- [ ] **Step 3: Implement**

In `home/dot_local/bin/executable_stream`:

Add below the `REMOTE_RE` line:

```python
GH_TIMEOUT_S = 60
PR_PAGE = 100
TITLE_MAX = 58
CHECKS = {"SUCCESS": "passing", "FAILURE": "failing", "ERROR": "failing",
          "PENDING": "pending", "EXPECTED": "pending"}
REVIEW = {"APPROVED": "approved", "CHANGES_REQUESTED": "changes", "REVIEW_REQUIRED": "needed"}
# One request per stream: open PRs with their check rollup, plus the subset
# waiting on the caller, which the first search cannot express per row.
PR_QUERY = """query($open: String!, $mine: String!, $n: Int!) {
  open: search(query: $open, type: ISSUE, first: $n) {
    issueCount
    nodes { ... on PullRequest {
      number title url isDraft reviewDecision
      repository { name }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    } }
  }
  mine: search(query: $mine, type: ISSUE, first: $n) {
    nodes { ... on PullRequest { url } }
  }
}"""
```

Add to the `HELP` dict:

```python
    "status": """Usage: stream status [owner] [--no-alerts]

Open pull requests with check state, reviews waiting on you, and open
Dependabot and code-scanning alerts. With no owner, one summary row per
stream. --no-alerts skips the per-repo alert requests. Read-only.""",
```

Add before the `COMMANDS = …` line:

```python
def gh(args):
    if not shutil.which("gh"):
        raise Fail("gh not installed")
    try:
        return subprocess.run(["gh", *args], capture_output=True, text=True, timeout=GH_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise Fail(f"gh timed out after {GH_TIMEOUT_S}s")


def gh_json(args):
    r = gh(args)
    if r.returncode != 0:
        first = (r.stderr.strip().splitlines() or ["unknown error"])[0]
        raise Fail(f"GitHub request failed: {first[:160]}", ["gh auth status"])
    try:
        return json.loads(r.stdout or "null")
    except ValueError:
        raise Fail("GitHub returned something that is not JSON")


def clip(s):
    s = " ".join(str(s).split())
    return s if len(s) <= TITLE_MAX else s[:TITLE_MAX - 1] + "…"


def stream_prs(owner):
    """(rows, total). total is GitHub's count, which can exceed the page."""
    base = f"is:pr is:open archived:false user:{owner}"
    data = (gh_json(["api", "graphql", "-f", f"query={PR_QUERY}", "-f", f"open={base}",
                     "-f", f"mine={base} review-requested:@me", "-F", f"n={PR_PAGE}"]) or {}).get("data")
    if not data:
        raise Fail(f"GitHub returned no data for {owner}", ["gh auth status"])
    mine = {(n or {}).get("url") for n in data["mine"]["nodes"]}
    rows = []
    for n in data["open"]["nodes"]:
        if not n:
            continue
        commit = (((n.get("commits") or {}).get("nodes") or [{}])[0] or {}).get("commit") or {}
        state = (commit.get("statusCheckRollup") or {}).get("state")
        rows.append({"repo": n["repository"]["name"], "number": n["number"],
                     "checks": CHECKS.get(state, "none"),
                     "review": "requested" if n["url"] in mine else REVIEW.get(n.get("reviewDecision"), "none"),
                     "title": clip(n["title"])})
    return rows, max(data["open"]["issueCount"], len(rows))


def stream_alerts(owner):
    """(rows with open alerts, repo count, repos with an unreadable endpoint).

    A 403/404 means the feature is off or not readable with this token; that is
    reported as unmeasured, because a zero would read as "nothing to fix".
    """
    repos = gh_json(["repo", "list", owner, "--no-archived", "--limit", "200",
                     "--json", "name", "--jq", "[.[].name]"]) or []
    rows, unmeasured = [], 0
    for repo in sorted(repos):
        counts = {}
        for kind, col in (("dependabot", "dependabot"), ("code-scanning", "code_scanning")):
            r = gh(["api", "-X", "GET", f"repos/{owner}/{repo}/{kind}/alerts",
                    "-f", "state=open", "-f", "per_page=100", "--jq", "length"])
            n = r.stdout.strip()
            counts[col] = int(n) if r.returncode == 0 and n.isdigit() else None
        if None in counts.values():
            unmeasured += 1
        if any(counts.values()):
            rows.append({"repo": repo, **{c: ("n/a" if v is None else v) for c, v in counts.items()}})
    return rows, len(repos), unmeasured


def alert_total(rows):
    return sum(v for r in rows for v in (r["dependabot"], r["code_scanning"]) if isinstance(v, int))


def status_detail(owner, s, with_alerts):
    prs, total = stream_prs(owner)
    requested = sum(p["review"] == "requested" for p in prs)
    failing = sum(p["checks"] == "failing" for p in prs)
    search = f"https://github.com/pulls?q=is:open+is:pr+archived:false+user:{owner}"
    out = {"stream": owner, "jira": s["jira"],
           "summary": f"{total} open, {requested} awaiting your review, {failing} failing",
           "pull_requests": prs or "0 open"}
    if total > len(prs):
        out["truncated"] = f"showing {len(prs)} of {total} — full list at {search}"
    if with_alerts:
        rows, repos, unmeasured = stream_alerts(owner)
        out["alerts"] = rows or f"0 open across {repos} repos"
        if unmeasured:
            out["alerts_unmeasured"] = f"{unmeasured} of {repos} repos (alerts disabled or not readable)"
    out["help"] = [f"gh pr view <number> --repo {owner}/<repo>", search]
    return out


def cmd_status(args):
    flags = [a for a in args if a.startswith("-")]
    owners = [a for a in args if not a.startswith("-")]
    bad = [f for f in flags if f != "--no-alerts"]
    if bad or len(owners) > 1:
        raise Fail(f"unknown argument {(bad or owners[1:])[0]}", ["stream status --help"])
    with_alerts = "--no-alerts" not in flags
    streams = load_map()["streams"]
    if owners:
        if owners[0] not in streams:
            raise Fail(f"unknown stream {owners[0]}", [f"stream status {o}" for o in streams])
        emit(status_detail(owners[0], streams[owners[0]], with_alerts))
        return 0
    rows = []
    for owner, s in streams.items():
        prs, total = stream_prs(owner)
        row = {"stream": owner, "jira": s["jira"], "open_prs": total,
               "review_requested": sum(p["review"] == "requested" for p in prs),
               "failing": sum(p["checks"] == "failing" for p in prs)}
        if with_alerts:
            row["alerts"] = alert_total(stream_alerts(owner)[0])
        rows.append(row)
    emit({"streams": rows, "help": ["stream status <owner>", "stream status --no-alerts"]})
    return 0
```

Change the `COMMANDS` line to:

```python
COMMANDS = {"slug": cmd_slug, "key": cmd_key, "jira-config": cmd_jira_config, "status": cmd_status}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/scripts/test_stream_script.sh`
Expected: `PASS`

- [ ] **Step 5: Check it against real GitHub**

Run: `python3 home/dot_local/bin/executable_stream status jdwlabs`
Expected: exit 0, a `summary:` line, and a PR count equal to the result count at `https://github.com/pulls?q=is:open+is:pr+archived:false+user:jdwlabs`. Record both numbers in the PR description. This needs `~/.config/streams.json`; if it is not deployed yet, run with `HOME` pointing at a temp dir holding a copy of `home/dot_config/streams.json` at `.config/streams.json` and `GH_CONFIG_DIR=$HOME/.config/gh` set to the real one.

- [ ] **Step 6: Commit**

```bash
git add home/dot_local/bin/executable_stream tests/scripts/test_stream_script.sh
git commit -m "feat(stream): show open PRs, reviews and alerts per stream

GitHub's own PR list cannot show check state and security alerts together or
be read by an agent, and Jira cannot see code in flight at all.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Assisted-by: Claude Code:claude-opus-5-5"
```

---

### Task 4: `jira-create` files into the current repo's stream

**Files:**
- Modify: `home/private_dot_claude/skills/jira-create/SKILL.md` (lines 25, 26, 32, 40, 45, 49, 119, 149–150, 157, 201–202, 279, 325, 344–346)
- Test: `tests/scripts/test_jira_create_skill.sh` (new)

**Interfaces:**
- Consumes: `stream key` (prints the Jira key or exits 1) and `~/.config/streams.json` from Task 1.
- Produces: nothing other tasks use.

- [ ] **Step 1: Write the failing test**

Create `tests/scripts/test_jira_create_skill.sh`:

```bash
#!/usr/bin/env bash
# The skill is instructions, not code, so what can be pinned is that it no
# longer steers every ticket into one project regardless of the repo.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
skill="$here/home/private_dot_claude/skills/jira-create/SKILL.md"
fail() { echo "FAIL: $1"; exit 1; }

grep -q 'stream key' "$skill" || fail "skill must resolve the project with 'stream key'"
grep -q 'Default `JDWLABS`' "$skill" && fail "skill still defaults every ticket to JDWLABS"
grep -q 'project = JDWLABS' "$skill" && fail "skill still hardcodes JDWLABS in JQL"
grep -q 'project = <PROJECT>' "$skill" || fail "JQL should use the resolved <PROJECT>"
grep -qE 'JDWLABS-[0-9X]+' "$skill" && fail "examples should use <PROJECT>-NN, not a JDWLABS key"
# Cross-stream work is linked, never re-parented across projects.
grep -qi 'another stream' "$skill" || fail "skill must say how to reference another stream's ticket"
echo "PASS"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/scripts/test_jira_create_skill.sh`
Expected: `FAIL: skill must resolve the project with 'stream key'`

- [ ] **Step 3: Edit the skill**

In `home/private_dot_claude/skills/jira-create/SKILL.md`:

Line 25 — in the **Issue type** row, replace `JDWLABS has no Story type — file new capability as a Task` with `These projects have no Story type — file new capability as a Task`.

Line 26 — replace the whole **Project** row with:

```markdown
| **Project** | Run `stream key` in the repo the work is for; its output is `<PROJECT>` for every step below. The project follows the repo's GitHub owner (`jdwillmsen` → `JDW`, with `career` → `CAREER`; `jdwlabs` → `JDWLABS`; `dotablaze-tech` → `DOTA`), not the directory the session happens to be in. If it exits 1, or the work belongs to no repo, ask which stream — never default. |
```

Line 32 — replace `on JDWLABS they are Epic, Task, Bug, Spike and Subtask` with `on JDWLABS they are Epic, Task, Bug, Spike and Subtask, and other projects may differ`.

Line 40 — replace `"put it under JDWLABS-131"` with `"put it under <PROJECT>-131"`.

Line 45 — replace `project = JDWLABS AND issuetype = Epic` with `project = <PROJECT> AND issuetype = Epic`.

Line 49 — replace `project = JDWLABS AND statusCategory != Done` with `project = <PROJECT> AND statusCategory != Done`.

After the paragraph that ends the "Dependency/duplicate sweep" (line 49), add:

```markdown
**Work that touches another stream:** the parent Epic is always in `<PROJECT>`. A dependency on another stream's ticket is recorded with a `Blocks` or `Relates` link to that ticket, never by parenting across projects — an Epic lives in exactly one project.
```

Line 119 — replace `JDWLABS is a team-managed project and Jira does not offer that field` with `every project on this site is team-managed and Jira does not offer that field`.

Line 157 — replace `which JDWLABS makes required on Spikes` with `which JDWLABS makes required on Spikes (check other projects with getJiraIssueTypeMetaWithFields)`.

Then replace every remaining example key. Run:

```bash
sed -i -E 's/JDWLABS-(XX|[0-9]+)/<PROJECT>-\1/g' home/private_dot_claude/skills/jira-create/SKILL.md
```

and confirm with `grep -n 'JDWLABS' home/private_dot_claude/skills/jira-create/SKILL.md` that the only lines left are 26, 32 and 157 as written above.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/scripts/test_jira_create_skill.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add home/private_dot_claude/skills/jira-create/SKILL.md tests/scripts/test_jira_create_skill.sh
git commit -m "feat(jira-create): file tickets in the current repo's stream

The skill defaulted every ticket to one project, which is how personal-repo
work ended up on the org's board.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Assisted-by: Claude Code:claude-opus-5-5"
```

---

### Task 5: `agent-audit` covers every stream

**Files:**
- Modify: `home/dot_local/bin/executable_agent-audit` (`:688` repo glob, `:775` and `:783` owner list, `:1018` report heading; add `stream_owners()` above `gh_search`)
- Test: `tests/scripts/test_agent_audit_script.sh` (insert after the line containing `"PR search not scoped to the window"`, currently line 243; and extend the fixture at line 56)

**Interfaces:**
- Consumes: `~/.config/streams.json` shape from Task 1.
- Produces: `stream_owners() -> list[str]`.

`JIRA_PROJECT = "JDWLABS"` on line 40 is deliberately unchanged here: the audit's Epic still lives in `JDWLABS` until plan 2 migrates it, and that plan changes the constant in the same step.

- [ ] **Step 1: Write the failing test**

In `tests/scripts/test_agent_audit_script.sh`, add after line 56 (`w("projects/jdwlabs/r1/AGENTS.md", …)`):

```python
w("projects/jdwillmsen/r2/AGENTS.md", "y\n")
```

and insert after the line that ends `fail "PR search not scoped to the window" "$(cat "$log.gh")"`:

```bash
check '"~/projects/jdwillmsen/r2/AGENTS.md" in [f["path"] for f in j["instructions"]["files"]]' "True" \
    "instruction files found under every owner folder"
# With no stream map the audit keeps its two original owners.
grep -q -- "--owner jdwillmsen --owner jdwlabs --created" "$log.gh" || fail "default owners changed" "$(cat "$log.gh")"
mkdir -p "$fx/.config"
echo '{"streams": {"jdwillmsen": {"jira": "JDW"}, "jdwlabs": {"jira": "JDWLABS"}, "dotablaze-tech": {"jira": "DOTA"}}}' \
    >"$fx/.config/streams.json"
: >"$log.gh"
run
grep -q -- "--owner jdwillmsen --owner jdwlabs --owner dotablaze-tech --created" "$log.gh" \
    || fail "PR hygiene must cover every stream in the map" "$(cat "$log.gh")"
grep -q "user:jdwillmsen user:jdwlabs user:dotablaze-tech" "$log.gh" || fail "count query must cover every stream" "$(cat "$log.gh")"
grep -q "^## PR hygiene (jdwillmsen, jdwlabs, dotablaze-tech)" "$md" || fail "report heading should name the streams measured"
echo 'not json' >"$fx/.config/streams.json"
: >"$log.gh"
run
grep -q -- "--owner jdwillmsen --owner jdwlabs --created" "$log.gh" || fail "a broken stream map must fall back, not crash" "$out"
rm -f "$fx/.config/streams.json"
```

The bare `run` matches the invocation the surrounding assertions use (see the `run` call a few lines above the `check` block); if that call carries arguments, pass the same ones.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/scripts/test_agent_audit_script.sh`
Expected: `FAIL: instruction files found under every owner folder` (or the harness's equivalent message for that `check`).

- [ ] **Step 3: Implement**

In `home/dot_local/bin/executable_agent-audit`:

Replace line 688 with:

```python
    repos = sorted({Path(p) for pattern in ("projects/*/AGENTS.md", "projects/*/*/AGENTS.md")
                    for p in glob.glob(str(HOME / pattern))})
```

Add immediately above `def gh_search(`:

```python
def stream_owners():
    """GitHub owners to measure: the stream map when readable, else the two
    owners this audit started with — a missing map must not blank the section."""
    try:
        streams = json.loads((HOME / ".config/streams.json").read_text())["streams"]
        owners = [o for o in streams if re.fullmatch(r"[A-Za-z0-9-]+", o)]
    except (OSError, ValueError, KeyError, TypeError):
        owners = []
    return owners or ["jdwillmsen", "jdwlabs"]
```

In `gh_search`, replace the `q = …` line with:

```python
    owners = stream_owners()
    q = ("is:pr " if kind == "prs" else "") + " ".join(f"user:{o}" for o in owners) + f" {qual}:{rng}"
```

and replace `"--owner", "jdwillmsen", "--owner", "jdwlabs", date_flag, rng,` with:

```python
*[x for o in owners for x in ("--owner", o)], date_flag, rng,
```

(the surrounding call becomes `gh_json(["search", kind, *[x for o in owners for x in ("--owner", o)], date_flag, rng, "--limit", str(limit), "--json", fields], pages=-(-limit // 100))`).

Replace line 1018 with:

```python
    L += [f"## PR hygiene ({', '.join(stream_owners())})", ""]
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/scripts/test_agent_audit_script.sh`
Expected: `PASS`

- [ ] **Step 5: Commit**

```bash
git add home/dot_local/bin/executable_agent-audit tests/scripts/test_agent_audit_script.sh
git commit -m "feat(agent-audit): measure every stream in the map

Owners and the repo instruction-file glob were hardcoded to one org's
layout, so a third owner and any repo outside that folder went unmeasured.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Assisted-by: Claude Code:claude-opus-5-5"
```

---

### Task 6: Aliases and docs for the tooling

**Files:**
- Modify: `home/dot_config/shell/aliases.sh:87`
- Modify: `home/AGENTS.md` (the `## Worktrees` section)
- Modify: `home/private_dot_claude/CLAUDE.md:66-68` (branch-name rule)
- Modify: `docs/shell-helpers.md` (`## Worktree locations`, the `cj` section, the `claude-jira.json` section; new `## stream` section)
- Create: `docs/streams.md`
- Test: `tests/template/test_shell_files.sh` (append before its final success line)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing other tasks use.

The `## Projects` section of `home/AGENTS.md` describes the folder layout and is rewritten by plan 2 when the folders actually move. Do not touch it here.

- [ ] **Step 1: Write the failing test**

Read the last 15 lines of `tests/template/test_shell_files.sh` to see its failure idiom and success line, then add before that success line, using the same idiom:

```bash
aliases="$here/home/dot_config/shell/aliases.sh"
for a in "alias jlabs='cd ~/projects/jdwlabs'" "alias jdw='cd ~/projects/jdwillmsen'" \
    "alias dota='cd ~/projects/dotablaze-tech'"; do
    grep -qxF "$a" "$aliases" || { echo "FAIL: missing stream alias: $a"; exit 1; }
done
```

If that file does not define `$here`, define it the way `tests/scripts/test_worktree_helpers.sh` line 5 does.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/template/test_shell_files.sh`
Expected: `FAIL: missing stream alias: alias jdw='cd ~/projects/jdwillmsen'`

- [ ] **Step 3: Add the aliases**

In `home/dot_config/shell/aliases.sh`, replace line 87 with:

```bash
alias jlabs='cd ~/projects/jdwlabs'
alias jdw='cd ~/projects/jdwillmsen'
alias dota='cd ~/projects/dotablaze-tech'
```

- [ ] **Step 4: Update `home/AGENTS.md`**

Replace the `## Worktrees — …` heading and its paragraph with:

```markdown
## Worktrees — `~/worktrees/<owner>/<repo>/<branch>`

`gwta` namespaces by the repo's GitHub owner, so `jdwlabs/platform` and
`dotablaze-tech/platform` cannot collide. `WT_BASE` (default `~/worktrees`)
may not exist until the first `gwta` run — its absence is not an error.

## Streams — one per GitHub owner

Each owner is a separate business with its own Jira project; the map is
`~/.config/streams.json`. `stream key` prints the project for the current
repo and `stream status <owner>` its open PRs and alerts. A fork whose origin
is upstream is assigned with `git config stream.owner <owner>`. Detail:
dotfiles `docs/streams.md`.
```

- [ ] **Step 5: Update the branch-name rule in `home/private_dot_claude/CLAUDE.md`**

Replace the bullet that starts `- Branch names:` (lines 66–68) with:

```markdown
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` + ticket key +
  kebab-case — `feat/JDWLABS-123-fix-login-retry`. The key's project is the
  repo's stream (`stream key`); the statusline and `cj` resolve it. Omit the
  key only for work with no ticket.
```

- [ ] **Step 6: Write `docs/streams.md`**

```markdown
# Streams

Each GitHub owner is one business stream. The owner of a repo decides its Jira
project, its folder under `~/projects`, and its worktree namespace.

| Stream | Jira project | Folder | Open PRs |
|---|---|---|---|
| `jdwillmsen` | `JDW` (`career` → `CAREER`) | `~/projects/jdwillmsen/` | <https://github.com/pulls?q=is:open+is:pr+archived:false+user:jdwillmsen> |
| `jdwlabs` | `JDWLABS` | `~/projects/jdwlabs/` | <https://github.com/pulls?q=is:open+is:pr+archived:false+org:jdwlabs> |
| `dotablaze-tech` | `DOTA` | `~/projects/dotablaze-tech/` | <https://github.com/pulls?q=is:open+is:pr+archived:false+org:dotablaze-tech> |

## The map

`~/.config/streams.json` (source: `home/dot_config/streams.json`) is the one
place owners and project keys are written down. Adding a stream is one entry
there; `chezmoi apply` then regenerates `~/.config/claude-jira.json`.

## `stream`

```bash
stream                    # the streams, and where the current repo sits
stream slug               # jdwlabs/platform
stream key                # JDWLABS
stream status             # one row per stream: open PRs, reviews, failing, alerts
stream status jdwlabs     # that stream's PRs with check state, and alerts
```

Read-only against GitHub and Jira. Output is TOON for agents; errors are
structured on stdout with exit 1.

A fork whose `origin` is the upstream repo would resolve to the upstream
owner. Assign it explicitly: `git config stream.owner jdwillmsen`.

## GitHub notification filters

Set once by hand under Notifications → Filters, so the inbox is split by
stream:

| Name | Filter |
|---|---|
| jdwillmsen | `owner:jdwillmsen` |
| jdwlabs | `org:jdwlabs` |
| dotablaze-tech | `org:dotablaze-tech` |

## Jira views

- Each stream has its own board in its own project.
- **Personal stream** filter: `project in (JDW, CAREER)`.
- **All streams** dashboard: every project side by side, for the admin view.

Cross-stream dependencies are issue links (`Blocks`, `Relates`). An Epic lives
in exactly one project.
```

- [ ] **Step 7: Update `docs/shell-helpers.md`**

In `## Worktree locations`, replace `` `~/worktrees/<project>/<type>/<name>` `` with `` `~/worktrees/<owner>/<repo>/<type>/<name>` `` and replace the tree diagram's `└── myapp/` level with:

```
~/worktrees/
└── acme/
    └── myapp/
        ├── feat/auth-jwt/       ← worktree (shell)
        └── fix/null-session/    ← worktree (shell)
```

In the `### ~/.config/claude-jira.json` section, replace the first paragraph (the one beginning "Machine-local and never tracked") with:

```markdown
Machine-local. On a personal machine `chezmoi apply` generates it from the
stream map (`stream jira-config --write`) and marks it with
`"generatedFrom": "streams.json"`. A file without that marker was written by
hand — typically an employer's site on a work machine — and is never
replaced:
```

Add at the end of the file:

```markdown
## `stream` — business stream per GitHub owner

Resolves a repo's `<owner>/<repo>`, its Jira project, and the stream's open
PRs and alerts. See [streams.md](streams.md).
```

- [ ] **Step 8: Run the full test suites**

Run:

```bash
for t in tests/template/*.sh tests/scripts/*.sh; do bash "$t" >/dev/null || echo "FAILED $t"; done
(cd scripts/claude-status && go test ./... )
```

Expected: no `FAILED` line; Go tests `ok`.

- [ ] **Step 9: Commit**

```bash
git add home/dot_config/shell/aliases.sh home/AGENTS.md home/private_dot_claude/CLAUDE.md \
    docs/shell-helpers.md docs/streams.md tests/template/test_shell_files.sh
git commit -m "docs(streams): document streams, their views and the worktree namespace

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Assisted-by: Claude Code:claude-opus-5-5"
```

---

### Task 7: Ship and deploy

**Files:** none.

- [ ] **Step 1: Ship through the pipeline**

Invoke the `no-mistakes` skill from the worktree. PR title: `feat(stream): per-owner work streams for worktrees, Jira and GitHub views`. After the last push, rewrite the PR body to the ~150-word reviewer format in `~/.claude/CLAUDE.md` (Why / Needs attention / Risk / Verified); under *Needs attention* name `home/dot_local/bin/executable_stream` `cmd_jira_config` (the only write) and the `__wt_project` rewrite; under *Verified* include the two PR counts from Task 3 Step 5.

- [ ] **Step 2: Review and merge**

All checks green, every review thread resolved, code-scanning `state=open` empty for the PR, diff read line by line. Rebase-merge.

- [ ] **Step 3: Deploy to this box**

```bash
git -C ~/.local/share/chezmoi pull --ff-only
chezmoi apply -v
```

- [ ] **Step 4: Verify the deployed behaviour**

```bash
cat ~/.config/claude-jira.json                       # projects: CAREER, DOTA, JDW, JDWLABS
(cd ~/projects/jdwlabs/platform && stream slug && stream key)   # jdwlabs/platform / JDWLABS
(cd ~/projects/gameops && stream key)                # JDW
(cd ~/projects/career && stream key)                 # CAREER
stream status --no-alerts                            # three rows
git -C ~/.local/share/chezmoi status --short         # empty
```

Open a new shell, then in `~/projects/jdwlabs/platform` run `gwta chore/stream-smoke`; confirm the path printed is `~/worktrees/jdwlabs/platform/chore/stream-smoke`, then `wtd chore/stream-smoke`.
