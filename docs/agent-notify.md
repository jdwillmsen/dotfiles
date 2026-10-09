# agent-notify

`~/.local/bin/agent-notify` tells the box's owner when the daily report raised
flags. It reads `~/.local/state/agent-metrics/flags.json`, which the daily
report writes only on a day with flags. Design: `docs/superpowers/specs/2026-10-09-agent-notify-trends-design.md`.

## Three places a flag shows

| Where | How | Cost |
|---|---|---|
| Tracking issue | `agent-notify send`, daily 07:20 from `agent-notify.timer`: one comment per flagged date | one `gh` call set, once per date |
| New shell | `agent-notify shell` prints one line such as `agent-metrics: 2 flags for 2026-10-08 (1 critical): run agent-notify show` | a stat when nothing is pending; no network, no git |
| Status line | `⚑ 2 critical`, on an existing line | one stat and a small read |

`agent-notify show` prints the flags in full and acknowledges that date
(`acked.json`), after which the shell line and the status-line marker stay
quiet for it. A new date is announced again.

## The tracking issue

The repo comes from `store_remote` in `~/.config/agent-metrics/config.json`
(`AGENT_NOTIFY_REPO=owner/repo` overrides it). The issue is titled exactly
`Agent metrics: flagged days`; its number is kept in `notify-issue`. With none
remembered, `send` looks for an open issue with that title, else creates one
and tries to pin it. A comment holds only the date, each flag's severity, id
and message, and a pointer to `reports/<date>-daily.json`.

A failed `gh` call exits 1 and leaves the date unnotified, so the next run
retries. `send --dry-run` prints the comment and changes nothing.

## State files

All under `~/.local/state/agent-metrics/`: `notified.json`, `acked.json`
(`{"dates": [...]}`, newest 90 kept) and `notify-issue`. A flags file that
cannot be read exits 2 naming it; the shell line stays silent instead.

```sh
agent-notify                  # pending flags, last notified date, the issue
agent-notify send --dry-run
systemctl --user list-timers 'agent-notify*'
```
