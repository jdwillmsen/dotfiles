# tmux

tmux is a terminal multiplexer — it lets you run multiple terminals inside a single terminal window, keep sessions alive after you disconnect, and pick back up where you left off.

## Concepts

| Term | What it means |
|------|--------------|
| **Session** | A collection of windows. Survives terminal close / SSH disconnect. |
| **Window** | A tab inside a session. Full-screen, like browser tabs. |
| **Pane** | A split inside a window. Multiple terminals side by side. |

## Starting tmux

```bash
tmux                        # new session
tmux new -s work            # new session named "work"
tmux attach                 # re-attach to last session
tmux attach -t work         # re-attach to "work"
tmux ls                     # list running sessions
```

## Key bindings

This config uses **Ctrl+A** as the prefix (more ergonomic than the default Ctrl+B).

### No prefix needed

| Key | Action |
|-----|--------|
| Alt+Arrow | Move between panes |
| Ctrl+Shift+Left/Right | Switch windows |
| Mouse click | Focus pane |
| Mouse scroll | Scroll pane history |

### After pressing Ctrl+A

| Key | Action |
|-----|--------|
| `|` | Split pane vertically |
| `-` | Split pane horizontally |
| `c` | New window |
| `x` | Close pane |
| `&` | Close window |
| `,` | Rename window |
| `$` | Rename session |
| `d` | Detach (session stays alive) |
| `z` | Zoom pane (toggle fullscreen) |
| `[` | Enter scroll/copy mode (q to exit) |
| `r` | Reload config |
| H/J/K/L | Resize pane (hold for repeat) |

### Copy mode (Ctrl+A then `[`)

| Key | Action |
|-----|--------|
| Arrow keys / hjkl | Navigate |
| `v` | Start selection |
| `y` | Copy and exit |
| `q` | Exit copy mode |

## Sessions workflow

```bash
# Start a session per project
tmux new -s dotfiles
tmux new -s work

# Switch between them
tmux switch -t work        # from inside tmux
tmux attach -t dotfiles    # from outside tmux
```

## Auto-start (optional)

Add to `~/.zshrc` or `~/.bashrc` to attach automatically:

```bash
if command -v tmux &>/dev/null && [ -z "$TMUX" ]; then
    tmux attach 2>/dev/null || tmux new -s main
fi
```
