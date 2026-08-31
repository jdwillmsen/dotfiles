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
| **caveman** | Token-efficient output mode. | `claudePlugins` marketplace install |

### Deliberately skipped

- **treehouse** (worktree manager) — native `EnterWorktree` plus the `gwta`/`wtd`
  shell helpers already cover this. See `docs/shell-helpers.md`.
- **firstmate** (orchestrator agent driving tmux tabs) — the tmux dependency is
  high-friction on Windows, and the `Agent` tool already covers parallel work.

## Two rules that are not obvious

**Skills are code, and they run with full agent permissions.** Do not install
skills casually off the internet. Two independent failure modes: credential
exfiltration, and quiet performance *degradation* — a 177k-star skill repo
benchmarked as using ~5% more tokens for worse results. Star count says nothing
about whether a skill helps. Every entry in `agentSkills` should be there
because it was read, not because it was popular.

**Keep the global `CLAUDE.md` small.** It loads on every single session, so
every line is a permanent tax. Conditional knowledge belongs in skills, which
load only when relevant (progressive disclosure); reference tables belong in
`docs/`. Grow *project* memory by correcting the agent and having it record the
correction, not by writing speculative rules up front.

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
