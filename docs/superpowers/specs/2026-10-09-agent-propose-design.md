# Agent propose: audit findings as one reviewed pull request

Date: 2026-10-09. The proposing piece of the workflow audit loop: the
proposer, its diff checker and the verify step. Usage is in
`docs/agent-propose.md`.

## Goal

Turn what the reports measure into small config changes a person can review
in one PR, unattended, without trusting the model that writes the edits.

## Threat model

The editing model reads the repository, so text in it can steer the model;
reports, the store and GitHub replies can hold hostile values. Therefore:

- Findings come from arithmetic in this tool. No model decides what to change.
- Model output is used in two forms only: file edits that pass the checker
  and the shape rule, and review verdicts that pass an exact schema check.
  It is never executed and never placed in a commit message, PR text,
  comment, branch name, log line or stored file.
- Every string on a `git` or `gh` command line is a constant, a number, or an
  identifier matched against a pattern here. No shell string is ever built.
- The worktree lives under a directory only this tool writes to. Git is
  addressed by an explicit git dir, so the worktree's own `.git` pointer,
  which the model could edit, is never trusted.
- No failure leaves a pushed branch without a PR, an open PR without history,
  or spend without a ledger entry.

## Decisions taken from the brief

- One stdlib file, loading `agent-metrics` as a library like `agent-report`.
- Gates in order: store, open audit PR, budget for the run's whole cap.
- Four finders and a trend stub; critical at an effect of 5% or more.
- History in `findings/history.jsonl`; a dropped or closed finding stays away
  90 days.
- One restricted call per finding, one commit per finding composed by the
  tool with `Finding`, `Expected-effect`, `Evidence` and attribution trailers.
- One review call returning enum verdicts; the branch is rebuilt from the
  approved patches.
- One PR labelled `agent-audit`; a critical daily run appends to an open one.
- Cap-first ledger booking, exactly as `agent-report` does.
- One checker used by the tool and by CI.

## Decisions the brief left open, or where it was changed

- **The approval check is a gate, before any spend.** The brief placed it
  just before opening the PR. Authoring first would spend up to the run cap
  on a branch that could then not be opened.
- **The checker is read from the base branch**, both here and in CI, so
  neither a model edit nor the PR under test can loosen its own rules. A base
  without it stops the run (`no-checker`).
- **A shape rule, in the checker.** The Claude settings source is a
  `modify_` script: chezmoi executes it, and so does the repo's settings
  test. Running tests on a model-edited script would execute model output.
  So an edit there must be exactly one `"<plugin>@<marketplace>": false` data
  line, whose allowed characters cannot leave the quoted JSON. The brief's
  "no model output is ever executed" wins over "the model edits the settings
  file" wherever they meet.
- **Per-finding rules live in the checker.** A commit with a `Finding:`
  trailer is held to its finder's one file, the line cap and the shape, all
  read from `propose.json` at the base revision, so CI and the tool make the
  same check. This is what keeps tests and scripts out of reach even where no
  protected pattern lists them.
- **Strict changes are opt-in per finder** (`strict_finders`, default empty).
  No v1 finder needs to change a hook, API environment setting or MCP server,
  so by default such an edit is rejected. When a finder is opted in, the
  commit gets `[!strict]` and the label, and no test is run on it.
- **Writes outside the worktree are prevented by the CLI and detected here.**
  `--restricted` confines the file tools. After each call the tool compares
  the sandbox directory, the owner's checkout, the store, the config
  directory and the `.git` pointer with what they were; a difference aborts
  the run. It cannot see a write elsewhere on disk, and a concurrent edit by
  the owner in the checkout also aborts the run.
- **The edit tool only.** `Write` is left out: no v1 change needs a new file.
- **Non-ASCII is refused everywhere but prose files**, which is simpler and
  stricter than listing hook, settings and shell files.
- **An `@` import added to an instruction file fails**, since it grows what
  every session loads without growing the file.
- **`.claude/`, `.mcp.json`, `.gitattributes` and chezmoi control files are
  protected**: the first two would configure the next call in the same
  worktree, the third can hide a diff, the last change what an apply runs.
- **Instruction edits cannot grow the file**, so the worktree-steering
  finding asks for a rewording in place. The prompt says so.
- **Effect definitions.** Plugin: share of injected bytes. Oversize file:
  share of the file above the limit. Unattributed sessions: points above the
  threshold, with at least five interactive sessions. Quota: points above the
  cut-off. The last three are the brief's "estimated effect" made concrete.
- **Plugins that provide only hooks are skipped**: they are never invoked by
  name, so zero invocations is no evidence.
- **Instruction files this repo does not deploy are `needs_human`**; the
  mapping from deployed path to source file is `instruction_sources`.
- **The quota finder reads the previous window from the same report**, which
  holds the same numbers as the previous stored report.
- **A daily report has no inventory**, so the newest stored one is used.
- **Test relevance** is "the test's text names the changed file", by path or
  file name, the rule `test_shell_script_coverage.sh` uses for coverage.
  Tests are listed by glob and run with `bash`, never through a shell string.
- **The review's share of the cap.** Authoring a finding is allowed only
  while its cap plus a $1.00 review floor still fits; the review gets $3.00
  or what is left. With less than the floor left nothing is reviewed and
  nothing ships. The defaults make a full weekly run fit exactly:
  4 x $0.50 + $3.00.
- **Models.** Sonnet edits and Opus reviews, by exact id, so the trailers
  name what ran. "Most capable" is read as the owner's rule that review uses
  Opus; both are config.
- **Quiet periods beyond the brief's 90 days.** An open finding is not
  proposed twice; a merged one rests 30 days; an edit this tool rejected is
  not retried for 30 days; a verify miss is remembered for 90. A finding
  never attempted (budget, cap, abort, red baseline) is not recorded.
- **Verdicts and attempts are different things.** A timeout, a failed call, a
  failed review or a failed PR says nothing about the edit, so it is recorded
  as `attempted` and retried; three in a row make the finding `needs_human`.
- **History before push.** Rows are written as `pending` before the branch is
  pushed and become `open` with the PR number. A run that dies in between is
  reconciled by the next run from the branch name.
- **A failed `gh pr create` deletes the pushed branch**, but only after
  looking for a PR on that head, since gh can fail after GitHub succeeded.
  The body is written before the push. A branch of today's name on the
  remote, or locally, stops the run rather than being overwritten.
- **Commits are made with hooks and signing off**, so no repo hook or
  pinentry runs unattended.
- **`verify` runs after every scheduled run** (`ExecStartPost`); the brief
  gave it no schedule.
- **`--report FILE`, dry-run only**, previews a report that is not stored.
- **Exit codes.** A gate that stops the run exits 0, so a routine stop does
  not mark the unit failed; a missing store keeps the siblings' exit 2.

## Changed after the security review

- **Line terminators.** Text is split on line feed only, and every other
  control or line-separator character is refused. `splitlines` had hidden a
  carriage return and what followed it from every rule.
- **A baseline test run** before any spend, and a unit `PATH` that finds the
  tools those tests need. A red baseline had turned every settings edit into
  a paid, remembered rejection.
- **The reviewer has no tools and runs in an empty directory** outside the
  worktree. Three real calls showed `--restricted` does not load instruction
  files on its own, and that a model asked to read one with a tool can still
  follow it; `docs/agent-propose.md` records what was and was not confirmed.
- **Appending verifies the open branch first**: every commit on it must be a
  finding commit that passes the checker, since its tests are about to run.
- **A reply over its call cap ends the run.** The caps are then not holding.
- **Fork PRs are ignored**, and only GitHub's explicit "Branch not protected"
  opens the approval gate.

## Not done

- Trend findings: stubbed until the store holds a month of variance.
- Opening the PR as the bot when the base requires approval: the run stops
  and says so.
- The reviewer's final flag set has not been exercised by a real call.
- One author call can read, as data, a file an earlier finding edited in the
  same run. Authoring each finding on a pristine base would close that, at
  the cost of two plugin findings no longer stacking in one run.
