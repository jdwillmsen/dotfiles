---
name: discord-browser
description: >
  Read Discord channels and DMs and post messages or files through the devbox agent-browser,
  where the user is already signed in. Use whenever the user asks to send, post, reply to, or
  read something on Discord. There is no API route: bot tokens are credentials and user-token
  automation breaks Discord's terms, so this drives the real web client.
---

# discord-browser

Builds on `agent-browser` (read it first for the login and viewer rules). Discord has no
credential-free API for a person's own account, so send and read through the web client over CDP.

## Rules

- **Stage, show, then send.** Type the exact text into the composer, show the user that full
  text, and wait for their approval of those exact words. "Just send" authorizes sending only
  text the user already supplied or has already approved; if you drafted the wording, still wait
  for approval of it. Never send on a general "message X" alone.
- **Verify every send** by reloading the channel and confirming the message is still there; a
  post can be accepted and then removed by the server's automod.
- Never handle credentials, tokens or cookies. If Discord shows a login, hand the user the
  viewer link from `agent-browser start`.

## Workflow

```bash
agent-browser start https://discord.com/channels/@me   # prints the cdp endpoint
agent-browser check https://discord.com/channels/@me   # logged_in: yes|no
```

Drive it with `uv run -q --with playwright python script.py`; keep scripts in the scratchpad.
Connect to the `cdp:` endpoint that `agent-browser start` printed (9222 only by default), and do
not trust `pages[-1]`: Chrome may already be open on another site, since the start URL applies
only when Chrome launches. Pick the page whose URL contains `discord.com`, or open a new page and
`goto` Discord:

```python
b = p.chromium.connect_over_cdp(CDP)
ctx = b.contexts[0]
page = next((pg for pg in ctx.pages if "discord.com" in pg.url), None) or ctx.new_page()
page.goto("https://discord.com/channels/@me")
```

1. **Find the DM.** List the rows of `ul[aria-label="Direct Messages"] li` and match the name
   exactly (a `has_text` filter on "Ann" also matches "Anna"). If more than one row matches,
   stop and ask the user which one. Click it, confirm the person by reading the last messages
   (`li[id^="chat-messages-"]`), and note the `/channels/@me/<id>` URL.
2. **Read channels directly.** Open the channel and read the messages; Discord search misses
   things.
3. **Stage the text.** Click `div[role="textbox"][data-slate-editor="true"]` (last match). For
   a single line, `page.keyboard.insert_text`. For anything with markdown blocks (`>` quotes,
   code fences, headings), dispatch a `paste` ClipboardEvent carrying the whole text via
   `page.evaluate`: typing line by line with `Shift+Enter` makes the editor auto-continue quote
   and code-fence blocks, which doubles the `>` markers and swallows lines. Check the composer
   text before sending. Plain Enter sends. Messages cap at 2000 characters.
4. **Show it.** Paste the full staged text into your reply for the user to read, and add the
   composer screenshot only as a check that it staged correctly; a screenshot alone can crop or
   hide text.
5. **Send** with Enter only after approval, then reload and re-read to verify.
6. `agent-browser stop` when done; the login persists.

## Quirks

- Photos must be full quality; iCloud album zips give 360x480 thumbnails. Get originals through
  Taildrop (`sudo tailscale file get --wait=false <dir>`; sudo is needed only because the
  Taildrop inbox is root-owned, and the command just moves received files into `<dir>`).
- Upload input may be single-file; set `multiple = true` on it before `set_input_files`.
  Videos over 10 MB are rejected; compress with ffmpeg to about 9 MB.
- Some servers remove multi-photo messages; messages of 3 or fewer photos with no caption
  usually survive.
- Reply: hover the message and click the toolbar arrow at (li.x + width - 88, li.y - 8), then
  check the "Replying to" bar before sending.
- Remove one attachment from a posted message: edit it, call `.click()` through JS on the
  "Remove Message Attachment" button, confirm the dialog.
- Delete your own message: hover it, click `div[role="button"][aria-label="More"]`, choose the
  "Delete Message" menu item, then confirm. Do this at once if a send renders wrong.
- Screenshot the sent message after a reload to confirm markdown rendered (headings, quotes,
  code blocks), not only that the text arrived.
- DM list rows include Friends, Nitro, Shop and Quests before the first person.
