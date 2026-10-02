# Agentic Workflow — the captain model

Working model adopted from Kun Chen's *L8 Principal's Agentic Engineering
Workflow* (YouTube `iQyg-KypKAA`). The `## Working Principles` section of the
global `CLAUDE.md` is the enforced summary; this file is the reasoning behind it
and the inventory of what is installed, what was skipped, and why.

## The thesis

Agents write faster than a human can review, so **the human is the bottleneck**.
The response is to stop working like an engineer and start working like an
engineering manager: spend your attention at the **start** (planning,
requirements, design) and the **end** (verification, quality bar), and let
agents own the middle. Run independent work in parallel rather than serially.

The corollary that is easy to miss: *don't optimise for development cost*.
Models inherit human time-estimates from their training data and will quietly
choose the cheap, low-quality path unless told the tradeoff is different. Correctness
and review cost dominate; generation cost is close to free.

"Let agents own the middle" only holds if the agent can keep running when you
stop watching. A devbox worked from over plain SSH doesn't survive closing the
laptop; see [`persistence.md`](persistence.md) for the tmux/linger/continuum
stack that turns the devbox into a persistent host any client can attach to
and walk away from.

## What is installed, and how it is enforced

Everything below is provisioned from this repo. Nothing here should require a
manual step on a new machine.

| Tool | Role | Enforced by |
|---|---|---|
| **AXI** (`axi`, `axi-quickref` skills) | Design standard for any CLI an agent drives. 10 principles; TOON output is ~40% cheaper than JSON. | `axi` via `agentSkills`; `axi-quickref` is hand-written and vendored in `private_dot_claude/skills/` |
| **no-mistakes** | Validation pipeline: branch → commit → isolated worktree → infer intent → rebase → adversarial review → e2e test with evidence → docs → lint → push → PR → babysit until merged. | CLI via `agentClis`, pinned to a version declared there; its `/no-mistakes` skill is installed by `no-mistakes init`, not by the skills CLI |
| **lavish** | Interactive HTML planning artifacts instead of a wall-of-text plan. | Skill via `agentSkills`; the CLI itself runs through `npx -y lavish-axi`, so nothing is installed |
| **gnhf** | Long-running unattended loop with hard token/iteration caps. Built for overnight runs. | CLI via `agentClis`, pinned to a version declared there |
| **whisper-local** | Local voice input. The highest-leverage single change — dictation is roughly 3× typing throughput. | `run_onchange_after_50-install-whisper-local.sh.tmpl` |
| **mattpocock/skills** | General engineering skills (tdd, diagnosing-bugs, code-review, …). | `claudePlugins` marketplace install; loads namespaced as `mattpocock-skills:*` |
| **caveman** | Token-efficient output mode, off by default; `/caveman` turns it on for a session. | `claudePlugins` marketplace install; default mode `off` in `dot_config/caveman/config.json` (and the `AppData/Roaming` copy on Windows) |
| **RTK** | Hook-rewritten command proxy that compresses shell output 60–90%. `rtk gain [--history]` shows savings, `rtk discover` finds missed commands, `rtk proxy <cmd>` bypasses filtering. If `rtk gain` fails, `which rtk` may be reachingforthejack/rtk (Rust Type Kit), a name collision. | `run_once_40-install-rtk.sh`; `rtk hook claude` PreToolUse hook in `modify_settings.json.json.tmpl`; agent-facing summary in `private_dot_claude/RTK.md` |

### Deliberately skipped

- **treehouse** (worktree manager) — native `EnterWorktree` plus the `gwta`/`wtd`
  shell helpers already cover this. See `docs/shell-helpers.md`.
- **firstmate** (orchestrator agent driving tmux tabs) — the tmux dependency is
  high-friction on Windows, and the `Agent` tool already covers parallel work.

### Installed but disabled

These plugins stay in `claudePlugins.install`, so re-enabling one is a
one-line flip, but `modify_settings.json.json.tmpl` forces them to `false` in
`enabledPlugins`. Each loaded skills or agents into every session's context.
Usage figures are from a 30-day transcript review.

- **learning-output-style** — 0 uses; its output style conflicts with the
  global CLAUDE.md.
- **pr-review-toolkit** — 9 uses for 6.6 KB of always-loaded agent
  descriptions; overlaps the built-in `/code-review`.
- **ralph-loop** — 0 uses; replaced by the built-in `/loop`.
- **remember** — duplicates the built-in auto-memory. Its `~/.remember` data
  stays on disk.
- **gopls-lsp**, **typescript-lsp** — 0 LSP calls.
- **claude-code-setup**, **commit-commands**, **frontend-design** — 0 skill
  invocations.

`skillOverrides` cannot trim inside a plugin: Claude Code ignores it for plugin
skills under any key spelling (`tdd`, `mattpocock-skills:tdd`, …). The
**skill-trim** mod (`~/.claude/mods/skill-trim`, loaded in every session by
`CLAUDE_CODE_PLUGIN_DIRS` in the settings template) does it instead: a
`prompt.attachment` hook drops 15 unused atlassian, mattpocock-skills and
superpowers skills from the skill listing, and they still run when invoked by
name. A `classic.SessionStart` hook swaps superpowers' 3.4 KB
`<EXTREMELY_IMPORTANT>` bootstrap for a 551 B version with the same routing
(check for a matching skill first, process skills before implementation ones,
CLAUDE.md wins); a controlled run on superpowers' issue tracker found the calm
wording fired the right skill as often as the original. Together that is about
8.4 KB less context per session.

Edit `home/private_dot_claude/mods/skill-trim/hooks/register.js` in the
chezmoi source, never the deployed copy, then run `chezmoi apply -v` before
`claude plugin test` in `~/.claude/mods/skill-trim`. The bootstrap is replaced
only when it hashes to the pinned superpowers 6.4.1 fingerprint
(`KNOWN_BOOTSTRAP_SHA256`). After a superpowers update that changes it, the
verbose upstream text comes back and the mod logs one line per session; review
the new text, then refresh the hash (`tests/template/test_skill_trim_mod.sh`
prints the live value when it differs).

**caveman** stays enabled so `/caveman` and the cavecrew agents work, but its
default mode is `off`. Measured net cost was about −$9 to −$13/month: Opus
ignores the rules (article rate 9.9 per 100 words against an 8.85
uncompressed baseline), and prose is only 4–6% of output tokens, so the
always-loaded ruleset cost more than it saved.

### claude.ai connectors denied in Claude Code

`deniedMcpServers` in the settings template blocks **claude.ai Gmail** and
**claude.ai Atlassian Rovo** (the latter duplicates the `atlassian` plugin's
MCP server). They stay connected on claude.ai; only Claude Code stops loading
them. Claude Docs and Google Drive stay enabled.

## Rules that are not obvious

**Skills are code, and they run with full agent permissions.** Do not install
skills casually off the internet. Two independent failure modes: credential
exfiltration, and quiet performance *degradation* — a 177k-star skill repo
benchmarked as using ~5% more tokens for worse results. Star count says nothing
about whether a skill helps. Every entry in `agentSkills` should be there
because it was read, not because it was popular.

**Rebase merge only.** Every repo has squash and merge commits disabled on the
GitHub side. Each commit reaching `main` stands alone, so `git blame` and
`git log -S` land on the commit that explains the line instead of a squashed
blob — which is why tidying a messy branch is the author's job before merging,
not the merge button's.

**Keep the global `CLAUDE.md` small.** It loads on every single session, so
every line is a permanent tax. Conditional knowledge belongs in skills, which
load only when relevant (progressive disclosure); reference tables belong in
`docs/`. Grow *project* memory by correcting the agent and having it record the
correction, not by writing speculative rules up front.

Instruction files stack: `~/.claude/CLAUDE.md` (+ `RTK.md`) and `~/AGENTS.md`
load for every Claude session under `$HOME`, then the repo's own `AGENTS.md`.
Cross-repo rules belong in the global file only; repo files state repo facts.
Codex reads `~/.codex/AGENTS.md` plus `AGENTS.md` files from the git root down
to the working directory, so inside a repo it never sees `~/AGENTS.md`; its
global file therefore carries its own copy of the security-relevant devbox
rules.

## Skill provisioning: three mechanisms, one source of truth

There are three legitimate ways a skill arrives, and mixing them up is how the
same skill ends up installed twice and loaded twice:

1. **`agentSkills`** in `.chezmoidata.yaml` — one skill extracted from a repo
   that is mostly something else, via the vercel-labs `skills` CLI.
2. **`claudeSkillsDir`** — a whole repo of skills cloned as a namespaced unit.
3. **Vendored** in `private_dot_claude/skills/` — hand-written, no upstream.

A skill must appear in exactly one of these. `run_onchange_33-install-agent-skills.sh`
reports anything installed but undeclared rather than deleting it, so drift is
visible without being destructive; it does delete dangling symlinks, which are
always a bug (a skill Claude Code lists but cannot read).
