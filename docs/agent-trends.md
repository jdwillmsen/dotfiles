# agent-trends

`~/.local/bin/agent-trends build` renders the metrics store into a static
site, `site/index.html` plus one `site/reports/<date>-<window>.html` page per
stored report, in the store, then commits and pushes it
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

A Reports section lists every stored `reports/<date>-<window>.md`, grouped by
window (daily to yearly), newest first. Each links by relative path
(`reports/<name>.html`) to a page rendering that report's Markdown with the
same inline CSS and light or dark setting, and a link back to `../`. The
converter handles only what `agent-report` writes (headings, paragraphs, pipe
tables, bullet lists, inline code and bold). All text is HTML-escaped, links
and raw HTML are not rendered, and anything else shows as escaped text. Pages
for reports that no longer exist are removed on the next build.

## Running it

```sh
agent-trends build --dry-run      # temp dir, prints the path, publishes nothing
agent-trends build --out DIR      # DIR/index.html and DIR/reports/, publishes nothing
agent-trends build [--days N]     # store site/, commit, push (default 90, at most 180)
```

Unreadable store data (a bad line in a session, quota or report file, a cost
that is not a plausible number, a malformed `pr_links` entry) exits 2 naming
the file and writes no page. The build stages only `site/`, so other tools'
files waiting in the store are not committed with it, and new or removed
report pages under `site/reports/` are.

## Viewing it privately

Nothing serves the page. The box's owner runs this once to publish the
store's `site/` directory to the tailnet only (not the public internet):

```sh
tailscale serve --bg --set-path /metrics ~/.local/share/agent-metrics/store/site
```

Serving needs root: run it with `sudo`, or once run
`sudo tailscale set --operator=$USER` so your user can. The page is at
`https://<host>/metrics/`; keep the trailing slash, because the pages link
with relative paths (`reports/<name>.html`) that resolve against it.

Check with `tailscale serve status`; undo with
`tailscale serve --https=443 --set-path /metrics off`. Agents do not run it.
