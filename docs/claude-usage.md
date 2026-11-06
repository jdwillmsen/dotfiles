# claude-usage

`~/.local/bin/claude-usage` logs the Claude plan numbers that claude.ai shows
in Settings > Usage, as a time series in
`~/.local/state/agent-metrics/claudeai.jsonl`. It fills the gap the transcript
collector leaves: cloud routines and claude.ai chat or Cowork spend never reach
`~/.claude/projects`, and the plan quota log only has readings while an
interactive session is open.

## How it reads

It uses the devbox browser from [`agent-browser`](agent-browser.md). It opens a
fresh tab in the signed-in profile (so a human using the browser keeps theirs),
lets claude.ai load, and calls the endpoints the usage panel itself calls, from
inside the page:

| Endpoint | What it gives |
|---|---|
| `/api/organizations/<org>/usage` | every quota window with a utilization and reset time: `session_5h`, `weekly`, and per-model or per-product windows when the plan has them |
| `/api/organizations/<org>/prepaid/credits` | the usage-credit balance |
| `/v1/code/promo/cloud_credit` | the cloud-session promo credit: `state` and `expires_at` |

The page's own `fetch` carries the session, so no cookie, token or password is
read, printed or stored. A row holds percentages, reset times, dollar amounts
and the promo state; it holds no account or organisation identifier. Quota
windows are found by shape (an object with a numeric `utilization`), so a new
window is logged without a code change.

If the profile is not signed in the tool exits 3 with a structured error and
the viewer link. The human signs in once; the tool never handles credentials.

## Commands

```
claude-usage                  read and print now (does not write)
claude-usage snapshot         read now and append one row to the log
claude-usage show --limit 24  newest logged readings
```

`claude-usage.timer` runs `snapshot --if-idle` hourly at :07. `--if-idle` skips
the run unless the browser is fully stopped, so a person using the viewer is
never interrupted; a browser the run starts is stopped afterwards, and one that
was running or half up is left as found. While it runs (about 30 seconds) the
viewer is up on the tailnet address, as for any `agent-browser start`. The
timer is enabled only where Chrome, Xvfb, x11vnc, websockify, tailscale and uv
are installed, and the command is not deployed to gaming machines.

## Limits

- The endpoints are the claude.ai web app's, not a documented API. If the usage
  endpoint moves, `snapshot` fails with a structured error naming the status;
  one that returns no quota window logs nothing and fails. A failed credit or
  promo read is logged as `unavailable`, never as a zero balance.
- Exit codes: 3 only when the browser says claude.ai is not signed in; any other
  failure, including a failed sign-in check, is 1.
- The first organisation the page contacts is used; an account in several
  organisations would need that choice made explicit.
- The promo credit endpoint reports state and expiry, not the amount spent. To
  see what a batch of cloud routines cost, take a snapshot before and after.
- Percentages only: Max plan windows report no dollars, so cost stays a
  list-price estimate computed from transcripts by `agent-metrics`.
