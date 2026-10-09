# agent-notify

`~/.local/bin/agent-notify` tells the box's owner when the daily report raised
flags. It reads `~/.local/state/agent-metrics/flags.json`, which the daily
report writes only on a day with flags. Design: `docs/superpowers/specs/2026-10-09-agent-notify-trends-design.md`.

## Three places a flag shows

| Where | How | Cost |
|---|---|---|
| Tracking issue | `agent-notify send`, daily 07:20 from `agent-notify.timer`: one comment per flagged date | one `gh` call set, once per date |
| New shell | `agent-notify shell` prints one line such as `agent-metrics: 2 flags for 2026-10-08 (1 critical): run agent-notify show`, only when stdout is a terminal | plain tests only when nothing is pending or the flags are acknowledged; otherwise one Python start (about 20 ms); never network or git |
| Status line | `⚑ 2 critical`, on an existing line | one stat and a small read |

`agent-notify show` prints the flags in full and acknowledges that date
(`acked.json`), after which the shell line and the status-line marker stay
quiet for it. A new date is announced again. The shell hook skips Python while
`acked.json` is newer than `flags.json`; a rewritten flags file is announced again.

## The tracking issue

The repo comes from `store_remote` in `~/.config/agent-metrics/config.json`
(`AGENT_NOTIFY_REPO=owner/repo` overrides it) and must be a plain GitHub
`owner/name`, else exit 2. The issue is titled exactly
`Agent metrics: flagged days`; `notify-issue` holds its repo and number, and
a value for another repo is ignored. With none usable, `send` looks for an
open issue with that title, else creates one and tries to pin it. If a
comment fails and the remembered issue is closed or gone, `send` replaces it
once; an open issue that refuses a comment is a plain failure.

A comment holds the date, each flag's severity, id and message, each inside
inline code so nothing in it renders as a link, image, mention or reference,
and the report location as a plain path. Ids are limited to identifier
characters (anything else shows as `_invalid`); messages lose control,
format and separator characters. The same cleaning applies to `show`.

## At most once per date

`send` holds a lock around the check, the comment and the record, so two
runs cannot both post. The date is recorded before the comment. A definite
`gh` failure removes the record, so the next run retries. A timeout or a
crash leaves it, because the comment may exist: the run exits 1 saying so
and later runs skip the date. If a post is genuinely missing, run
`agent-notify send --force`. State that cannot be written exits 1 before
anything is posted. `send --dry-run` prints the comment and changes nothing.

## State files

All under `~/.local/state/agent-metrics/`: `notified.json`, `acked.json`
(`{"dates": [...]}`, newest 90 kept) and `notify-issue`
(`{"repo": ..., "number": ...}`). A state file that is not a small regular
file is treated as absent. A flags file that
cannot be read exits 2 naming it; the shell line stays silent instead.

```sh
agent-notify                  # pending flags, last notified date, the issue
agent-notify send --dry-run
systemctl --user list-timers 'agent-notify*'
```
