# agent-notify

`~/.local/bin/agent-notify` tells the box's owner when the daily report raised
flags. It reads `~/.local/state/agent-metrics/flags.json`, which the daily
report writes only on a day with flags. Design: `docs/superpowers/specs/2026-10-09-agent-notify-trends-design.md`.

## Three places a flag shows

| Where | How | Cost |
|---|---|---|
| Tracking issue | `agent-notify send`, daily 07:20 from `agent-notify.timer`: one comment per flagged date | one `gh` call set, once per date |
| Weekly digest | `agent-notify digest`, Mondays 09:10 UTC from `agent-notify-digest.timer`: one comment per weekly report | one `gh` call set, once per report |
| New shell | `agent-notify shell` prints one line such as `agent-metrics: 2 flags for 2026-10-08 (1 critical): run agent-notify show`, only when stdout is a terminal | plain tests only when nothing is pending or the flags are acknowledged; otherwise one Python start (about 20 ms); never network or git |
| Status line | `⚑ 2 critical`, on an existing line | one stat and a small read |

`agent-notify show` prints the flags in full and acknowledges that date
(`acked.json`), after which the shell line and the status-line marker stay
quiet for it. A new date is announced again. The shell hook skips Python while
`acked.json` is newer than `flags.json`; a rewritten flags file is announced again.

## The tracking issue

This describes the `github-issue` channel; see Channels for the rest.

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

## Channels

Every message (topics `flags` and `digest`) goes to each channel in the
`notify` object of `~/.config/agent-metrics/config.json`; without one, a
single `github-issue` channel posting as `gh` is used. Channels get their turn
independently: one failing is reported in the `channels` table and exit 1, the
others still post, and only the failed one retries.

```json
{"notify": {"dashboard_url": "https://devbox.tail5bbd6f.ts.net/metrics/",
            "channels": [{"type": "github-issue", "identity": "app"}]}}
```

`dashboard_url` (http or https) only adds links to the digest. A channel may
set `name` (default: its type; needed to tell two of one type apart) and, for
`github-issue`, `repo` (default: the store repo). Unknown types, duplicate
names or malformed values exit 2 before anything is sent. State of the
default `github-issue` channel keeps its original file names; other channels
use `<name>.` as a prefix.

**Add a channel type:** subclass `Channel` in `agent-notify` (`target`,
`prepare` if setup can fail before notifying, `post(topic, body)` returning a
result dict, raising `ChannelError` on failure) and add it to `CHANNEL_TYPES`.
The lock, at-most-once records, rollback and output are shared.

### App identity

GitHub never notifies you of your own comments, so `"identity": "app"` posts
the comment as `jdwlabs-agent-bot`. At send time the channel reads
`GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY` from secret `ai-sre-relay` in
`ai-sre` (`kubectl`), signs a JWT with `openssl` (the key goes through a pipe,
never a file or an argument), finds the App's installation on the repo
(`GET /repos/{repo}/installation`) and exchanges it for a token scoped to that
repository. The token reaches `gh` only as `GH_TOKEN`, and only for the
comment call: finding, creating and pinning the issue stay with your `gh`
login, so you are the issue author and are the one notified. Neither key, JWT
nor token is printed, logged, stored or put in an argument list.

If minting fails (no `kubectl`, App not installed on the repo, refused
exchange, network) or `gh` is refused the comment (the App lacks the Issues
permission), the comment is posted as `gh` instead and the output carries
`identity: gh`, a `fallback` reason and a `help` line. Nothing is silent.

**One-time setup:** install the `jdwlabs-agent-bot` App on the account that
owns the store repo (`jdwillmsen`), with access to that repository, and give
it the Issues: read & write permission (the installation then asks you to
accept it). Check with `agent-notify send --force`.

## Weekly digest

`agent-notify digest [--dry-run] [--force] [--date YYYY-MM-DD]` reads the
newest `reports/<date>-weekly.json` in the metrics store (or the one for
`--date`) and posts to the issue `Agent metrics: weekly digest`: the window,
interactive spend, sessions, linked PRs, cost per linked PR and peak weekly
quota against the previous week with percent change (`n/a` when a value is
missing or the previous one is zero), the flags the daily reports raised in
the window, and, when `dashboard_url` is set, links to the dashboard and to
`reports/<date>-weekly.html`. Text from the data gets the same cleaning as flag
comments. Once per report date (`digest-notified.json`); `--force` re-sends.
With no weekly report it says so and exits 0.

`agent-notify-digest.service` first runs `agent-trends build` so the report
page it links exists (a failed build still posts), and runs after
`agent-report@weekly.service` when a catch-up boot queues both. It needs
`kubectl`, `openssl` and `gh` on its PATH
(`/usr/bin`) and reads `~/.kube/config`; `NoNewPrivileges` and `PrivateTmp`
leave both alone.

## State files

All under `~/.local/state/agent-metrics/`: `notified.json`, `digest-notified.json`,
`acked.json` (`{"dates": [...]}`, newest 90 kept), and `notify-issue` and
`digest-issue` (`{"repo": ..., "number": ...}`). A state file that is not a small regular
file is treated as absent. A flags file that
cannot be read exits 2 naming it; the shell line stays silent instead.

```sh
agent-notify                  # pending flags, last notified date, the issue
agent-notify send --dry-run
agent-notify digest --dry-run
systemctl --user list-timers 'agent-notify*'
```
