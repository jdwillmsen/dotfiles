# Ticket-driven agent workflow — findings and options

Measured 2026-10-23 from the agent-metrics transcripts, the T3 Code state
database, GitHub (`gh`) and Jira. Decision pending: nothing here is deployed.
The draft skill `jira-followup` is the only artifact added alongside this doc.

## Goal

Agents coordinate through Jira: they file a ticket when stuck or when they find
follow-up work, a fresh agent can pick any ticket up cold, and the human spends
attention at the start (what is Ready) and the end (review, merge, rollout).
Constraints: Claude Max 5x quota is the scarce resource; reviews, merges and
rollbacks must stay fast and safe.

## What the data says

| Area | Finding |
|---|---|
| Cost | $2,501 over 14 days (API-rate equivalent). Top 10 sessions are 60% of it; the median session is $0.65. |
| Cost drivers | Cache reads and writes are $1,101 and $1,110; output is $289. Context size and idling matter more than output. |
| Thread age | Cost per main-thread call rises from $0.095 (calls 0–199) to $0.254 (calls 800–999). Calls past index 400 are 17% of main-thread cost. |
| Idle | 938 calls came after a gap over 5 minutes; their cache writes cost $448. 254 gaps over 1 hour cost $369 (15% of spend). |
| Opus leak | Opus subagents cost $468 (84 runs, $6.05 each) against Sonnet $1.63 per run. 56 were reviews or audits; about $34 was a genuine final or security review. `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` is set, so these are explicit `model: "opus"` overrides in T3 threads. |
| Quota | Five-hour window hit 99–102% on five days in 14. Seven-day peaked at 98%. |
| Delegation | Free OpenCode models completed 30 of 31 implementation runs; Sonnet 9 of 9. All 23 failures were infrastructure (NIM GLM 429s, Codex/Grok usage limits, a retired model, context overflow), none a wrong answer. |
| Retries | 51 of 83 delegated tasks are retries (`-rN`); ten tickets needed a second model, one went through four failed attempts. |
| Threads | 3,409-item and 1,333-item orchestrator threads exist; 16 of 41 human-started threads exceed 300 items. Only 2 of 83 delegated tasks used a worktree. |
| Jira | 210 open tickets, 118 created in 7 days, 12 Ready, 158 in Backlog. Ready tickets score 3.5 of 5 for cold pickup; the weakest check is "repo named". |
| Staleness | Of 14 stale non-Epic In Progress tickets, 8 have a merged PR and were never moved on. |
| Agent filing | `jira-create` needs a human CONFIRM and runs six phases, so it cannot be used unattended. No `agent-filed`, `needs-human` or blocked convention exists. Only 3 tickets carry `agent-actionable` or `human-only`. |
| Delivery | 753 PRs merged in 30 days, median 0.14 h to merge. `jdwlabs-agent-bot` PRs have p90 172 h (human approval); CodeRabbit skips bot PRs. 21 Renovate PRs are 13–27 days old. |
| Rollback | Revert PR plus ArgoCD resync, or a digest-pin dispatch. No service health gate, no "last known good" record, no rehearsal. Auto-sync with prune and self-heal means a bad merge is live at once. |
| Merge to prd | Merge to non-prd about 19 minutes; the prd promotion PR merged 46 hours later in the one release traced. |

Not verified: merge-to-live timing in ArgoCD, why the promotion waited, and
fixed-versus-dismissed review comments beyond a small sample. "Completed" for a
delegated task means the run finished, not that the work was correct.

## Nine approaches

Savings are shares of weekly spend and overlap; the cost analysis puts the
combined ceiling of the model-routing levers near 35%.

### 1. One ticket, one worktree, one thread

Start every unit of work with `t3_thread_launch` bound to a new worktree, titled
with the ticket key, ending with a Jira comment (done, remaining, branch/PR) and
a settled thread. Orchestrator state lives in the Epic, not in a 3,000-item
thread.

- Cost: targets the 17% of main-thread spend past call 400 and part of the idle re-warm cost. Estimated 8–12% (medium confidence).
- Review/merge: one PR per ticket, easier to review and to revert.
- Effort: low; a launch convention plus a handoff comment template.
- Risk: more threads to track. Mitigate with the Ready queue (approach 3).

### 2. Stuck protocol and agent-filed tickets

Add to the shared agent rules: when stuck twice, blocked, or when you find
out-of-scope work, run `jira-followup` (draft in this branch), then continue
with anything unblocked. Labels `agent-filed` and `needs-human`; stuck tickets
stay in Backlog; only a human sets Ready or Done.

- Cost: none to small; removes repeated failing retries (ten tickets needed a second model).
- Review: the human queue becomes a saved JQL filter instead of chat archaeology.
- Effort: low. Needs an "Agent follow-ups" Epic per project (admin step).
- Risk: ticket spam (118 created last week already). Mitigate with the duplicate check and a weekly janitor (approach 8).

### 3. Ready-queue puller (scheduled, capped)

A `schedule_task` fixed-time or interval job reads `status = Ready AND labels =
agent-actionable`, launches one worker thread per ticket via approach 1, and
stops at hard caps: at most 3 concurrent workers (NIM GLM rate-limits near 4),
a per-run ticket limit, and no run when quota is above the gate in approach 9.

- Throughput: the backlog drains while the human reviews; Jira is the queue.
- Cost: neutral to positive when workers use approach 4's cheap-first routing.
- Effort: medium. Needs Definition of Ready enforced (below) or workers get weak briefs.
- Risk: runaway loops. Caps and the quota gate are mandatory, per the existing rule on unattended loops.

### 4. Cheap-first model ladder with escalation

Route by task: free OpenCode (glm-5.3-flash-free, deepseek-v4.1-flash-free,
minimax-m3.1-flash-free) for implementation and review-fix rounds; Sonnet for
research, spikes and anything a free model failed; Opus only for planning,
final pre-merge review, security and architecture. Skip Codex/Grok on the free
plans, NIM above 3 concurrent, retired NIM models (GLM 5.3, kimi-k3), NIM DeepSeek and local-chat for
agent tasks. A ticket that fails on one rung is escalated, not retried on the
same model.

- Cost: Opus subagents to Sonnet saves 7–9%; moving orchestration threads to Sonnet could add 15–30% but carries a quality risk and low confidence.
- Review: keep an Opus reviewer for risky diffs only (approach 5).
- Effort: low. Mostly a stated routing table plus a rule against `model: "opus"` on routine review.
- Risk: free-model output still needs inspection (gofmt gaps, unverified fixes).

### 5. Risk-tiered review and merge

Tier a PR by what it touches. Docs, config and Renovate non-major: green CI plus
a bot review, auto-merge. Normal code: a Sonnet reviewer plus CodeRabbit. Prod
paths, auth, data, security: an Opus reviewer and a human. Enable CodeRabbit on
bot-authored PRs so the approver reads more than a PR-Agent summary, and let
Renovate group or auto-merge low-risk updates.

- Review: attacks the 172-hour p90 on bot PRs and the 21 stale Renovate PRs.
- Cost: moves Opus review spend (about $165 per 14 days labelled review) to the few PRs that need it.
- Effort: medium; `.coderabbit.yaml` and `renovate.json` per repo, a tier rule in the review step.
- Risk: auto-merge widens blast radius; keep it behind approach 6.

### 6. Rollback safety net

Write a per-service last-known-good record on each promotion, add a one-command
rollback dispatch that re-pins it, and open an automatic revert PR when a
post-promotion health check fails. Rehearse it once in non-prd. Argo Rollouts
is the heavier alternative.

- Merge/rollback: makes faster merging safe; today recovery depends on a human noticing.
- Effort: medium to high; touches the deployments repos and `promote-prd.yml`.
- Risk: a rollback must not rewrite data. Anything with migrations stays human-gated.

### 7. Webhook-driven dispatch

Jira Automation sends a web request when a ticket enters Ready; a T3
`schedule_task` webhook launches a worker immediately. Same workers as approach 3,
event-driven rather than polled.

- Throughput: lower latency than polling.
- Effort: high for the value. Needs T3 Connect remote access for a public URL, a signing secret entered through `request_secret`, and Jira Automation rules.
- Recommendation: skip until approach 3 is proven; polling every 30–60 minutes is enough.

### 8. Ticket janitor

A weekly cheap-model job: list In Progress tickets with a merged PR and propose
Done, flag duplicates, label unlabelled tickets, add missing parents, and post
the result as one comment or digest. Humans approve the moves.

- Effort: low. It reuses the saved filters below.
- Value: the 8 finished-but-not-moved tickets are the immediate case.

### 9. Cache-aware cadence and quota gate

Work in bursts inside the 1-hour cache window, settle or compact a thread
before a long break, and start new threads rather than resuming after hours of
idle. Gate unattended dispatch on `agent-metrics providers`: above about 80%
on the five-hour or seven-day window, pause Opus and Sonnet dispatch and
spill to free models or wait.

- Cost: the idle re-warm leak was $369 for gaps over an hour, 15% of spend; about 40% looks avoidable.
- Effort: low for the habit, medium for an automated gate.
- Risk: none beyond slower dispatch near the limit.

## Comparison

| # | Approach | Cost | Throughput | Review/merge/rollback | Effort | Risk |
|---|---|---|---|---|---|---|
| 1 | Ticket-per-thread | High | Medium | Medium | Low | Low |
| 2 | Stuck protocol | Low | High | Medium | Low | Low |
| 3 | Ready-queue puller | Neutral | High | Low | Medium | Medium |
| 4 | Cheap-first ladder | High | Medium | Low | Low | Medium |
| 5 | Risk-tiered review | Medium | Medium | High | Medium | Medium |
| 6 | Rollback safety net | None | Low | High | High | Low |
| 7 | Webhook dispatch | None | Low | None | High | Medium |
| 8 | Ticket janitor | Low | Medium | Low | Low | Low |
| 9 | Cadence and quota gate | Medium | Low | None | Low | Low |

## Recommended order

1. **This week, low risk:** approaches 2, 4, 8 and 9 as habits and rules. Add the stuck rule to `~/.config/agents/AGENTS.md`, ban `model: "opus"` on routine review, move the 8 finished tickets to Done, create the "Agent follow-ups" Epics, and add the five saved filters.
2. **Next:** approach 1 as the default launch pattern, then approach 5's low-risk half (CodeRabbit on bot PRs, Renovate grouping, closing stale Renovate PRs).
3. **Then:** approach 6 before auto-merging anything beyond docs, and approach 3 once Definition of Ready is enforced.
4. **Defer:** approach 7.

## Conventions to adopt

Definition of Ready (all six): repo or path named; observable done-when; dated
evidence; dependencies listed; parent Epic set; labelled `agent-actionable` or
`human-only`.

Labels: `agent-filed`, `needs-human`, `blocked` (with a `Blocks` link).
Statuses: no Blocked status exists; park stuck tickets in Backlog with a
comment. Agents move tickets to In Progress and Review; only a human sets Done.

Saved filters (created in Jira on 2026-10-24 as "Agents: Ready queue", "Agents: Human queue",
"Agents: Stale in progress", "Agents: Agent-filed inbox" and "Agents: Hygiene"; private to the
owner, ordered as below):

1. Ready queue: `project != OPS AND status = Ready AND labels = agent-actionable ORDER BY priority DESC, created`
2. Human queue: `project != OPS AND statusCategory != Done AND labels in (human-only, needs-human)`
3. Stale: `project != OPS AND status = "In Progress" AND issuetype != Epic AND updated <= -3d`
4. Agent inbox: `labels = agent-filed AND status = Backlog ORDER BY created DESC`
5. Hygiene: `project != OPS AND statusCategory != Done AND issuetype != Epic AND (labels is EMPTY OR parent is EMPTY)`

## Decisions needed

- Adopt the stuck protocol as a shared rule, and file without confirmation?
- Where does a worker's handoff go: a Jira comment only, or also a file in the branch?
- Are free models acceptable for implementation by default, with Sonnet as the first escalation?
- How much auto-merge is acceptable, and for which paths?
- Should orchestration threads run on Sonnet by default (largest saving, quality risk)?
