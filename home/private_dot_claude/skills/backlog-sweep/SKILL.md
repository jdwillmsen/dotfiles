---
name: backlog-sweep
description: Sweep a stream's Jira backlog against GitHub and T3 threads, and answer "where are we". Three modes - rundown (what is in flight, stuck, waiting on the owner), close-out (match In Progress and Review tickets to merged and rolled-out PRs, settle them with evidence, bundle the rest into one owner decision) and OPS-alert triage (report only). Use when the owner says "where are we", "where did we leave off", "rundown", "what can we close out", "close out the review Jiras", "triage the backlog", "review my backlog" or "triage the OPS alerts".
model: sonnet
---

# Backlog sweep

A sequencer over tools that already exist. The rules it relies on (Done only
when live, owner approval for anything closed without shipping, never file in
`OPS`) live in the shared AGENTS.md; this skill does not restate them, it
applies them.

## 0. Scope

- Stream: `stream key` from the repo or grouping folder (`stream` lists them).
  "All streams" means one pass per stream key, then one combined summary.
- cloudId: `getAccessibleAtlassianResources` once.
- Pick the mode from the ask: rundown (default), close-out, or OPS triage.

## 1. Rundown — "where are we"

Read only. Gather, in parallel:

1. Jira, `searchJiraIssuesUsingJql`:
   `project = KEY AND status in ("In Progress", Review) ORDER BY updated DESC`
   and `project = KEY AND status = Ready ORDER BY rank` (the next up).
2. GitHub: `stream status <owner>` for open PRs, check state and alerts.
3. Threads: `t3_thread_list` for open threads in the stream's projects; read
   the tail of any that look stalled with `t3_thread_read`.

Join them on the ticket key (branch name, PR title, thread title). Report the
summary in section 4. Stop here unless the owner asked to close things out.

## 2. Close-out — settle In Progress and Review

For each ticket from the first JQL above:

1. **Find its PRs.** `gh search prs "<KEY>" --owner <owner> --json repository,number,state,url,closedAt`
   searches titles and bodies. Branch names carry the key, so for the repo the
   ticket names also run `gh pr list --repo <o/r> --state all --limit 100
   --json number,state,url,headRefName,mergeCommit` and match `headRefName`.
2. **Classify the evidence**, one of:
   - `open` — PR open. A ticket still In Progress with a PR up may move to Review.
   - `merged` — merged, rollout not shown yet.
   - `live` — merged, the repo's rollout signal is green, and the change was
     checked live. Rollout signals per repo kind are in dotfiles
     `docs/merge-captain.md` ("Rollout verification"); read them with
     `merge-captain status` (rollouts rows) or `gh run list --repo <o/r> --commit <mergeCommit>`.
   - `none` — no PR found.
   - `obsolete` — the work is moot (superseded, done elsewhere, no longer wanted).
3. **Act:**
   - Merged, rolled out and verified live **by this session** → transition to Done,
     comment the evidence (PR link, merge commit, rollout run, live check).
   - Everything else that looks finished (`merged`, `live` found by the sweep,
     `obsolete`, won't-do) → do not transition; put it in the owner decision.
   - `none` and stale (no update for 7+ days) → stuck; name the blocker.
4. **Verify every transition.** Re-read the ticket with `getJiraIssue` and
   compare the status; `transitionJiraIssue` can return success with nothing
   changed. Retry once if unchanged, then report it as not moved.
5. **Comment format** (`addOrEditJiraIssueComment`), two to four lines:
   what shipped, PR link, rollout evidence, what was checked live.

Open threads whose ticket is settled: offer to close or merge them in the
summary; do not archive a thread without the owner's yes.

## 3. OPS-alert triage

Report only. No comments, no links, no transitions on `OPS` tickets.

1. `project = OPS AND statusCategory != Done ORDER BY created DESC`.
2. Group by alert name (summary prefix). For each group note: count, first and
   last fired, last comment date (repeat firings are comments from the relay).
3. Look for a linked stream ticket with
   `project in (<stream keys>) AND text ~ "<alert name>"`.
4. Flag: still firing with no stream ticket, open for 7+ days, firing many
   times a day (noisy rule), and any that look resolved but stay open.

The owner decides what becomes stream work; `jira-followup` files it in the
owning stream when they say so.

## 4. The summary

One message, in this order, each item one line with the key and a link:

- **Done** — tickets this session moved to Done, with the evidence link.
- **Moved** — other transitions made (e.g. In Progress → Review).
- **Stuck** — key, blocker, the next step.
- **Owner decision** — one numbered list the owner can answer in one reply:
  "close as Done (merged and live)", "close as won't do", "obsolete", each with
  its evidence. Never ask these one at a time.
- **Threads** — open threads to settle or merge.
- **Next** — the top three Ready tickets.

PRs are full links (`[owner/repo#N](url)`). A count that could not be read
(GitHub or Jira error) is reported as unknown, never as zero.
