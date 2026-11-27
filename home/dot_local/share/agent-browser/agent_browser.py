"""Attach a Playwright script to the tab its agent-browser lease owns.

Run scripts through `agent-browser py <lease> script.py`, which sets the
environment this module reads:

    from playwright.sync_api import sync_playwright
    from agent_browser import page

    with sync_playwright() as p:
        pg = page(p)
        pg.goto("https://github.com/settings/profile")

Other agents share the same Chrome, so never touch `context.pages` directly:
another lease's tab, or one the human is signing in on, may be the last one.
"""

import os
import sys


def _target_id(ctx, pg):
    s = ctx.new_cdp_session(pg)
    try:
        return s.send("Target.getTargetInfo")["targetInfo"]["targetId"]
    finally:
        s.detach()


def _record_target(target):
    path = os.environ.get("AGENT_BROWSER_LEASE_FILE")
    if not path:
        return
    with open(path) as f:
        lines = [l for l in f.read().splitlines() if not l.startswith("target=")]
    lines.append(f"target={target}")
    # Replace atomically: agent-browser reads lease files without this
    # script's lock, and a truncated file would read as no lease. The dot
    # keeps the temporary file out of agent-browser's lease glob.
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".tmp")
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def page(p):
    """Return this lease's own page, reopening it if something closed it."""
    cdp = os.environ.get("AGENT_BROWSER_CDP")
    if not cdp:
        sys.exit("error: no_lease\nmessage: run this script through agent-browser\n"
                 "help[1]:\n  agent-browser py <lease> script.py")
    target = os.environ.get("AGENT_BROWSER_TARGET", "")
    ctx = p.chromium.connect_over_cdp(cdp).contexts[0]
    for pg in ctx.pages:
        if _target_id(ctx, pg) == target:
            return pg
    pg = ctx.new_page()
    _record_target(_target_id(ctx, pg))
    print("note: this lease's tab was closed; opened a new one", file=sys.stderr)
    return pg
