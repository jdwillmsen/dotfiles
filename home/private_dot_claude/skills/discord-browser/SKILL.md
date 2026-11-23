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

- **Stage, show, then send.** Type the exact text into the composer, screenshot it, and wait for
  the user's approval of that specific message. Send only after approval, or when the user said
  "just send" for that message. Never send on a general "message X" alone.
- **Verify every send** by reloading the channel and confirming the message is still there; a
  post can be accepted and then removed by the server's automod.
- Never handle credentials, tokens or cookies. If Discord shows a login, hand the user the
  viewer link from `agent-browser start`.

## Workflow

```bash
agent-browser start https://discord.com/channels/@me
agent-browser check https://discord.com/channels/@me   # logged_in: yes|no
```

Drive it with `uv run -q --with playwright python script.py` using
`connect_over_cdp("http://127.0.0.1:9222").contexts[0].pages[-1]`; keep scripts in the scratchpad.

1. **Find the DM.** `ul[aria-label="Direct Messages"] li` filtered by `has_text=<name>`, then
   click. Confirm the right person by reading the last messages
   (`li[id^="chat-messages-"]`) and note the `/channels/@me/<id>` URL.
2. **Read channels directly.** Open the channel and read the messages; Discord search misses
   things.
3. **Stage the text.** Click `div[role="textbox"][data-slate-editor="true"]` (last match), then
   `page.keyboard.insert_text(line)` per line with `Shift+Enter` between lines. Plain Enter
   sends. Messages cap at 2000 characters. Markdown works (`**bold**`).
4. **Show it.** Take a screenshot and show the user the text.
5. **Send** with Enter only after approval, then reload and re-read to verify.
6. `agent-browser stop` when done; the login persists.

## Quirks

- Photos must be full quality; iCloud album zips give 360x480 thumbnails. Get originals through
  Taildrop (`sudo tailscale file get --wait=false <dir>`).
- Upload input may be single-file; set `multiple = true` on it before `set_input_files`.
  Videos over 10 MB are rejected; compress with ffmpeg to about 9 MB.
- Some servers remove multi-photo messages; messages of 3 or fewer photos with no caption
  usually survive.
- Reply: hover the message and click the toolbar arrow at (li.x + width - 88, li.y - 8), then
  check the "Replying to" bar before sending.
- Remove one attachment from a posted message: edit it, call `.click()` through JS on the
  "Remove Message Attachment" button, confirm the dialog.
- DM list rows include Friends, Nitro, Shop and Quests before the first person.
