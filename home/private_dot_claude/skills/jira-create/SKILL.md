---
name: jira-create
description: Create a high-quality, fully-populated Jira issue with evidence, parent anchoring, and deterministic structure. Triggers on "create a Jira", "log this as a Jira", "open a ticket", "file a Jira", "add to Jira", "log this issue", "write up a Jira". Always produces consistent, evidence-rich issues following the typed template discipline below.
---

# Jira Create

Deterministic, evidence-rich Jira issue creation. Never skip a phase. Never POST without CONFIRM.

## Invocation

Triggers when user says: "create a Jira", "log this as a Jira", "open a ticket", "file a Jira", "add to Jira", "log this issue", "write up a Jira for this", or any equivalent.

---

## Phases (execute in order — never skip)

### Phase 1 — CLASSIFY

Determine from conversation context:

| Decision | How |
|----------|-----|
| **Issue type** | Bug = broken thing; Story = new capability; Task = concrete work item; Epic = multi-issue goal |
| **Project** | Default `JDWLABS`. If context implies another project, ask. |
| **Priority** | Derive from impact: P1=cluster down/data loss, P2=degraded service, P3=improvement, P4=low-impact cleanup |
| **Summary draft** | `<Action verb> <specific noun> <context>` — ≤80 chars, no filler words |

Call `getAccessibleAtlassianResources` to get `cloudId`. Cache it for all subsequent calls.

Call `getJiraProjectIssueTypesMetadata` to discover available issue types + any custom fields for the project.

---

### Phase 2 — ANCHOR (parent/Epic — NEVER skip)

**Purpose:** Every issue must have a parent. No orphans.

**If the user already named the parent** (e.g. "put it under JDWLABS-131"): verify it exists and scope-fits via `getJiraIssue`, then skip the search below.

**Search strategy:**
1. Extract 3-5 keywords from the issue context
2. Call `search(cloudId, query="<keywords> Epic")` targeting Epics
3. Also call `searchJiraIssuesUsingJql(cloudId, jql="project = JDWLABS AND issuetype = Epic AND text ~ '<keywords>' ORDER BY updated DESC")` for precision
4. Present top 3 Epic candidates with their summaries and status
5. User picks one — OR — if no match, **pause and create the Epic first**

**Dependency/duplicate sweep (feeds the draft's Dependencies section):** run one JQL over open issues with the same keywords (`project = JDWLABS AND statusCategory != Done AND text ~ '<keywords>'`). Record real Blocks/Blocked-by keys, link duplicates instead of re-filing, or write "none" — never from memory.

**If Epic must be created first:**
- Draft the Epic using the Epic template below
- CONFIRM the Epic
- Create the Epic (get its key)
- Then continue with child issue creation, linking to that Epic as parent

**Linking child to parent:**
- For Stories/Tasks under an Epic: use `parent` field with Epic key
- For sub-tasks under a Story: use `parent` field with Story key
- Always also call `createIssueLink` with "is part of" after creation for extra traceability

---

### Phase 3 — GATHER (evidence — maximize always)

Collect **every available artifact** from the current session context. Do not ask just once — be aggressive. Check all sources:

#### Source Priority (try all that apply):

**1. Playwright Screenshots (UI issues)**
- If the issue involves a UI (Grafana, ArgoCD, Headlamp, any web app), capture a screenshot
- Call `browser_take_screenshot` and `browser_snapshot` to capture current state
- Navigate to the relevant URL if not already there
- Capture: the error state, the expected state if accessible, any alert/notification banners

**2. kubectl / platformctl Output (infrastructure issues)**
- Pull any relevant command output already visible in conversation
- If not yet captured, run targeted commands:
  - `kubectl describe pod <name> -n <ns>` — events + status
  - `kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -20` — recent events
  - `kubectl logs <pod> -n <ns> --tail=50` — last 50 log lines
  - `platformctl --json` output from relevant commands
- Format as fenced code blocks with language tag

**3. Git Diff / File Content (code/config issues)**
- Run `git diff HEAD` or `git diff <ref>` if issue relates to a code change
- Include relevant file snippets with file path and line numbers
- Show before/after if it's a regression

**4. Grafana / Alert State (monitoring issues)**
- Navigate to relevant Grafana dashboard or alert
- Screenshot the alert firing state with timestamp visible
- Capture the alert rule if accessible
- Include the raw alert labels/annotations

**5. Error Messages and Stack Traces**
- Quote exact error strings — never paraphrase
- Include full stack traces where present
- Note the exact versions involved

**6. Cluster State Snapshot**
- `kubectl get pods -n <ns>` — pod status at time of issue
- `kubectl top pods -n <ns>` — resource usage if relevant
- `kubectl get events --field-selector reason=Failed -n <ns>` — failures

**Evidence quality rule:** If you have zero evidence artifacts, ask the user explicitly before continuing. A Jira with no evidence is not acceptable.

---

### Phase 4 — DRAFT

Build the complete issue draft. Use the typed template for the issue type. Fill every section — no placeholders, no "TBD", no empty sections.

**Compose the draft's `Definition of Done` from `## Reference: Definition of Done` below** (universal core + type block + work-surface block — delete only lines that genuinely cannot apply). **Then self-check the draft against `## Reference: Definition of Ready`** — a draft that fails DoR is not ready to present at CONFIRM; fix it first.

#### Bug Template
```markdown
## Problem
[Single sentence. What is broken — describe the system state, not the user experience.]

## Environment
- **Cluster/Namespace:** [value]
- **Component/Version:** [chart version, image tag, app version]
- **Detected:** [timestamp or "first observed YYYY-MM-DD HH:MM UTC"]
- **Reproducible:** [always / intermittent / once]

## Steps to Reproduce
1. [Precise step]
2. [Precise step]
3. [...]

## Expected Behavior
[What should happen. Be specific.]

## Actual Behavior
[What actually happens. Paste exact error/output — do not paraphrase.]

## Root Cause
[Confirmed cause, or best hypothesis with confidence level. "Unknown — see evidence" is acceptable if genuine.]

## Impact
[Who/what is affected. Quantify: N pods down, X% error rate, Y users impacted, data loss risk Y/N.]

## Evidence
[Paste kubectl output, logs, error strings, screenshots as inline images or code blocks]

## Fix / Mitigation
[Immediate workaround if known. Link to fix PR if exists.]

## Dependencies
- **Blocks:** [JDWLABS-XX or "none"]
- **Blocked by:** [JDWLABS-XX or "none"]

## Definition of Done
[Compose from ## Reference: Definition of Done — universal core + Bug block + applicable work-surface block(s)]
```

#### Story / Feature Template
```markdown
## User Story
As a **[role]**, I want **[specific goal]** so that **[measurable benefit]**.

## Context
[Why now. What triggered this request. What breaks or degrades without it.]

## Acceptance Criteria
- [ ] [Specific, testable criterion]
- [ ] [Specific, testable criterion]
- [ ] [Given/When/Then format where applicable]

## Technical Notes
[Architecture decisions, implementation constraints, known risks, dependencies.]

## Out of Scope
[Explicit exclusions. Prevents scope creep. At least one entry.]

## Definition of Done
[Compose from ## Reference: Definition of Done — universal core + Story block + applicable work-surface block]
```

#### Task Template
```markdown
## Objective
[Single sentence. Concrete, observable deliverable.]

## Deliverables
- [ ] [Specific output or artifact]
- [ ] [...]

## Context & Motivation
[Why this task exists. What fails or degrades without it. Link to parent Story/Epic for context.]

## Technical Approach
[How to do this. Not a novel — 3-5 bullet points max.]

## Dependencies
- **Blocks:** [JDWLABS-XX or "none"]
- **Blocked by:** [JDWLABS-XX or "none"]

## Definition of Done
- [ ] [Verifiable completion criterion]
- [ ] [...]
```

#### Epic Template
```markdown
## Goal
[Strategic outcome in 1-2 sentences. What state of the world will be true when this is done.]

## Problem Being Solved
[Current pain. Quantify where possible: X failures/week, Y hours manual effort, Z% error rate.]

## Success Metrics
- [ ] [Measurable metric]
- [ ] [Measurable metric]

## Scope
**In:** [What this Epic covers]
**Out:** [What is explicitly excluded]

## Delivery Phases
1. [Phase name — brief description]
2. [Phase name — brief description]

## Linked Context
- [ADR, design doc, or prior Jira link]
- [Runbook or OPERATIONS.md section]

## Definition of Done
[Compose from ## Reference: Definition of Done — universal core + Epic block]
```

---

#### Full Field Set (populate all that apply)

| Field | Value Strategy |
|-------|---------------|
| `summary` | ≤80 chars, action verb start, specific |
| `description` | Typed template, no empty sections |
| `issuetype` | Bug / Story / Task / Epic |
| `priority` | Use the instance's actual priority names from project metadata (this instance: Highest/High/Medium/Low). The P1–P4 impact classes from Phase 1 map onto them; keep the class rationale in Impact/Context, not the field name |
| `parent` | Epic key (confirmed in Phase 2) |
| `labels` | ≥2 from taxonomy below |
| `assignee` | Default: self (jdwillmsen@gmail.com → look up account ID via `lookupJiraAccountId`) |
| `environment` | For Bugs: paste cluster/version/namespace string |
| `components` | From project metadata if available |

#### Label Taxonomy
Use labels from this set (combine as needed):
```
platform    tenant      infra       storage     networking
security    ci          monitoring  database    vault
argocd      cert        arc-runner  longhorn    cnpg
fix         upgrade     debt        spike       investigation
ux          api         auth        config      performance
```

---

### Phase 5 — CONFIRM

**ALWAYS do this. Never skip.**

Present the full draft as a formatted preview:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
JIRA DRAFT — [ISSUE TYPE] — [PROJECT]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Summary:     [summary text]
Type:        [Bug / Story / Task / Epic]
Priority:    [P1-P4 + name]
Parent:      [JDWLABS-XX — Epic summary]
Assignee:    [name]
Labels:      [label1, label2, ...]

─── DESCRIPTION ───────────────────────────
[full description rendered]

─── EVIDENCE ──────────────────────────────
[list of evidence artifacts — inlined in the description, or added as a Phase 6 comment; Jira file attachments are not available via these tools]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Create this issue? (yes / edit [field] / cancel)
```

Wait for explicit approval. Accept: "yes", "create it", "looks good", "go". 
On "edit [field]": update that field and re-show the full preview.
On "cancel": stop, do not create.

**Pre-POST quality gate (check before submitting):**
- [ ] Summary ≤80 chars, starts with action verb
- [ ] All template sections populated (no empty/placeholder text)
- [ ] Parent confirmed — not guessed
- [ ] Priority has one-line justification in Impact or Context
- [ ] ≥2 labels from taxonomy
- [ ] ≥1 evidence artifact (screenshot, log, code, error string)
- [ ] **Full DoR pass** (`## Reference: Definition of Ready`) — every universal + type-specific item
- [ ] DoD composed from `## Reference: Definition of Done`, every line verifiable

If any gate fails, fix it before creating — do not ask user to overlook it.

---

### Phase 6 — CREATE

Execute in this exact order:

1. **Create the issue**
   ```
   createJiraIssue(cloudId, fields={...all populated fields...})
   ```
   Capture the returned issue key (e.g., `JDWLABS-42`).

2. **Add issue link to parent**
   ```
   createIssueLink(cloudId, {
     type: { name: "is part of" },
     inwardIssue: { key: "<new key>" },
     outwardIssue: { key: "<parent epic key>" }
   })
   ```

3. **Add evidence comment**
   If there are code blocks, kubectl output, or long artifacts that didn't fit cleanly in the description, add them as a comment:
   ```
   addCommentToJiraIssue(cloudId, issueKey, {
     body: {
       type: "doc", version: 1,
       content: [{ type: "paragraph", content: [{ type: "text", text: "..." }] }]
     }
   })
   ```

4. **Report result**
   ```
   ✅ Created JDWLABS-42 — [summary]
   🔗 https://jdwillmsen.atlassian.net/browse/JDWLABS-42
   👆 Parent: JDWLABS-XX — [epic summary]
   ```

---

## Reference: Definition of Ready (DoR)

A ticket is Ready when a competent contributor — human or agent — could start it **without asking a single question**. Check during DRAFT; re-verify at the CONFIRM gate. Any failing item: fix the draft, don't present it.

### Universal DoR (all issue types)

- [ ] Summary ≤80 chars, action verb, specific noun — greppable and unambiguous in a backlog list
- [ ] Problem/Objective states current state and desired state, one sentence each
- [ ] ≥1 evidence artifact: exact log/error text, file path + line, screenshot, incident timestamp, or command output — never paraphrased
- [ ] Parent anchored to a verified Epic (searched, scope-checked — not guessed) — no orphans
- [ ] Acceptance criteria / deliverables are **observable**: a reviewer can answer "done?" yes/no without interpretation
- [ ] Dependencies enumerated as issue keys (`Blocks:` / `Blocked by:` / "none") — verified live via JQL, not from memory
- [ ] Priority justified in one line tied to impact (data loss, outage class, bottleneck, cleanup)
- [ ] Sized to ≤3 focus-days of work; larger → split into Tasks or promote to Epic with phases
- [ ] Repo(s) and component named where the change lands — path-level where known
- [ ] ≥2 taxonomy labels; assignee resolved to account ID
- [ ] No unresolved decision blocking start — open questions live in the body with a named decision owner

### Type-specific DoR

| Type | Additional readiness bar |
|---|---|
| **Bug** | Repro steps precise enough to replay, or "intermittent" + observed frequency; exact error quoted; env/component/version captured; impact quantified |
| **Story** | Role is a real persona (never "as a user"); benefit measurable; Out of Scope has ≥1 real entry |
| **Task** | Single concrete deliverable; Technical Approach ≤5 bullets; not secretly three tasks |
| **Epic** | Success metrics measurable (numbers, not vibes); delivery phases named; In/Out scope explicit; expected child issues sketched |

### DoR anti-patterns

| Smell | Fix |
|---|---|
| "Investigate X" with no exit condition | Deliverable = the specific questions the investigation must answer |
| Acceptance criteria restate the summary | Rewrite as observable checks with concrete commands/URLs |
| "TBD", "etc.", "and so on" in any section | Resolve it now or delete the section honestly |
| Evidence is a paraphrase ("the pod was crashing") | Paste the exact output/error verbatim |
| Blocked-by from memory | Run the JQL; link the key or write "none" |
| Ticket assumes conversation context ("fix the thing we discussed") | Body must stand alone for a reader with zero context |

---

## Reference: Definition of Done (DoD)

Compose each ticket's DoD from three parts: **universal core + type block + work-surface block(s)**. Delete only lines that genuinely cannot apply — never leave a line that can't be verified with evidence.

Org standards source of truth: `jdwlabs/.github` → `docs/code-standards.md` (linters/CI implement it; DoD items below assume it).

### Universal core (every ticket)

- [ ] Every deliverable checkbox verified, with evidence (command output, screenshot, PR/CI link) attached as a ticket comment
- [ ] Change merged to `main` via PR with green CI — never a direct push
- [ ] Every review thread and bot/security finding fixed or explicitly justified in the PR
- [ ] Org code standards met: lint/format/test gates green; comments explain *why*; **no ticket IDs in code or manifest comments** (traceability = commit/PR)
- [ ] Docs updated where behavior or structure changed (README structure sections, runbooks, agent docs)
- [ ] Conventional commits; PR description links this ticket

### Work-surface blocks (add all that apply)

**GitOps / platform / deployments change**
- [ ] ArgoCD Application(s) Synced + Healthy after merge — verified against live cluster, not assumed
- [ ] Live state verified with `platformctl`/`kubectl` read evidence; zero manual mutations (`kubectl apply/edit`, `argocd app sync`)
- [ ] New workloads have resources + probes set (no BestEffort; startupProbe for slow-boot services)

**Go CLI / tooling**
- [ ] `go test -race ./...` green; `golangci-lint` clean
- [ ] Agent-facing commands follow AXI (structured output, exit codes 0/1, no interactive prompts in CI paths)

**Frontend / Nx**
- [ ] `nx affected -t lint test build` green; module boundaries respected
- [ ] E2E updated/passing where user-facing behavior changed

**Terraform / Talos**
- [ ] `fmt` + `validate` green; plan reviewed by a human before apply — never autonomous apply
- [ ] Repo version pins match the running cluster after the change

**Incident / operations**
- [ ] Runbook created or updated (`scenarios/`, `OPERATIONS.md`) with symptom → fix
- [ ] Alert/monitor confirmed resolved or added to cover the failure mode

### Type-specific blocks

| Type | Done additionally means |
|---|---|
| **Bug** | Root cause documented in the ticket (not just the fix); regression test added where a test surface exists; fix verified in the affected environment |
| **Story** | Every acceptance criterion demonstrably true; demo evidence (screenshot/URL) on the ticket |
| **Task** | All deliverables checked with evidence; follow-up work ticketed, not left implicit |
| **Epic** | All children Done; each success metric measured and recorded in a closing epic comment |

### DoD anti-patterns

| Smell | Fix |
|---|---|
| "Done" claimed without running the verification | Run the command, paste the output, then claim |
| Boilerplate DoD lines left unverifiable ("docs updated if applicable") | Either verify and check it, or delete the line at draft time |
| Live cluster patched to green but git not merged | Not done — ArgoCD will revert it; merge the PR |
| Epic closed with open children | Reparent or finish them first |

---

## Reference: Atlassian Tools

| Tool | When |
|------|------|
| `getAccessibleAtlassianResources` | Phase 1 — get cloudId |
| `getJiraProjectIssueTypesMetadata` | Phase 1 — discover issue types + custom fields |
| `search` | Phase 2 — find parent Epics |
| `searchJiraIssuesUsingJql` | Phase 2 — precise Epic search |
| `lookupJiraAccountId` | Phase 4 — resolve assignee email → accountId |
| `createJiraIssue` | Phase 6 — create the issue |
| `createIssueLink` | Phase 6 — link child to parent |
| `addCommentToJiraIssue` | Phase 6 — attach overflow evidence |
| `getJiraIssue` | Any — verify created issue or look up parent details |

## Reference: Evidence Tools

| Tool | When |
|------|------|
| `browser_take_screenshot` | UI state capture |
| `browser_snapshot` | Accessibility tree + DOM state |
| `browser_navigate` | Navigate to relevant URL before screenshot |
| Bash/PowerShell | `kubectl`, `platformctl`, `git diff` output |

---

## Quality Principles

**Concise but complete.** Every word earns its place. No filler sentences. But zero empty sections.

**Evidence over assertion.** "Pod is crashing" with a 50-line log is infinitely better than "Pod is crashing" alone.

**Specificity over generality.** "argocd-server v3.3.6 pods CrashLooping on talos-4h8-zy6 after rollout restart" beats "ArgoCD issue".

**Intent visible.** A reader with no context should understand what problem this solves and why it matters — from the description alone, without asking anyone.

**No orphans.** If there's no Epic to anchor to, that's a signal to create one. The hierarchy reflects actual work structure.
