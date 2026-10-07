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
there; on a personal machine `chezmoi apply` then regenerates
`~/.config/claude-jira.json` (see
[shell-helpers.md](shell-helpers.md#configclaude-jirajson) for when a
hand-written file is kept).

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

- Each stream has its own board in its own project.
- **Personal stream** filter: `project in (JDW, CAREER)`.
- **All streams** dashboard: every project side by side, for the admin view.

Cross-stream dependencies are issue links (`Blocks`, `Relates`). An Epic lives
in exactly one project.
