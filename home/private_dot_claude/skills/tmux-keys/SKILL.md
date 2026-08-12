---
name: tmux-keys
description: >
  Look up tmux keybindings for this machine — what key does X, what is bound to Y, or the full
  grouped cheatsheet. Use when the user asks about tmux shortcuts, says they forgot a tmux
  binding, wants a tmux cheatsheet, or when you need to tell them which keys to press inside
  tmux. Also use before suggesting a new tmux binding, to check the key is free.
---

# tmux keybindings

`tmux-cheat` reads the live tmux config at `~/.tmux.conf` and merges in the stock tmux
bindings that config does not override, so its answers match what the keyboard actually does.
Never answer tmux-binding questions from general knowledge — this config remaps the prefix and
several defaults.

## Commands

```bash
tmux-cheat --toon              # every binding, token-efficient (preferred)
tmux-cheat --toon --custom     # only bindings this config defines
tmux-cheat --toon pane         # filter by key, action, group, or raw tmux command
tmux-cheat --json              # same data plus the raw tmux command per binding
```

Output fields: `key` (as typed, prefix already expanded), `action`, `group`,
`source` (`config` | `default` | `plugin`).

## Answering

- Quote the `key` column verbatim — it already includes the prefix, so
  `Ctrl+a |` means press `Ctrl+a`, release, then `|`.
- A `key` starting with `copy-mode` is pressed inside copy mode, not from the prompt.
- Filter rather than dumping all bindings; the unfiltered list is ~58 rows.
- `source: default` means tmux ships it and the config leaves it alone. Say so when it matters —
  it tells the user the binding survives a config change.

## Adding a binding

Check the key is free first: `tmux-cheat --toon "<key>"`. Bindings live in the chezmoi source
at `home/dot_tmux.conf`, not in `~/.tmux.conf` directly — edit the source, then `chezmoi apply`.
Group the new binding under a `# ===` comment header like the surrounding ones.

## Visual output

`tmux-cheat --html --out <path>` writes a self-contained, theme-aware HTML page. Use it when the
user wants a shareable or browser-viewable cheatsheet; it is also publishable as an artifact
as-is. Inside tmux, `tmux-cheat --popup` (bound to `prefix ?`) opens a scrollable overlay
without disturbing the session.
