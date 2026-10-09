# Streams

Each GitHub owner is one business stream. The owner of a repo decides its Jira
project, its folder under `~/projects`, and its worktree namespace.

| Stream | Jira project | Folder | Open PRs |
|---|---|---|---|
| `jdwillmsen` | `JDW` (`career` → `CAREER`) | `~/projects/jdwillmsen/` | <https://github.com/pulls?q=is:open+is:pr+archived:false+user:jdwillmsen> |
| `jdwlabs` | `JDWLABS` | `~/projects/jdwlabs/` | <https://github.com/pulls?q=is:open+is:pr+archived:false+org:jdwlabs> |
| `dotablaze-tech` | `DOTA` | `~/projects/dotablaze-tech/` | <https://github.com/pulls?q=is:open+is:pr+archived:false+org:dotablaze-tech> |

## The map

`~/.config/streams.json` (source: `home/dot_config/streams.json`) is the one
place owners and project keys are written down. Adding a stream is one entry
there; `chezmoi apply` then regenerates `~/.config/claude-jira.json` (see
[shell-helpers.md](shell-helpers.md#configclaude-jirajson) for which machines
get it and when a hand-written file is kept).

## `stream`

```bash
stream                    # the streams, and where the current repo sits
stream slug               # jdwlabs/platform
stream key                # JDWLABS
stream status             # one row per stream: open PRs, reviews, failing, alerts
stream status jdwlabs     # that stream's PRs with check state, and alerts
stream status --no-alerts # skip the per-repo alert requests
stream jira-config        # print the Jira allowlist; --write saves it
```

Read-only against GitHub and Jira. A repo whose alerts could not be read is
counted as not measured, never as zero. Output is TOON for agents; errors are
structured on stdout, exit 1 for a failure and 2 for a usage error.

GitHub owner and repo names are case-insensitive, so the slug is lower-cased
and an owner or overridden repo matches the map in any case. A repo with no
usable remote keeps its folder name as it is.

In the `stream status` overview, `review_requested` and `failing` are counted
from the first 100 open PRs; a trailing `+` marks them as a floor when the
stream has more.

A fork whose `origin` is the upstream repo would resolve to the upstream
owner. Assign it explicitly: `git config stream.owner jdwillmsen`.

## GitHub notification filters

Set once by hand under Notifications → Filters, so the inbox is split by
stream:

| Name | Filter |
|---|---|
| jdwillmsen | `org:jdwillmsen` |
| jdwlabs | `org:jdwlabs` |
| dotablaze-tech | `org:dotablaze-tech` |

The `org:` qualifier is documented for organisations. If it matches nothing
for the personal account, name its active repos instead:
`repo:jdwillmsen/gameops repo:jdwillmsen/dotfiles …`.

## Jira views

- Each project has its own board, and all five (`JDW`, `CAREER`, `JDWLABS`,
  `DOTA`, `OPS`) share the columns Backlog, Ready, In Progress, Review, Done.
- The four stream projects share one set of issue types: Epic, Task, Bug,
  Spike and Subtask. `OPS` has the same without Spike.
- Every open ticket in a stream project has a parent Epic.
- **Personal stream** filter: `project in (JDW, CAREER)`.
- **All streams** dashboard: every project side by side, for the admin view,
  with open alerts from `OPS` in their own panel.

Cross-stream dependencies are issue links (`Blocks`, `Relates`). An Epic lives
in exactly one project.

## Alerts — `OPS`

Alert tickets are operational events, not planned work, so they belong to no
stream. `ai-sre-relay` files every critical or warning alert as a Task in the
`OPS` project (its `JIRA_PROJECT` setting in `jdwlabs/platform`), comments on
the same ticket when the alert repeats, and closes it after the alert
resolves. Nothing else is filed there: work that an alert leads to is a
ticket in the owning stream's project, linked to the `OPS` ticket.

The relay only looks for an alert's existing ticket inside `OPS`, so an alert
ticket moved to another project is never found again and the next firing
opens a duplicate.
