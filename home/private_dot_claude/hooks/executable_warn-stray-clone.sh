#!/usr/bin/env bash
# PreToolUse hook on Bash: warns, never blocks, when `git clone`, `gh repo clone` or `git worktree add` puts a checkout
# under ~/projects other than a canonical ~/projects/<owner>/<repo>. Ad-hoc copies there (date- or ticket-suffixed
# clones, worktrees inside a repo) drift from origin and break the devbox map; worktrees belong in
# ~/worktrees/<owner>/<repo>/<branch>. A clone into a new top-level <owner>/<repo> named after the repo stays silent.
#
# It reads command text, so a path spelled through a variable or a subshell is missed; it is a nudge, not a guard.
# Any fault exits 0 with no output, so a broken hook never stops a command.
set -u
trap 'exit 0' ERR

IFS= read -r -d '' input || true

# Runs before every Bash call: anything that cannot be a clone or a worktree add returns without starting a process.
# Only the command string is searched; cwd and transcript_path sit under ~/worktrees in most sessions, so testing the
# whole input would start Python on every call. A quote after a backslash is taken as escaped and the scan goes on,
# which can only widen the text searched, never cut the command short.
rest=${input#*\"command\"}
[[ $rest != "$input" ]] || exit 0
rest=${rest#*\"}
cmd=""
while [[ $rest == *\"* ]]; do
    chunk=${rest%%\"*}
    cmd+=$chunk
    rest=${rest:$((${#chunk} + 1))}
    [[ $chunk == *\\ ]] || break
done
[[ $cmd == *clone* || $cmd == *worktree* ]] || exit 0

PY=python3
"$PY" -c "" >/dev/null 2>&1 || PY=python
# shellcheck disable=SC2016  # the single-quoted block is python source, not shell
printf '%s' "$input" | "$PY" -I -c '
import json, os, re, shlex, sys

CLONE_VALUE_OPTS = {"-b", "--branch", "-o", "--origin", "--depth", "-c", "--config", "--reference",
                    "--reference-if-able", "--template", "-j", "--jobs", "--filter", "--separate-git-dir",
                    "-u", "--upload-pack", "--shallow-since", "--shallow-exclude", "--server-option", "--bundle-uri"}
WORKTREE_VALUE_OPTS = {"-b", "-B", "--reason"}
GIT_VALUE_OPTS = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "|&"}


def expand(path, home):
    if path == "~" or path.startswith("~/"):
        path = home + path[1:]
    return re.sub(r"^\$(HOME|\{HOME\})(?=/|$)", lambda _: home, path)


def resolve(base, path, home):
    return os.path.normpath(os.path.join(base, expand(path, home)))


def repo_name(source):
    name = re.split(r"[/:]", source.rstrip("/"))[-1]
    return name[:-4] if name.endswith(".git") else name


def positionals(args, value_opts):
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            out.extend(args[i + 1:])
            break
        if a.startswith("-") and len(a) > 1:
            if a in value_opts:
                i += 1
        else:
            out.append(a)
        i += 1
    return out


def checkouts(command, cwd, home):
    """Yields (kind, target, source_repo, base_dir) for each clone or worktree add in the command."""
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    segment, segments = [], []
    for tok in lexer:
        if tok in SEPARATORS:
            segments.append(segment)
            segment = []
        else:
            segment.append(tok)
    segments.append(segment)
    here = cwd
    for seg in segments:
        while seg and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", seg[0]) or seg[0] in ("rtk", "command", "exec", "time", "env")):
            seg = seg[1:]
        if not seg:
            continue
        prog = os.path.basename(seg[0])
        if prog == "cd":
            here = resolve(here, seg[1], home) if len(seg) > 1 else home
            continue
        if prog == "gh" and seg[1:3] == ["repo", "clone"]:
            pos = positionals(seg[3:], set())
            if pos:
                yield "clone", resolve(here, pos[1] if len(pos) > 1 else repo_name(pos[0]), home), repo_name(pos[0]), here
            continue
        if prog != "git":
            continue
        base, i = here, 1
        while i < len(seg) and seg[i].startswith("-"):
            if seg[i] == "-C" and i + 1 < len(seg):
                base = resolve(base, seg[i + 1], home)
                i += 1
            elif seg[i] in GIT_VALUE_OPTS:
                i += 1
            i += 1
        sub, rest = (seg[i], seg[i + 1:]) if i < len(seg) else ("", [])
        if sub == "clone":
            pos = positionals(rest, CLONE_VALUE_OPTS)
            if pos:
                yield "clone", resolve(base, pos[1] if len(pos) > 1 else repo_name(pos[0]), home), repo_name(pos[0]), base
        elif sub == "worktree" and rest[:1] == ["add"]:
            pos = positionals(rest[1:], WORKTREE_VALUE_OPTS)
            if pos:
                yield "worktree", resolve(base, pos[0], home), None, base


def tilde(path, home):
    return "~" + path[len(home):] if path == home or path.startswith(home + "/") else path


def main():
    data = json.loads(sys.stdin.read())
    command = (data.get("tool_input") or {}).get("command") or ""
    home = os.path.normpath(os.environ["HOME"])
    projects = os.path.join(home, "projects")
    cwd = data.get("cwd") or os.getcwd()
    warnings = []
    for kind, target, source, base in checkouts(command, cwd, home):
        rel = os.path.relpath(target, projects)
        if rel == ".." or rel.startswith(".." + os.sep):
            continue
        parts = [] if rel == "." else rel.split(os.sep)
        if kind == "clone" and len(parts) == 2 and parts[1].lower() == (source or "").lower():
            continue
        if kind == "worktree":
            brel = os.path.relpath(base, projects).split(os.sep)
            owner, repo = (brel[0], brel[1]) if len(brel) >= 2 and brel[0] != ".." else ("<owner>", "<repo>")
            what = "git worktree add puts a worktree under ~/projects"
        else:
            owner = parts[0] if parts else "<owner>"
            repo = source or "<repo>"
            what = "this clone is not a canonical ~/projects/<owner>/<repo> checkout"
        warnings.append(
            f"{tilde(target, home)}: {what}. ~/projects holds one checkout per repo; for a branch use "
            f"git -C ~/projects/{owner}/{repo} worktree add ~/worktrees/{owner}/{repo}/<branch> -b <branch> origin/main "
            f"(or gwta). If the repo is not cloned yet, clone it once to ~/projects/{owner}/{repo}.")
    if warnings:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                 "additionalContext": "warn-stray-clone: " + " ".join(warnings)}}))


try:
    main()
except Exception:
    pass
' || true
exit 0
