---
name: task-dispatch
description: Classify a piece of work by risk, pick the model lane for each delegated task, brief the worker, record the outcome and escalate on failure. Use before delegating any implementation, review or research to another agent, and when starting work from a ticket.
model: sonnet
---

# Task dispatch

Orchestrate, do not hand-build: classify, assign by rule, brief, verify, record.

## 1. Classify the work

```
change-class --plan <file-or-ticket-text>      # before any work starts
change-class --pr <N> --repo <owner/repo>      # before merging
```

- Tier R3 (`human: true`, `interview: true`): stop and interview the owner about
  blast radius, rollback and who is affected before any worker starts. Do not
  dispatch implementation until they answer.
- Put `risk-R<n>` and the `tag-*` labels on the ticket; `risk/R<n>` on the PR.
- Split a plan whose parts have different tiers. R0/R1 parts can start now.

## 2. Assign a lane per task

One task = one bounded change a worker can finish in one thread.

```
agent-pace assign --class <impl|impl-large|review-fix|review|research|spike|docs|test|ops|summarize> --risk <R0..R3> --ticket <KEY> [--implementer <lane>]
```

Use the `lane`, `provider` and `model` it returns. If it says `defer`, the lane
that may do this work is out of quota until the reset it names; queue the work,
do not give it to a lane the tier does not allow. Each call is logged, so
dispatch only when you will actually run the task.

## 3. Brief and launch

- Create the worktree yourself (`gwta`, or `git worktree add <path> -b <branch>
  origin/main`) and pass its path; shared isolation runs in the parent's cwd.
- Launch with `delegate_task`, `clientRequestId` = the assignment id. The brief is
  all the worker has: ticket key, goal, repo and worktree path, files and
  constraints, the exact commands that prove it works, the commit trailers for
  that model, "no push, no PR, use /usr/bin/git inside the worktree".
- Read the rules file pattern in `/tmp/delivery-build-rules.md` if one exists for
  the current effort; do not paste a long rulebook into every brief.
- Several workers at once: each gets its own worktree and branch. Respect each
  lane's concurrency; NIM GLM breaks above about three.

## 4. Verify, never trust the summary

Inspect the worktree: `git log`, `git diff --stat`, run the tests yourself. Run
the formatter and linter the repo uses (free models leave gofmt gaps). Review at
the tier's level (see the shared rules). If the work is wrong, say precisely
what, and use the next lane on the fallback ladder with that finding in the
brief; never re-run the same model on the same failure.

## 5. Record the outcome

```
agent-eval record --id <assignment-id> --status completed|failed|interrupted \
  [--failure-kind infra|quota|timeout|quality] [--ci-first-pass true|false] \
  [--review-findings N] [--merged true] [--human-touch true] [--escalated-from <lane>]
```

Record failures as honestly as successes: a quota error is `quota`, a wrong
answer is `quality`. The reports use these to decide which models earn more work.

## 6. When you cannot continue

File a ticket with `jira-followup` and comment the handoff on the working
ticket. Keep going on whatever is not blocked.
