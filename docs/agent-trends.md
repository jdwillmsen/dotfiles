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
cost per linked PR, weekly quota peak); a Provider limits section with each
provider's plan, quota windows (a bar, percent used, time to reset) and a
per-day chart of each one's headline window, from the provider readings
(`docs/agent-metrics.md`, Provider limits; a reading over 36 hours old is
marked, and a provider that reports no windows says so); estimated spend per day by
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

## Delivery page

`site/delivery.html`, linked from the index and linking back, is built with the
same inline CSS, palette and chart helpers from the delivery mirror
(`docs/agent-metrics.md`, Delivery ledgers) and the quota log. It shows tiles
(merges, median time to merge, approvals; 7 days against the 7 before); merges
per day stacked by risk tier; median time to merge per week; mean review
findings per delegated outcome per week; approvals per day by state; why pull
requests wait (distinct PRs per blocked, waiting or needs-human reason, 30
days, live runs); rollout states, only when rollout rows exist; a lane and
model scoreboard (outcomes, completed share, CI first pass, merged, mean
findings, median duration) with captain reviews by lane; and the weekly quota
peak per day with agent-pace assignment counts in the tooltip. Each section
says so when it has no data.

Limits worth knowing: only merges the merge captain made are counted;
time to merge runs from the captain first seeing the PR, not from opening it;
findings and CI first pass appear only once `agent-eval enrich` has joined the
outcome to its PR; a malformed mirrored row exits 2 naming the file.

## Running it

```sh
agent-trends build --dry-run      # temp dir, prints the path, publishes nothing
agent-trends build --out DIR      # DIR/index.html and DIR/reports/, publishes nothing
agent-trends build --delivery-only  # only delivery.html; no sessions, providers or reports read
agent-trends build [--days N]     # store site/, commit, push (default 90, at most 180)
```

Unreadable store data (a bad line in a session, quota or report file, a cost
that is not a plausible number, a malformed `pr_links` entry) exits 2 naming
the file and writes no page. The build stages only `site/`, so other tools'
files waiting in the store are not committed with it, and new or removed
report pages under `site/reports/` are.

`build --delivery-only` takes the same `--out` and `--dry-run` and, with neither,
commits `site/delivery.html` alone. It is the cheap path for a frequent
refresh. Follow-up, not built: a 15-minute timer running `agent-metrics
delivery sync` then `agent-trends build --delivery-only`. It would add about 96
store commits a day, so it needs a decision on skipping the commit when only
the "Generated" time changed.

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
