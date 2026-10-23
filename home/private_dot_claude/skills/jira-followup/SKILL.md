---
name: jira-followup
description: File a short Jira ticket without asking, so a fresh agent can pick the work up later. Use when you are stuck or blocked, find follow-up work outside your task, or must hand work to a human. Not for planned work a human asked for; that is jira-create.
model: sonnet
---

# Jira follow-up

File first, trim later. No confirmation step, no Playwright evidence, no phases.
Planned or human-requested tickets still go through `jira-create`.

## When to file

- You are stuck: the same fix failed twice, a tool or credential is missing, or the
  next step needs a decision only the owner can make.
- You found work outside your task (bug, cleanup, missing test, doc gap).
- You are stopping mid-task and someone else must continue.

Do not file for something you can finish in this task.

## Steps

1. `KEY=$(stream key)` from the repo the work is for. Use the Atlassian cloudId from
   `getAccessibleAtlassianResources`.
2. One duplicate check:
   `project = KEY AND statusCategory != Done AND text ~ "<2-3 keywords>"`.
   If a match exists, comment on it instead of filing.
3. Create the issue (Bug, Task or Spike) in KEY:
   - Parent: the Epic that fits; otherwise the project's "Agent follow-ups" Epic.
   - Labels: `agent-filed`, plus `needs-human` when only the owner can unblock it.
   - Status stays Backlog. Only a human moves it to Ready.
4. Description, in this order, each a line or two:
   - **Repo/path**: `owner/repo`, files or service.
   - **Why / stuck on**: exact error or evidence, with date.
   - **Done when**: yes/no checks.
   - **Dependencies**: issue keys, or none.
   - **Handoff**: what was tried, the branch or PR, the next step.
5. If it blocks your current ticket, add a `Blocks` link and comment the new key there.
6. Reply with the key and one line. Keep working on whatever is not blocked.

## Rules

- Summary: verb phrase, 80 characters or fewer.
- Never file into `OPS`; that project is for alerts.
- Never paste secrets, tokens or full logs; quote the failing line.
- Never transition a ticket to Done.
