---
name: agent-browser
description: >
  Drive a real, logged-in web browser on the devbox for tasks that have no API, such as
  LinkedIn profile edits, GitHub settings pages, or job sites, while the human handles every
  login. Use whenever a task needs a website the user is signed in to, when Playwright MCP
  would be logged out or headless, or when the user mentions the remote browser or noVNC.
---

# agent-browser

A persistent Chrome profile on the devbox, shown to the human through a noVNC viewer on the
tailnet and driven by agents over loopback CDP. The human signs in once per site; later tasks
reuse the session. Several agents can use it at once, each in its own leased tab or slot.

## Rules (non-negotiable)

- **Never handle credentials.** Do not type, read, fill, screenshot-to-read or store passwords,
  2FA codes, recovery codes or cookies. Do not read the profile's cookie or login databases.
  If a page asks for a login, stop and hand the human the viewer link.
- **Show before you change.** Outward-facing edits (profiles, posts, messages, settings) need
  the user's approval of the exact content first, then a read-back of the saved result.
- **Never send messages or apply to jobs** without explicit approval of that specific action.
- **Do not navigate a tab the human is using to log in.** Wait for them to say they are done.
- **Release your lease** with `agent-browser stop <lease>` when the task ends. It closes only
  your tab; the browser and viewer stop when the last lease goes. Never run a bare `stop` or
  `stop --force` to "clean up": other agents may be mid-task in the same browser.

## Parallel agents

Other sessions share this browser. Every `start` takes a **lease** that owns one tab:

- **Shared (default)**: `agent-browser start <URL>`. Slot 0, the profile the human signs in to;
  your tab sits beside other agents' tabs. Use this unless one of the cases below applies.
- **Isolated**: `agent-browser start --slot auto <URL>`. A separate Chrome, viewer and profile
  (slots 1-3). Use it when another agent may be on the same site with the same account (two
  edits to one LinkedIn profile, two Discord sends), or a task needs a clean session. Each
  slot's profile has its own logins, so the human may need to sign in there once.

Never pick a tab from `context.pages` (`pages[-1]` is someone else's tab or the human's login
page). Drive only your own tab, through the `agent_browser` helper.

## Workflow

```bash
agent-browser start [--slot auto] URL   # prints lease:, viewer:, cdp:; opens your own tab
agent-browser check <github|linkedin|URL> --lease <lease>   # logged_in: yes|no
agent-browser py <lease> script.py      # run Playwright attached to your tab
agent-browser show <lease>              # bring your tab to the front of the viewer
agent-browser stop <lease>              # end of task; sessions persist in the profile
agent-browser                           # status: every slot, its leases and viewer
```

1. `agent-browser start <URL>` and keep the printed `lease:` for every later call. If `check`
   says `logged_in: no`, run `agent-browser show <lease>`, send the user the viewer link and
   wait for "logged in".
2. Write the script in the session scratchpad and run it with `agent-browser py <lease>
   script.py`:

   ```python
   from playwright.sync_api import sync_playwright
   from agent_browser import page

   with sync_playwright() as p:
       pg = page(p)   # your lease's tab; reopened if something closed it
       pg.goto("https://github.com/settings/profile")
   ```

   Prefer role/text locators; fall back to coordinates from a screenshot only when a control
   has no label. Calls through `py`, `check` and `show` keep the lease alive; a lease unused
   for 2 hours expires.
3. Verify every save by re-reading the live page, then `agent-browser stop <lease>`.

## Known site quirks

- LinkedIn rich-text editors ignore Ctrl+A; select with a JS range and press Backspace.
  Blank lines double up, so type only non-empty lines. Link previews to deep GitHub paths
  often fail; a blob URL to a README works.
- GitHub social preview and org avatars have no API; upload through the hidden
  `input[type=file]` with `set_input_files`.

`agent-browser wipe --yes [--slot N]` deletes every saved login in that slot (only when the user
asks).
Details: `docs/agent-browser.md` in the dotfiles repo.
