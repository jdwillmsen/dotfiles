# Work Streams Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to run this plan task-by-task in one session. Steps use checkbox (`- [ ]`) syntax for tracking. This is an operations runbook against live state, not a code change: do not parallelise it and do not hand tasks to subagents.

**Goal:** Reorganise Jira, `~/projects`, `~/worktrees` and the open backlog into three per-owner streams, add the all-streams admin view, and leave the box clean.

**Architecture:** Jira structure is created first because it changes nothing existing. Repos and worktrees are then re-homed one repo at a time by a rehearsed script that snapshots state before and after. Open personal-repo tickets move to the new project only after the owner signs off the list. Cleanup deletes nothing without a signed-off inventory. A final dotfiles PR makes the docs match the end state.

**Tech Stack:** bash, git worktrees, `stream` (plan 1), the Atlassian MCP connector, `gh`, chezmoi.

**Spec:** `docs/superpowers/specs/2026-10-07-work-stream-boundaries-design.md`

This is plan 2 of 2. **Precondition:** plan 1 (`2026-10-07-work-streams-tooling.md`) is merged, `chezmoi apply` has run, and `stream slug` works on this box.

## Global Constraints

- Streams and keys, verbatim: `jdwillmsen` → `JDW` (repo `career` → `CAREER`), `jdwlabs` → `JDWLABS`, `dotablaze-tech` → `DOTA`. Site: `https://jdwillmsen.atlassian.net`, cloudId `01f5c783-d91e-4d3f-a99c-b6dbe09da295`.
- Target layout: `~/projects/<owner>/<repo>` and `~/worktrees/<owner>/<repo>/<branch>`.
- **Nothing is deleted without the owner's sign-off on a specific list.** Moves are fine; removals wait.
- **No repo moves while a process has its cwd inside it or any of its worktrees.** The script enforces this; do not bypass it.
- Never run a credential-minting command; hand those to the owner.
- Jira writes happen only after the owner has approved the specific list or object in that task.
- A step that fails verification stops the task. Report it; do not improvise a repair on live repos.
- Run the session from `~/projects/jdwlabs/platform` or `~`: neither moves.
- Status updates give full clickable URLs for every PR and ticket.

## Review Focus

1. **A worktree created by a tool inside the repo** (`.claude/worktrees/*`, `.worktrees/*`) moves with its main checkout and needs `git worktree repair <new path>`, not `git worktree move`. Pinned in Task 2's rehearsal.
2. **Dirty and unpushed work** must be byte-identical after a move. Pinned by the before/after snapshot in Task 2 and re-checked per repo in Task 3.
3. **A live agent session** in the repo being moved loses its cwd. Pinned by the script's `/proc/*/cwd` guard and its rehearsal case.
4. **State keyed by absolute path outside git** — `no-mistakes` gate repos, T3 Code projects, systemd units, tmux. Pinned by the canary in Task 3 Step 2.
5. **A ticket moved to the wrong stream** is cheap to move back but breaks links people follow. Pinned by the owner sign-off gate in Task 5.

---

### Task 1: Jira structure and the all-streams view

**Files:** none (Jira objects only).

**Interfaces:**
- Produces: projects `JDW` and `DOTA`; board "JDWLABS board"; saved filters "Personal stream" and "All streams"; dashboard "All streams"; a tracking Epic in `JDW` whose key later branches use.

- [ ] **Step 1: Find the connector operations**

Call `discover` once each for: `create jira project`, `update jira board name`, `create jira filter`, `create jira dashboard`, `add gadget to jira dashboard`, `move jira issue to another project`. Record which exist. Anything missing becomes a hand-off to the owner in the steps below, with the exact values to enter.

- [ ] **Step 2: Create the projects**

Create two team-managed software projects with the Kanban template:

| Name | Key |
|---|---|
| `jdwillmsen` | `JDW` |
| `dotablaze-tech` | `DOTA` |

If no create-project operation exists, ask the owner to create them at `https://jdwillmsen.atlassian.net/jira/projects?page=1` → Create project → Software → Kanban → Team-managed, with those names and keys.

Then, for each, call `listJiraProjectIssueTypesMetadata` and compare with `JDWLABS` (Epic, Task, Bug, Spike, Subtask). A new team-managed project has no `Spike` type; tell the owner which types are missing and that they are added under Project settings → Work types. Do not proceed to Task 5 until `JDW` has every type used by the issues that will move there.

Verify: `listJiraProjects` returns `CAREER`, `DOTA`, `JDW`, `JDWLABS`.

- [ ] **Step 3: Rename the JDWLABS board**

Rename board id `10` from "KAN board" to "JDWLABS board". If there is no operation for it, ask the owner to rename it from the board's `⋯` menu.

- [ ] **Step 4: Create the saved filters**

| Name | JQL |
|---|---|
| Personal stream | `project in (JDW, CAREER) ORDER BY updated DESC` |
| All streams | `project in (JDW, CAREER, JDWLABS, DOTA) ORDER BY updated DESC` |
| All streams — in progress | `project in (JDW, CAREER, JDWLABS, DOTA) AND statusCategory = "In Progress" ORDER BY project, updated DESC` |

Verify each by running its JQL through `searchJiraIssuesUsingJql` with `searchResultMode: "count"`.

- [ ] **Step 5: Build the All streams dashboard**

Create dashboard "All streams" with these gadgets, top to bottom:

| Gadget | Settings |
|---|---|
| Two Dimensional Filter Statistics | Filter: All streams; X axis: Status; Y axis: Project |
| Filter Results | Filter: All streams — in progress; columns: Key, Summary, Project, Status, Updated; 25 rows |
| Created vs Resolved Chart | Filter: All streams; period: Daily; days: 30 |
| Pie Chart | Filter: All streams, restricted to `statusCategory != Done`; statistic: Project |

If the connector cannot create dashboards or gadgets, give the owner this table and the link `https://jdwillmsen.atlassian.net/jira/dashboards` for a one-time manual build, and continue.

- [ ] **Step 6: File the tracking Epic**

Use the `jira-create` skill to file an Epic in `JDW`: "Separate work into per-business streams across Jira, GitHub and the devbox". Scope: this plan's Tasks 2–8. Acceptance criteria: the spec's Verification section. Record the key as `<EPIC>`; the cleanup PR in Task 7 uses branch `chore/<EPIC>-stream-docs-sweep`.

- [ ] **Step 7: Report**

Give the owner the URLs of both projects, both boards, the three filters and the dashboard.

---

### Task 2: The re-home script, rehearsed

**Files:**
- Create: `<scratchpad>/rehome/rehome-repo.sh`
- Create: `<scratchpad>/rehome/rehearse.sh`

`<scratchpad>` is the session scratchpad directory. The script is single-use; it is not committed.

**Interfaces:**
- Consumes: `stream slug` (plan 1).
- Produces: `rehome-repo.sh <main-checkout> [--dry-run]` — moves the main checkout to `$PROJECTS_BASE/<owner>/<repo>`, re-homes its worktrees under `$WT_BASE` to `$WT_BASE/<owner>/<repo>/<branch>`, renames matching Claude Code project directories, and exits non-zero if the before and after snapshots differ.

- [ ] **Step 1: Write the script**

Create `<scratchpad>/rehome/rehome-repo.sh`:

```bash
#!/usr/bin/env bash
# rehome-repo.sh <main-checkout> [--dry-run]
set -euo pipefail
main="$(cd "$1" && pwd -P)"
dry="${2:-}"
PROJECTS="${PROJECTS_BASE:-$HOME/projects}"
WT="${WT_BASE:-$HOME/worktrees}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

[ "$(git -C "$main" rev-parse --show-toplevel)" = "$main" ] || { echo "refusing: $main is not a repo root"; exit 1; }
[ -d "$main/.git" ] || { echo "refusing: $main is a linked worktree, not the main checkout"; exit 1; }
slug="$(cd "$main" && stream slug)"
case "$slug" in */*) ;; *) echo "refusing: $main has no owner — set git config stream.owner"; exit 1 ;; esac
new_main="$PROJECTS/$slug"
# Some checkouts are pinned by another tool (chezmoi's source dir); those keep
# their place and only their worktrees are re-homed.
[ -z "${KEEP_MAIN:-}" ] || new_main="$main"

do_() { if [ -n "$dry" ]; then printf 'would: %s\n' "$*"; else "$@"; fi; }
# Claude Code names a project directory after the absolute path, with every
# non-alphanumeric character turned into a dash.
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
move_claude_dir() {
    local o n
    o="$CLAUDE_PROJECTS/$(enc "$1")"
    n="$CLAUDE_PROJECTS/$(enc "$2")"
    [ -d "$o" ] || return 0
    if [ -e "$n" ]; then echo "KEEP: $n exists; left $o in place"; return 0; fi
    do_ mv "$o" "$n"
}
busy() {
    local d c
    for d in /proc/[0-9]*; do
        c="$(readlink "$d/cwd" 2>/dev/null)" || continue
        case "$c/" in "$1"/*) echo "pid ${d#/proc/} in $c" ;; esac
    done
}
snapshot() {  # one line per worktree: HEAD, branch, hash of its dirty state
    local w
    git -C "$1" worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r w; do
        [ -d "$w" ] || { echo "missing"; continue; }
        printf '%s|%s|%s\n' "$(git -C "$w" rev-parse HEAD)" "$(git -C "$w" branch --show-current)" \
            "$(git -C "$w" status --porcelain | sha256sum | cut -c1-16)"
    done | sort
}
unpushed() { git -C "$1" log --branches --not --remotes --oneline | wc -l; }
prunable() { git -C "$1" worktree list --porcelain | grep -c '^prunable' || true; }

mapfile -t wts < <(git -C "$main" worktree list --porcelain | sed -n 's/^worktree //p')
for w in "${wts[@]}"; do
    b="$(busy "$w")"
    [ -z "$b" ] || { echo "BUSY, not moving $slug:"; echo "$b"; exit 1; }
done
before="$(snapshot "$main")"
unpushed_before="$(unpushed "$main")"
prunable_before="$(prunable "$main")"

cur="$main"
if [ "$main" != "$new_main" ]; then
    [ ! -e "$new_main" ] || { echo "refusing: $new_main already exists"; exit 1; }
    do_ mkdir -p "$(dirname "$new_main")"
    do_ mv "$main" "$new_main"
    # Worktrees a tool created inside the repo moved with it, so both ends of
    # their link are stale and repair needs their new paths.
    inner_old=() inner_new=()
    for w in "${wts[@]:1}"; do
        case "$w" in "$main"/*) inner_old+=("$w"); inner_new+=("$new_main${w#"$main"}") ;; esac
    done
    [ -n "$dry" ] || cur="$new_main"
    do_ git -C "$cur" worktree repair "${inner_new[@]}"
    move_claude_dir "$main" "$new_main"
    for i in "${!inner_old[@]}"; do move_claude_dir "${inner_old[$i]}" "${inner_new[$i]}"; done
fi

for w in "${wts[@]:1}"; do
    case "$w" in "$WT"/*) ;; *) continue ;; esac
    [ -d "$w" ] || { echo "SKIP (missing on disk): $w"; continue; }
    branch="$(git -C "$w" branch --show-current)"
    [ -n "$branch" ] || { echo "SKIP (detached HEAD): $w"; continue; }
    dest="$WT/$slug/$branch"
    [ "$w" != "$dest" ] || continue
    [ ! -e "$dest" ] || { echo "SKIP (destination exists): $w -> $dest"; continue; }
    do_ mkdir -p "$(dirname "$dest")"
    if do_ git -C "$cur" worktree move "$w" "$dest"; then
        move_claude_dir "$w" "$dest"
    else
        echo "FAILED to move: $w"
    fi
done

[ -z "$dry" ] || { echo "dry run: nothing changed"; exit 0; }
after="$(snapshot "$cur")"
[ "$before" = "$after" ] || { echo "MISMATCH: worktree state changed for $slug"; diff <(echo "$before") <(echo "$after") || true; exit 1; }
[ "$unpushed_before" = "$(unpushed "$cur")" ] || { echo "MISMATCH: unpushed commit count changed for $slug"; exit 1; }
[ "$prunable_before" = "$(prunable "$cur")" ] || { echo "MISMATCH: prunable worktree count changed for $slug"; exit 1; }
echo "OK $slug -> $cur ($(echo "$after" | wc -l) worktrees, $unpushed_before unpushed)"
```

- [ ] **Step 2: Write the rehearsal**

Create `<scratchpad>/rehome/rehearse.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
export PROJECTS_BASE="$t/projects" WT_BASE="$t/worktrees" CLAUDE_PROJECTS="$t/claude"
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
fail() { echo "REHEARSAL FAIL: $1"; exit 1; }

old="$PROJECTS_BASE/demo"
mkdir -p "$PROJECTS_BASE" "$WT_BASE" "$CLAUDE_PROJECTS"
git init -q "$old"
git -C "$old" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$old" remote add origin git@github.com:jdwillmsen/demo.git
git -C "$old" worktree add -q -b feat/JDW-1-a "$WT_BASE/demo/feat/JDW-1-a"
git -C "$old" worktree add -q -b inner "$old/.claude/worktrees/inner"
git -C "$old" worktree add -q --detach "$WT_BASE/demo/detached"
echo dirty >"$WT_BASE/demo/feat/JDW-1-a/untracked.txt"
echo dirty >"$old/.claude/worktrees/inner/untracked.txt"
mkdir -p "$CLAUDE_PROJECTS/$(enc "$old")" "$CLAUDE_PROJECTS/$(enc "$WT_BASE/demo/feat/JDW-1-a")"

bash "$here/rehome-repo.sh" "$old" --dry-run | grep -q 'dry run: nothing changed' || fail "dry run did not report"
[ -d "$old" ] || fail "dry run moved the repo"

# A process sitting in a worktree must block the move.
(cd "$WT_BASE/demo/feat/JDW-1-a" && exec sleep 30) &
sleeper=$!
sleep 0.5
if bash "$here/rehome-repo.sh" "$old" >/dev/null 2>&1; then kill "$sleeper"; fail "moved a repo with a live process in it"; fi
kill "$sleeper"; wait "$sleeper" 2>/dev/null || true
[ -d "$old" ] || fail "busy guard still moved the repo"

bash "$here/rehome-repo.sh" "$old" | tee "$t/out"
new="$PROJECTS_BASE/jdwillmsen/demo"
grep -q '^OK jdwillmsen/demo' "$t/out" || fail "script did not report OK"
[ -d "$new" ] && [ ! -e "$old" ] || fail "main checkout not moved"
[ -f "$WT_BASE/jdwillmsen/demo/feat/JDW-1-a/untracked.txt" ] || fail "external worktree not re-homed with its dirty file"
[ -f "$new/.claude/worktrees/inner/untracked.txt" ] || fail "in-repo worktree lost"
git -C "$new/.claude/worktrees/inner" status >/dev/null || fail "in-repo worktree not repaired"
git -C "$WT_BASE/jdwillmsen/demo/feat/JDW-1-a" status >/dev/null || fail "external worktree broken"
[ -d "$WT_BASE/demo/detached" ] || fail "detached worktree should be left where it was"
git -C "$WT_BASE/demo/detached" status >/dev/null || fail "detached worktree lost its link to the moved main"
git -C "$new" worktree list --porcelain | grep -q '^prunable' && fail "a worktree became prunable"
[ -d "$CLAUDE_PROJECTS/$(enc "$new")" ] || fail "main checkout's Claude project dir not renamed"
[ -d "$CLAUDE_PROJECTS/$(enc "$WT_BASE/jdwillmsen/demo/feat/JDW-1-a")" ] || fail "worktree's Claude project dir not renamed"

# Re-running on an already-homed repo is a no-op.
bash "$here/rehome-repo.sh" "$new" | grep -q '^OK jdwillmsen/demo' || fail "second run was not a clean no-op"
echo "REHEARSAL PASS"
```

- [ ] **Step 3: Run the rehearsal**

Run: `bash <scratchpad>/rehome/rehearse.sh`
Expected: final line `REHEARSAL PASS`.

If it fails, fix the script and re-run until it passes. Do not start Task 3 on a failing rehearsal.

- [ ] **Step 4: Confirm how Claude Code encodes project paths on this box**

Run: `ls ~/.claude/projects | grep -c -- '-home-dev-admin--local-share-chezmoi$'`
Expected: `1` — confirming `/` and `.` both become `-`, which is what `enc` assumes. If it is `0`, find the directory for `~/.local/share/chezmoi`, correct `enc` in both files to match, and re-run Step 3.

---

### Task 3: Re-home repos and worktrees

**Files:** none (moves on disk).

- [ ] **Step 1: Pre-flight inventory**

```bash
for d in ~/projects/*/ ~/projects/jdwlabs/*/ ~/.local/share/chezmoi/; do
    [ -d "$d/.git" ] || continue
    printf '%-55s %-34s wt=%s dirty=%s unpushed=%s\n' "$d" "$(cd "$d" && stream slug)" \
        "$(git -C "$d" worktree list | wc -l)" "$(git -C "$d" status --porcelain | wc -l)" \
        "$(git -C "$d" log --branches --not --remotes --oneline | wc -l)"
done | tee <scratchpad>/rehome/inventory-before.txt
```

Save the output; Task 8 compares against it.

Record every absolute-path reference outside git:

```bash
grep -rIl -e "$HOME/projects/" -e "$HOME/worktrees/" ~/.config ~/.local/share/systemd ~/.no-mistakes \
    ~/.tmux* ~/.t3* 2>/dev/null | grep -v -e '/node_modules/' -e '\.jsonl$' | tee <scratchpad>/rehome/path-refs-before.txt
systemctl --user list-units --type=service --all --no-legend | awk '{print $1}' | while read -r u; do
    systemctl --user cat "$u" 2>/dev/null | grep -H -e '/projects/' -e '/worktrees/' || true
done | tee -a <scratchpad>/rehome/path-refs-before.txt
crontab -l 2>/dev/null | grep -e '/projects/' -e '/worktrees/' || true
```

Read the result. For each file listed, decide whether it holds a path to a repo that is about to move, and note what must be updated after that repo's move. Report the list to the owner before Step 2.

- [ ] **Step 2: Canary — `countdown-app`**

It is small, with two worktrees.

```bash
git -C ~/projects/countdown-app remote -v      # note any `no-mistakes` remote path
bash <scratchpad>/rehome/rehome-repo.sh ~/projects/countdown-app --dry-run
bash <scratchpad>/rehome/rehome-repo.sh ~/projects/countdown-app
```

Expected: `OK jdwillmsen/countdown-app -> /home/dev-admin/projects/jdwillmsen/countdown-app (…)`.

Then verify everything that keys on the path:

```bash
cd ~/projects/jdwillmsen/countdown-app
git worktree list                       # every path exists; none prunable
git status --short && git fetch origin  # still talks to its remote
stream key                              # JDW
no-mistakes --help | head -20           # find its status/doctor subcommand, then run it here
```

Start `claude` in the moved repo, run `/resume`, confirm earlier sessions are listed, and exit. If `no-mistakes` reports the repo as unknown, read `~/projects/jdwillmsen/no-mistakes/README.md` for how a repo is registered, re-register this one, and add that step to every later move in this task. If T3 Code or any file from Step 1 holds the old path, update it and note the fix for later moves.

**Stop and report to the owner** what the canary showed before continuing.

- [ ] **Step 3: Move the remaining `jdwillmsen` repos**

The fork needs its owner assigned first, because its `origin` is upstream:

```bash
git -C ~/projects/no-mistakes config stream.owner jdwillmsen
```

Then, one at a time, in this order, stopping on the first failure:

```bash
for r in career minecraft-afk-bot mc-console-bridge minecraft-server-agent usersrole usersrole-nx no-mistakes gameops; do
    bash <scratchpad>/rehome/rehome-repo.sh ~/projects/$r || break
done
bash <scratchpad>/rehome/rehome-repo.sh ~/projects/jdwlabs/jdw-deployments
```

A `BUSY` line means a session is live in that repo: tell the owner which pid and path, skip that repo, and return to it later. `~/projects/jdwlabs/minecraft-server-agent` is deliberately not in this list — it would collide with the clone just moved; Task 6 handles it.

- [ ] **Step 4: Re-home the worktrees of repos whose main checkout stays put**

```bash
for r in apps deployments infrastructure platform .github .github-private; do
    [ -d ~/projects/jdwlabs/$r/.git ] && bash <scratchpad>/rehome/rehome-repo.sh ~/projects/jdwlabs/$r
done
KEEP_MAIN=1 bash <scratchpad>/rehome/rehome-repo.sh ~/.local/share/chezmoi --dry-run
KEEP_MAIN=1 bash <scratchpad>/rehome/rehome-repo.sh ~/.local/share/chezmoi
```

chezmoi's source dir lives outside `~/projects` by design, so `KEEP_MAIN=1` re-homes only its worktrees, to `~/worktrees/jdwillmsen/dotfiles/<branch>`. Read the dry run first: it must contain no `would: mv /home/dev-admin/.local/share/chezmoi` line.

- [ ] **Step 5: Clone `dotablaze-tech`**

```bash
mkdir -p ~/projects/dotablaze-tech
git clone git@github.com:dotablaze-tech/deployments.git ~/projects/dotablaze-tech/deployments
git clone git@github.com:dotablaze-tech/platform.git ~/projects/dotablaze-tech/platform
(cd ~/projects/dotablaze-tech/platform && stream slug && stream key)   # dotablaze-tech/platform / DOTA
```

- [ ] **Step 6: Verify the whole layout**

```bash
ls ~/projects ~/projects/jdwillmsen ~/projects/jdwlabs ~/projects/dotablaze-tech
for d in ~/projects/*/*/; do
    [ -d "$d/.git" ] || continue
    s="$(cd "$d" && stream slug)"
    [ "$HOME/projects/$s/" = "$d" ] || echo "MISPLACED: $d is $s"
    git -C "$d" worktree list --porcelain | grep -q '^prunable' && echo "PRUNABLE in $d"
done
find ~/worktrees -mindepth 1 -maxdepth 1 -type d | sort
```

Expected: no `PRUNABLE` line; the only `MISPLACED` line is `~/projects/jdwlabs/minecraft-server-agent/`; `~/worktrees` holds `jdwillmsen`, `jdwlabs`, plus whatever old folders still contain detached or skipped worktrees. List those leftovers for Task 6.

---

### Task 4: Report the box state

- [ ] **Step 1: Summarise for the owner**

Report: repos moved, worktrees re-homed, every `SKIP` and `FAILED` line the script printed, what the canary revealed about `no-mistakes` and other path-keyed state, and that per-project trust prompts in Claude Code may reappear once for moved repos because `~/.claude.json` keys projects by path and is not edited here (a live session rewrites that file).

---

### Task 5: Move open personal-repo work from `JDWLABS` to `JDW`

**Files:** none (Jira issues).

- [ ] **Step 1: Build the candidate list**

Fetch every open Epic and every open issue with no parent:

```
project = JDWLABS AND issuetype = Epic AND statusCategory != Done ORDER BY key
project = JDWLABS AND issuetype != Epic AND parent is EMPTY AND statusCategory != Done ORDER BY key
```

For each, read the description (`getJiraIssue`) and decide the stream from the repo it targets — not from where the software runs. Starting classification from the epic list at design time, to be confirmed against each description:

| Epic | Summary | Proposed stream |
|---|---|---|
| JDWLABS-734 | Harden gameops delivery | `JDW` (`jdwillmsen/gameops`) |
| JDWLABS-697 | Agent tooling usage audits | `JDW` (`jdwillmsen/dotfiles`) |
| JDWLABS-658 | Live FWB world map | `JDW` (`jdwillmsen/gameops`) |
| JDWLABS-644 | @server correct game answers | `JDW` (`jdwillmsen/gameops`) |
| JDWLABS-607 | Park and restore FWB actors | `JDW` (`jdwillmsen/gameops`) |
| JDWLABS-575 | FWB Bedrock tick performance | `JDW` — confirm repo |
| JDWLABS-548 | Maximize T3 throughput | `JDW` (`jdwillmsen/dotfiles`) |
| JDWLABS-420 | Split usersrole JVM monolith | ask the owner — confirm which repo holds the Go services |
| JDWLABS-678, 668, 616, 131, 14 | org platform, apps, governance | stay in `JDWLABS` |

For each Epic proposed to move, count its open and Done children:

```
parent = <KEY> AND statusCategory != Done
parent = <KEY> AND statusCategory = Done
```

- [ ] **Step 2: Get sign-off**

Present one table: key, summary, proposed stream, the repo that decided it, open children that move with it, Done children that stay behind. State plainly that moved issues get new `JDW-` keys, old keys redirect, and Done children left in `JDWLABS` lose their parent link to a moved Epic (they keep a `Relates` link, added in Step 4). **Wait for the owner's explicit approval of the list.** Apply any changes they make.

- [ ] **Step 3: Move**

For each approved Epic, move the Epic and its open children to `JDW`, using the move operation found in Task 1 Step 1. If the connector has none, save a filter "Move to JDW" with JQL `key in (<all approved keys and their open children>)` and ask the owner to use Jira's bulk move on it (filter → `⋯` → Bulk change → Move), keeping issue types and mapping statuses by name; then continue from Step 4.

- [ ] **Step 4: Repair links and record the old keys**

For each moved issue, add a comment `Moved from <old key> when work was split into per-business streams.` For each Done child left behind in `JDWLABS`, create a `Relates` link to its former Epic's new key.

- [ ] **Step 5: Verify**

```
project = JDWLABS AND statusCategory != Done AND (text ~ "gameops" OR text ~ "minecraft" OR text ~ "dotfiles" OR text ~ "chezmoi")
```

Read every hit: each must be org work that merely mentions a personal repo, or be reported to the owner as a missed candidate. Confirm `project = JDW` returns the moved count, and give the owner the JDW board URL.

---

### Task 6: Cleanup, each item behind a signed-off inventory

**Files:** removals on disk, after sign-off.

- [ ] **Step 1: Build the inventory**

Collect, without changing anything:

```bash
cd ~
echo "== ~/projects root clutter"; ls -la ~/projects | grep -v -e ' jdwillmsen$' -e ' jdwlabs$' -e ' dotablaze-tech$'
git -C ~/projects log --oneline 2>&1 | head -1        # expect: no commits yet
echo "== ~/projects/test"; ls -la ~/projects/test; git -C ~/projects/test status --short | head
echo "== duplicate minecraft-server-agent"
a=~/projects/jdwlabs/minecraft-server-agent; b=~/projects/jdwillmsen/minecraft-server-agent
git -C "$a" status --short; git -C "$a" worktree list
git -C "$a" for-each-ref --format='%(refname:short) %(objectname)' refs/heads | while read -r br sha; do
    git -C "$b" cat-file -e "$sha" 2>/dev/null || echo "ONLY IN DUPLICATE: $br $sha"
done
echo "== archived-repo clones"
for r in minecraft-afk-bot mc-console-bridge minecraft-server-agent usersrole usersrole-nx; do
    d=~/projects/jdwillmsen/$r
    echo "$r dirty=$(git -C "$d" status --porcelain | wc -l) unpushed=$(git -C "$d" log --branches --not --remotes --oneline | wc -l)"
done
echo "== merged worktrees"
for d in ~/projects/*/*/; do [ -d "$d/.git" ] && (cd "$d" && bash -ic 'wtclean -n' 2>/dev/null | sed "s|^|$(basename "$d"): |"); done
echo "== old worktree folders"; find ~/worktrees -mindepth 1 -maxdepth 1 ! -name jdwillmsen ! -name jdwlabs ! -name dotablaze-tech
echo "== empty worktree dirs"; find ~/worktrees -mindepth 1 -type d -empty
echo "== stale Claude project dirs"; ls ~/.claude/projects | grep -e '^-home-dev-admin-Dev-' | head -50
```

- [ ] **Step 2: Present it and get sign-off**

One table per category: what it is, what would be removed, what would be lost (uncommitted files by name, unpushed commits by `git log --oneline`). For the duplicate clone and each archived clone with unpushed commits, the default proposal is **rescue first**: push the branch to the repo's remote as `rescue/<branch>` (archived repos must be unarchived to accept a push — ask before doing that) or keep the clone. **Wait for the owner's decision per category.** Remove nothing they did not approve.

- [ ] **Step 3: Apply the approved removals**

Use the approved list only. Worktrees go through `wtd` / `wtclean -y` in their repo, never `rm -rf`. Whole clones are removed with `rm -rf` only after their rescue step, if any, is verified on the remote with `git ls-remote`. The empty `~/projects/.git` is removed with `rm -rf ~/projects/.git` once `git -C ~/projects log` has confirmed it has no commits. Empty worktree directories: `find ~/worktrees -mindepth 1 -type d -empty -delete`.

- [ ] **Step 4: Verify**

```bash
ls -la ~/projects            # only the three owner folders, plus anything the owner chose to keep
ls ~/worktrees               # only owner folders
for d in ~/projects/*/*/; do [ -d "$d/.git" ] && git -C "$d" worktree prune -n; done   # prints nothing
```

---

### Task 7: Docs sweep — one dotfiles PR, plus per-repo fixes

**Files:**
- Modify: `home/AGENTS.md` (`## Projects` section) in dotfiles
- Modify: `home/dot_local/bin/executable_agent-audit:40` (`JIRA_PROJECT`) — only if JDWLABS-697 moved in Task 5
- Modify: any file the sweep finds

- [ ] **Step 1: Start a worktree from fresh main**

```bash
cd ~/.local/share/chezmoi && git fetch origin && gwta chore/<EPIC>-stream-docs-sweep
```

- [ ] **Step 2: Rewrite the devbox map**

In `home/AGENTS.md`, replace the `## Projects — …` heading and its body with:

```markdown
## Projects — `~/projects/<owner>/<repo>`

One grouping folder per GitHub owner; each owner is a separate business
stream with its own Jira project and board (dotfiles `docs/streams.md`).

- `~/projects/jdwillmsen/` — personal projects and brand, `JDW`; the `career`
  repo files to `CAREER`.
- `~/projects/jdwlabs/` — the `jdwlabs` org, `JDWLABS`: `apps/`,
  `deployments/`, `infrastructure/`, `platform/`. Independent sibling repos,
  not a monorepo.
- `~/projects/dotablaze-tech/` — the `dotablaze-tech` org, `DOTA`.

A repo's folder, worktree namespace and Jira project all follow its GitHub
owner. Streams reference each other with Jira issue links, never by sharing
an Epic.
```

- [ ] **Step 3: Point the audit at its Epic's new project**

If JDWLABS-697 moved to `JDW` in Task 5, change line 40 of `home/dot_local/bin/executable_agent-audit` to `JIRA_PROJECT = "JDW"`, update the matching expectation in `tests/scripts/test_agent_audit_script.sh` (search it for `JDWLABS`), and run `bash tests/scripts/test_agent_audit_script.sh` → `PASS`. If it did not move, leave both alone.

- [ ] **Step 4: Sweep dotfiles for the old layout**

```bash
grep -rnI -e 'projects/career' -e 'projects/gameops' -e 'projects/countdown' -e 'projects/no-mistakes' \
    -e 'projects/jdwlabs/jdw-deployments' -e 'worktrees/<project>' -e 'Dev/projects' . \
    | grep -v -e '^./docs/superpowers/' -e '^./.git/'
```

Fix every hit to the new path. Historical specs and plans under `docs/superpowers/` are records and stay as written.

- [ ] **Step 5: Sweep each repo's agent docs**

```bash
for d in ~/projects/*/*/; do
    grep -nI -e '~/projects/' -e '~/worktrees/' -e 'home/dev-admin/projects' "$d"AGENTS.md "$d"CLAUDE.md "$d"docs/*.md 2>/dev/null \
        | sed "s|^|$(basename "$d"): |"
done
```

For each stale path, open a small `docs/` PR in that repo (its own worktree and branch, keyed to that repo's stream project). Archived repos are skipped.

- [ ] **Step 6: Run the suites, ship, deploy**

```bash
for t in tests/template/*.sh tests/scripts/*.sh; do bash "$t" >/dev/null || echo "FAILED $t"; done
```

Expected: no `FAILED` line. Ship with the `no-mistakes` skill, review and rebase-merge, then `git -C ~/.local/share/chezmoi pull --ff-only && chezmoi apply -v`.

---

### Task 8: Final verification against the spec

- [ ] **Step 1: Run every check in the spec's Verification section**

```bash
(cd ~/projects/jdwillmsen/gameops && stream key)       # JDW
(cd ~/projects/jdwlabs/platform && stream key)         # JDWLABS
(cd ~/projects/jdwillmsen/career && stream key)        # CAREER
(cd ~/projects/dotablaze-tech/platform && stream key)  # DOTA
stream status                                          # three rows
chezmoi verify && git -C ~/.local/share/chezmoi status --short   # both silent
```

Compare unpushed-commit and dirty counts per repo against `<scratchpad>/rehome/inventory-before.txt`; every moved repo must match. In one repo per stream, `gwta chore/verify-stream` must create under `~/worktrees/<owner>/<repo>/chore/verify-stream`; remove it with `wtd`. In `gameops`, start `cj` on a `JDW-` branch and confirm the session is named after the ticket.

Open the All streams dashboard and confirm all four projects appear. Confirm each stream's PR count from `stream status` against its saved search URL in `docs/streams.md`.

- [ ] **Step 2: Hand over the manual items**

Give the owner the GitHub notification filters table from `docs/streams.md` to add under Notifications → Filters, and any dashboard or project-settings step that was handed off in Task 1.

- [ ] **Step 3: Close out**

Report to the owner with full URLs: both dotfiles PRs, every per-repo docs PR, the tracking Epic, the four boards, the dashboard. List anything skipped and why. Close the Epic only when every acceptance criterion is checked.
