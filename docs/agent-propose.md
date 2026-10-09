# Agent propose

`~/.local/bin/agent-propose` turns findings from the newest
[agent report](agent-report.md) into one reviewable pull request against this
repo, unattended. The findings are arithmetic; a model only edits files, inside
limits this tool enforces, and never writes a commit message, a PR, a comment
or anything that is executed. The design is in
`docs/superpowers/specs/2026-10-09-agent-propose-design.md`.

```sh
agent-propose                                 # history counts and next steps
agent-propose run --window weekly --dry-run   # findings, gates, planned caps; changes nothing
agent-propose run --window weekly             # author, review, open the PR
agent-propose run --window weekly --dry-run --report FILE   # preview a report outside the store
agent-propose verify [--dry-run]              # judge findings merged 14 or more days ago
```

Exit codes: 0 success, including a run a gate stopped; 1 runtime failure (a
failed PR, an aborted run, a failed push of the store); 2 usage or setup error.

## The flow of a run

1. **Read.** The newest stored report for the window, the config inventory it
   embeds (a daily report embeds none, so the newest stored one stands in),
   and the window's session rows.
2. **Find.** Deterministic finders (below) return findings. A finding is
   critical when its estimated effect is 5% or more.
3. **Remember.** Outcomes of earlier proposals are refreshed from GitHub and
   rule out what was already turned down.
4. **Gate.** See below. `--dry-run` stops here and prints everything.
5. **Author.** A fresh worktree of the freshly fetched base branch, on
   `chore/agent-audit-<UTC date>`, under `~/.local/state/agent-metrics/propose/worktrees/`.
   One model call per finding edits one file. The tool then checks the edit,
   commits it with a message it composes, and runs the script tests that name
   the changed file. Anything that fails is discarded with a reason code.
6. **Review.** One read-only call on the reviewing model sees the branch diff
   and returns approve or reject per commit. The branch is rebuilt from the
   approved commits; a patch that no longer applies is dropped.
7. **Deliver.** The branch is pushed and one PR opened, labelled
   `agent-audit`. History is written and the store published. The worktree
   and local branch are removed.

If nothing survives, no branch is pushed and no PR opened.

## Findings

| Finder | Fires when | Effect | Proposes |
|---|---|---|---|
| `unused-plugin:<name>` | an enabled plugin has no skill, agent or MCP call in the window's session rows and its hooks injected context | its injected bytes as a share of all injected bytes | disabling it in `home/private_dot_claude/modify_settings.json.json.tmpl` |
| `oversize-instructions:<path>` | an always-loaded instruction file is over 200 lines, or a `MEMORY.md` over 200 lines or 25 KiB | the share of the file above the limit | trimming it; no replacement text is supplied |
| `unattributed-sessions:interactive` | more than half of at least five interactive sessions started outside any repo | the distance to the threshold, in points | a rewording in `home/AGENTS.md` so sessions start in a repo worktree |
| `weekly-quota-peak:<window>` | the weekly plan quota peaked at or above the budget cut-off in this window and the previous one | points above the cut-off | nothing: `needs_human` |

A plugin that provides only hooks is never invoked by name, so it is not a
candidate. An instruction file this repo does not deploy (a `MEMORY.md`,
another repo's `AGENTS.md`) is reported as `needs_human` too. Findings marked
`needs_human` are listed in the output and in the PR body and are never edited.

Trend-based findings are not implemented: `find_trends` returns nothing until
the store holds a month of variance to judge a movement against.

Findings are ranked by effect; a run takes at most `max_findings` (4), and a
daily run takes critical ones only.

## Gates

In order; each stops the run cleanly with `result: stopped` and the reason.

| Gate | Stops when |
|---|---|
| store | the store is not cloned (exit 2) |
| open-pr | an `agent-audit` PR is open. A daily run with a critical finding instead adds its commits to that PR and leaves one comment listing them |
| budget | `agent-metrics` would not allow the run's whole cap; over the plan, only a run with a critical finding may spend |
| review-gate | the base branch requires an approving review, by ruleset or classic protection, or that could not be read. Such a PR must be opened as the bot ([`bot-authored-prs.md`](bot-authored-prs.md)), which this tool does not do |
| repo | today's branch already exists on the remote, or the base branch does not carry the checker |

A failed GitHub query is a failure, not a pass.

## What the model can and cannot do

Each call is `claude -p --restricted` with a turn cap, a dollar cap, a
wall-clock timeout, no session persistence, no MCP server, no skills, and the
environment minus credential-shaped variables. Restricted mode ignores every
settings file and confines the file tools to the working directory.

| | Author | Reviewer |
|---|---|---|
| Model | `author_model` (Sonnet) | `review_model` (Opus) |
| Tools | `Read,Glob,Grep,Edit` | `Read,Glob,Grep` |
| Permission mode | `acceptEdits` | `dontAsk` |
| Prompt | the finding's numbers and identifiers plus fixed rules | fixed rules, the findings, the branch diff |
| Output used | the file edit only; its reply is discarded | one `{finding_id, verdict, reason}` per commit, schema-validated |

It cannot run a command, reach the network, commit, push, or write outside the
worktree. Its text never reaches a commit message, PR title or body, comment,
branch name, log line or stored file. A review reply that is not exactly one
valid entry per finding approves nothing.

After each edit the tool applies, in order:

1. **Containment.** The sandbox directory, the owner's checkout, the store,
   the config directory and the worktree's `.git` pointer must be as they were.
   If not, the run aborts with nothing shipped (`outside_worktree`, exit 1).
2. **The checker**, `scripts/check-agent-diff`, read from the base branch.
3. **A shape rule.** The settings source is a script that tests and a later
   apply execute, so an edit there must be exactly the one
   `"<plugin>@<marketplace>": false` line (plus a comma on its neighbour). A
   trim must leave the file smaller.
4. **Tests.** Script tests under `test_globs` whose text names the changed
   file. A failure drops the commit.

Reason codes: `timeout`, `spawn_failed`, `claude_exit`, `claude_error`,
`no_change`, `no_effect`, `shape`, `outside_worktree`, `checker_error`,
`tests_failed`, `review_rejected`, `review_failed`, `patch_conflict`,
`pr_failed`, and the checker's own.

## The checker and protected paths

`scripts/check-agent-diff BASE HEAD` is the one implementation both this tool
and CI use. CI runs the base branch's copy with `--each-commit` on every pull
request, judging each commit that carries a `Finding:` trailer against its
parent. It fails, naming the file and a code, when a diff:

- touches a protected path (`protected_path`): `.github/`, `.claude/`,
  `.mcp.json`, `.gitattributes`, chezmoi control files, rulesets, key and
  secret material by name, `budget.json`, `propose.json`, `thresholds.json`,
  the checker itself, and the `protected_paths` globs in `propose.json`
  (scripts, tests, run scripts, the tools, the units, git config);
- touches permissions in the Claude settings source (`protected_settings_block`);
- adds invisible or bidirectional characters (`invisible_unicode`), or any
  non-ASCII outside prose files (`non_ascii`);
- makes an always-loaded instruction file larger in lines or bytes
  (`instruction_growth`) or adds an `@` import to one (`instruction_import`);
- changes a hook, an `ANTHROPIC_*`, proxy or base-URL setting, or an MCP
  server (`hook_change`, `env_change`, `mcp_change`) without `[!strict]` in
  the commit subject;
- changes a file mode, or adds a symlink or binary (`mode_change`, `symlink`,
  `binary`).

The tool sets `[!strict]` only for a finder listed in `strict_finders`
(default: none), and then also applies the `strict-review` label and runs no
test on that commit. The marker never unlocks a protected path.

## Dropping a finding

Remove its commit from the PR branch before merging (each commit stands
alone). On the next run the PR is seen as merged without that `Finding:`
trailer and the finding is recorded as `dropped`. Closing the PR unmerged
records every finding in it as `closed`. Either way it is not proposed again
for `rejection_memory_days` (90). A merged finding rests for 30 days, and one
this tool rejected is not retried for 30.

History is `findings/history.jsonl` in the store: one row per proposed
finding with `id`, `proposed_at`, `pr`, `branch`, `commit_subject`, `outcome`
(`pending`, `open`, `merged`, `dropped`, `closed`, `rejected`), the finding's
numbers, and later `verdict`, `before`, `after`.

## Verify

`agent-propose verify` takes each merged finding whose merge is at least 14
days old and has no verdict, measures its metric over the 14 days before and
after the merge, and records `hit` (it fell) or `miss` with both numbers. The
unattributed share comes from session rows; hook bytes and instruction sizes
come from stored report inventories whose window lies inside each fortnight.
With no data on either side the finding stays unjudged. Misses are listed as
revert candidates. It calls no model, and runs after every scheduled run.

## Spending

`~/.config/agent-metrics/propose.json` holds the caps: a daily run $3.00, a
weekly run $5.00, a monthly run $10.00; each authoring call $0.50; the review
$3.00 or what the run has left, and never less than $1.00. Every call is gated
by `agent-metrics`, booked at its cap in the ledger as `propose-<window>`
before it starts, and rewritten to the reported cost after. A timeout or a
reply without a cost stays charged at the cap. The run stops before any call
that could take its total past the run cap. `propose.json` also holds the repo
path, slug, base branch, models and protected paths; it is not for agents to
edit and the checker refuses changes to it.

## Scheduling

`agent-propose@.service` runs `agent-report --window %i`, then the run, then
`verify`. `run_onchange_57-enable-agent-propose.sh.tmpl` enables the timers on
a home apply without starting a run.

| Timer | Fires |
|---|---|
| daily | every day 07:40 |
| weekly | Monday 10:00 |
| monthly | the 1st, 10:30 |

All are `Persistent=true` and sit after the matching report timers.

```sh
systemctl --user list-timers 'agent-propose-*'
journalctl --user -u 'agent-propose@*' -n 50
```
