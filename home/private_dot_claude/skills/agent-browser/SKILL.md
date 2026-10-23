---
name: agent-browser
description: >
  Drive a real, logged-in web browser on the devbox for tasks that have no API, such as
  LinkedIn profile edits, GitHub settings pages, or job sites, while the human handles every
  login. Use whenever a task needs a website the user is signed in to, when Playwright MCP
  would be logged out or headless, or when the user mentions the remote browser or noVNC.
---

# agent-browser

One persistent Chrome profile on the devbox, shown to the human through a noVNC viewer on the
tailnet and driven by the agent over loopback CDP. The human signs in once per site; later
tasks reuse the session.

## Rules (non-negotiable)

- **Never handle credentials.** Do not type, read, fill, screenshot-to-read or store passwords,
  2FA codes, recovery codes or cookies. Do not read the profile's cookie or login databases.
  If a page asks for a login, stop and hand the human the viewer link.
- **Show before you change.** Outward-facing edits (profiles, posts, messages, settings) need
  the user's approval of the exact content first, then a read-back of the saved result.
- **Never send messages or apply to jobs** without explicit approval of that specific action.
- **Do not navigate a tab the human is using to log in.** Wait for them to say they are done.
- **Close the viewer** with `agent-browser stop` when the task ends. The profile stays.

## Workflow

```bash
agent-browser                  # status: components, viewer URL, CDP endpoint
agent-browser start [URL]      # idempotent; prints the viewer link for the human
agent-browser check github     # logged_in: yes|no (also: linkedin, or any URL)
agent-browser stop             # end of task; sessions persist in the profile
```

1. `agent-browser start <site>`; if `check` says `logged_in: no`, send the user the viewer
   link and wait for "logged in".
2. Drive the page with Playwright over CDP:
   `uv run -q --with playwright python script.py`, where the script does
   `p.chromium.connect_over_cdp("http://127.0.0.1:9222").contexts[0].pages[-1]`.
   Keep scripts in the session scratchpad. Prefer role/text locators; fall back to
   coordinates from a screenshot only when a control has no label.
3. Verify every save by re-reading the live page, then `agent-browser stop`.

## Known site quirks

- LinkedIn rich-text editors ignore Ctrl+A; select with a JS range and press Backspace.
  Blank lines double up, so type only non-empty lines. Link previews to deep GitHub paths
  often fail; a blob URL to a README works.
- GitHub social preview and org avatars have no API; upload through the hidden
  `input[type=file]` with `set_input_files`.

`agent-browser wipe --yes` deletes every saved login (only when the user asks).
Details: `docs/agent-browser.md` in the dotfiles repo.
