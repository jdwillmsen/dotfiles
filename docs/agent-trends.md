# agent-trends

`~/.local/bin/agent-trends build` renders the metrics store into one static
page, `site/index.html` in the store, then commits and pushes it
(`site: <UTC date>`). `agent-trends.timer` runs it daily at 07:30. Design:
`docs/superpowers/specs/2026-10-09-agent-notify-trends-design.md`.

The page is self-contained: inline CSS and SVG, no fonts, scripts or images
from anywhere, and one small inline script for hover details. It follows the
system light or dark setting. Every chart has a data table under it.

## Content

Tiles for the last 7 days against the 7 before (estimated spend, sessions,
cost per linked PR, weekly quota peak); estimated spend per day by
population; per week by model family; cache read share per week; plan quota
peaks per day; follow-up fix rates, failed-check share and no-mistakes
first-pass rate from stored weekly reports; flagged days from stored daily
reports; spend by repo, pipeline and model for 30 days. A section with no
data says so. Only numbers, dates, model ids, repo names, pipeline names and
flag ids are shown, all HTML-escaped. Dollar figures are list-price
estimates, not a bill.

## Running it

```sh
agent-trends build --dry-run      # temp dir, prints the path, publishes nothing
agent-trends build --out DIR      # DIR/index.html, publishes nothing
agent-trends build [--days N]     # store site/, commit, push (default 90 days)
```

Unreadable store data (a bad line in a session, quota or report file, or a
cost that is not a number) exits 2 naming the file.

## Viewing it privately

Nothing serves the page. The box's owner runs this once to publish the
store's `site/` directory to the tailnet only (not the public internet):

```sh
tailscale serve --bg --set-path /metrics ~/.local/share/agent-metrics/store/site
```

Check with `tailscale serve status`; undo with
`tailscale serve --https=443 --set-path /metrics off`. Agents do not run it.
