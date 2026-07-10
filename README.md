# tmux-overview

> Watch every tmux session at once — a read-only, live tiled dashboard with zoom.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Shell: POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25.svg)
![tmux: 3.2+](https://img.shields.io/badge/tmux-3.2%2B-1BB916.svg)

[한국어 README](./README.ko.md)

If you run several AI coding agents (Claude Code, Codex, Aider, ...) in separate tmux sessions, keeping an eye on them means cycling through sessions one at a time. **tmux-overview** mirrors the active pane of *every* session into a single tiled grid, live, so you can see at a glance who is working (**RUN**) and who is waiting for input (**IDLE**) — and jump straight into a session the moment it needs you. It is a single dependency-free POSIX shell script; the mirroring is purely read-only, so your working sessions are never touched, resized, or interrupted.

## Demo

![tmux-overview — six live sessions mirrored in one grid, each with a RUN/IDLE header](./assets/overview.png)

<details>
<summary>Text-only preview (for environments where the image doesn't render)</summary>

```
┌ agent-api ─────────────────────────────┐┌ agent-web ─────────────────────────────┐
│ agent-api [node]  RUN                  ││ agent-web [node]  IDLE 42s             │
│ ⏺ Running tests… (esc to interrupt)    ││ ❯ Plan ready. Proceed? (y/n)           │
│   PASS src/routes/auth.test.ts         ││                                        │
└────────────────────────────────────────┘└────────────────────────────────────────┘
┌ agent-docs ────────────────────────────┐┌ scratch ───────────────────────────────┐
│ agent-docs [claude]  RUN               ││ scratch [zsh]  IDLE 317s               │
│ ⏺ Editing migration guide…             ││ ~ $                                    │
│   +42 −7 README.md                     ││                                        │
└────────────────────────────────────────┘└────────────────────────────────────────┘
```

</details>

Green header = output flowing in the last few seconds (agent busy). Yellow header = output stopped for N seconds (waiting for input, or done). Red banner = session ended.

## Features

- **Live tiled mirror of all sessions.** Each tile mirrors one session's active pane via `tmux capture-pane -ep` about once a second — ANSI colors preserved, output bottom-aligned (where agent activity is), and each line hard-truncated (ANSI- and UTF-8-aware) to the tile width so a wider agent TUI stays aligned instead of wrapping into a broken mess. Flicker-free repaint.
- **RUN / IDLE status per tile.** Based on `window_activity`: output within the last 3 s → **RUN** (green); otherwise **IDLE Ns** (yellow). Since agents keep the screen updating while working (spinners, streaming), this cleanly separates "busy" from "waiting for you".
- **Self-updating grid.** Global `session-created` / `session-closed` hooks (registered at index `[99]`, so they coexist with your own hooks) reconcile the grid automatically — new sessions get a tile, closed ones lose theirs. If the dashboard is gone, the hooks remove themselves.
- **One-key zoom.** Focus a tile, hit a key, and you `switch-client` full-screen into that session — same terminal client, so no nested-attach resize side effects. Same key brings you back to the grid.
- **Session filtering.** `build '<pattern>'` shows only matching sessions; the pattern is remembered in the `@overview_filter` session option so hook-driven updates respect it.
- **Zero dependencies.** One POSIX `sh` script + tmux. Works from any install location (resolves its own absolute path for hooks and tiles).

## Requirements

- tmux **≥ 3.2** (developed and tested on tmux 3.6; see [docs/DESIGN.md](./docs/DESIGN.md) for the feature-by-feature version rationale)
- POSIX `sh` (any macOS / Linux)

## Installation

### Manual

```sh
# 1. Put overview.sh somewhere on disk (any location works), e.g.:
mkdir -p ~/.local/bin
curl -fLo ~/.local/bin/overview.sh \
  https://raw.githubusercontent.com/justice-hwan/tmux-overview/main/overview.sh
chmod +x ~/.local/bin/overview.sh

# 2. Add the keybindings to your tmux config (usually ~/.tmux.conf; if you keep
#    yours at ~/.config/tmux/tmux.conf, append there instead):
cat >> ~/.tmux.conf <<'EOF'

# tmux-overview
bind-key a     run-shell "$HOME/.local/bin/overview.sh toggle"
bind-key A     run-shell "$HOME/.local/bin/overview.sh rebuild"
bind-key Enter run-shell "$HOME/.local/bin/overview.sh zoom"
EOF

# 3. Reload, then CONFIRM the keys registered — this one check catches the most
#    common setup mistake (bindings added to a file tmux didn't load):
tmux source-file ~/.tmux.conf
tmux list-keys | grep overview.sh          # must print three lines; if empty, see Troubleshooting
```

Or clone the repo and run the bundled installer, which copies the script to `${XDG_BIN_HOME:-$HOME/.local/bin}` and prints the keybinding snippet:

```sh
git clone https://github.com/justice-hwan/tmux-overview.git
cd tmux-overview && ./install.sh
```

### TPM (Tmux Plugin Manager)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'justice-hwan/tmux-overview'
```

Then press `prefix + I` to install. The plugin binds the default keys below; customize them with:

```tmux
set -g @overview-key 'a'            # toggle dashboard (default: a)
set -g @overview-rebuild-key 'A'    # force rebuild    (default: A)
set -g @overview-enter-key 'Enter'  # zoom into tile   (default: Enter)
```

## Keybindings

For manual installs, add this to `~/.tmux.conf` (adjust the path to where you put the script):

```tmux
# tmux-overview
bind-key a     run-shell "$HOME/.local/bin/overview.sh toggle"   # outside: open dashboard / inside: enter focused tile
bind-key A     run-shell "$HOME/.local/bin/overview.sh rebuild"  # force rebuild (rarely needed — grid self-updates)
bind-key Enter run-shell "$HOME/.local/bin/overview.sh zoom"     # inside dashboard: enter focused tile's session
```

All keys are freely customizable — these are only suggestions. In particular, if you use `C-a` as your tmux prefix, `prefix + a` may clash with a habit or another binding; pick any key you like (`bind-key g ...` etc.). The script itself never binds keys.

## Usage & workflow

1. **Open** — `prefix + a` from anywhere. The dashboard session is built on first use (one tile per session) and reused afterwards.
2. **Scan** — the grid updates itself about once a second. Green means the agent is working; yellow with a growing idle counter usually means it wants input.
3. **Move focus** — use your normal tmux pane navigation (`prefix + arrow keys`, or the mouse if `mouse on`).
4. **Dive in** — with a tile focused, `prefix + a` (or `prefix + Enter`) switches you full-screen into that session. Interact as usual.
5. **Return** — `prefix + a` again brings you back to the dashboard. Repeat.

The grid tracks session lifecycle automatically: start a new agent session and a tile appears; a session exits and its tile disappears.

### CLI

The script can also be driven directly (run from inside any tmux client):

| Command | What it does |
|---|---|
| `overview.sh build [pattern]` | (Re)create the dashboard. Optional grep `pattern` filters session names (default: all). |
| `overview.sh toggle` | Outside the dashboard: open (building if needed). Inside: switch into the focused tile's session (or back to the previous session if the tile is dead). |
| `overview.sh rebuild` | Force a re-sync of the grid in place (no teardown, so an attached client is never dropped), or build it if absent. |
| `overview.sh zoom` | Inside the dashboard: switch into the focused tile's session. |
| `overview.sh reconcile` | Sync the grid with the live session list (normally fired by hooks). |
| `overview.sh kill` | Remove the dashboard session and unregister its hooks. |
| `overview.sh mirror <session>` | Internal — the mirror loop that runs inside each tile. |

## Configuration

All configuration is via environment variables, read each time the script runs:

| Variable | Default | Description |
|---|---|---|
| `OVERVIEW_SESSION` | `overview` | Name of the dashboard session. |
| `OVERVIEW_WIDTH` | `188` | Width the dashboard session is created with (it is created detached; match your terminal size so the tile layout is computed correctly). |
| `OVERVIEW_HEIGHT` | `53` | Height the dashboard session is created with. |
| `OVERVIEW_IDLE_SEC` | `3` | Seconds without output before a tile flips RUN → IDLE. |
| `OVERVIEW_INTERVAL` | `1` | Mirror refresh interval, in seconds. |
| `OVERVIEW_EXCLUDE_SELF` | *(unset)* | If set (to anything), the session you launch the dashboard **from** is left out of the grid. Applied at build time only — see Limitations. |

Since keybindings invoke the script through `run-shell`, set variables inline in the binding:

```tmux
bind-key a run-shell "OVERVIEW_WIDTH=220 OVERVIEW_HEIGHT=60 OVERVIEW_IDLE_SEC=5 $HOME/.local/bin/overview.sh toggle"
```

**Filtering with `@overview_filter`.** `build` accepts a grep pattern and stores it in the dashboard session's `@overview_filter` option, so automatic reconciles keep honoring it:

```sh
overview.sh build '^agent-'    # only sessions whose names start with "agent-"
```

```tmux
# or as a binding that always builds a filtered dashboard:
bind-key a run-shell "$HOME/.local/bin/overview.sh toggle"
bind-key A run-shell "$HOME/.local/bin/overview.sh build '^agent-'"
```

## How it works

- **Mirroring.** Each tile runs `overview.sh mirror <session>`: a loop that captures the target session's active pane with `tmux capture-pane -ep` (`-e` preserves ANSI colors/attributes), takes the bottom `rows − 1` lines, hard-truncates each to the tile width with an ANSI-aware `awk` pass (SGR color sequences are copied uncounted, UTF-8 multibyte glyphs count as one, a reset is appended on cut), and repaints the tile using cursor-home + per-line erase escapes (`ESC[H`, `ESC[K`, `ESC[J`) — no full clears, so no flicker. Capturing is a pure read: the target session is never attached, resized, or sent input.
- **State detection.** The header compares `#{window_activity}` (last output, epoch seconds) against now. Within `OVERVIEW_IDLE_SEC` → RUN; beyond it → IDLE with the idle duration. If the target session vanishes, the tile shows a red `session ended` banner until reconcile removes it. The header also shows `#{pane_current_command}` so you can see what's running.
- **Grid reconciliation.** `build` registers two global hooks, `session-created[99]` and `session-closed[99]`, that call `overview.sh reconcile`. Reconcile diffs the live session list (through `@overview_filter`) against the grid — each tile carries its target in a `@mirror_target` pane option — then adds missing tiles, kills stale ones, and re-applies the `tiled` layout. The high hook index keeps your own `session-created`/`session-closed` hooks untouched, and if the dashboard session no longer exists, reconcile unregisters the hooks (self-healing).
- **Zoom.** Reads the focused pane's `@mirror_target` and runs `switch-client -t <target>`. Because it's the same terminal client switching sessions (not a nested attach), the target keeps its size — no reflow damage to running TUIs. The empirical study behind this design is in [docs/DESIGN.md](./docs/DESIGN.md).

## Limitations

Honest constraints, by design or by tmux's nature:

- **Read-only, ~1 s latency.** Tiles are mirrors: you cannot type into them or scroll their history, and updates lag by up to `OVERVIEW_INTERVAL`. Cursor position and in-progress IME composition are not shown. To interact, zoom in.
- **Wide content is truncated, not wrapped.** Each source line is hard-cut (ANSI-aware, UTF-8-aware) to the tile width, so a session wider than its tile shows only its left portion — you keep clean, aligned rows and a readable TUI (e.g. an agent's input box) instead of a wrapped mess, at the cost of the right edge. Practically a ~190×50 terminal stays readable at **6–9 tiles**; if a split fails with "pane too small" the script warns and skips the rest. Use a filter or fewer columns to see more of each session.
- **Active pane only.** Each tile mirrors the *active pane of the active window* of its session. If your agent lives in a background window of that session, the tile shows whatever window is active there instead.
- **RUN/IDLE is a heuristic.** It keys off screen output. An agent that thinks silently without repainting reads IDLE; "done" and "waiting for input" both read IDLE.
- **The dashboard is itself a tmux session**, so it appears in `list-sessions` and session pickers (rename via `OVERVIEW_SESSION` if you want it sorted out of the way).
- **`OVERVIEW_EXCLUDE_SELF` applies at build time only.** A later hook-driven reconcile only knows `@overview_filter`, so it can add the launcher session back. For a persistent exclusion, use a build filter pattern instead.

## Troubleshooting

**`prefix + a` does nothing / no reaction.** The script and tmux are almost always fine — the keybinding simply isn't loaded. This is the most common setup issue. Check first:

```sh
tmux list-keys | grep overview.sh     # should print three lines
```

- **Prints nothing** → the bindings aren't loaded — you either skipped the `bind-key` lines, didn't reload, or put them in a file tmux doesn't read. Ask tmux exactly which files it loaded and make sure your bindings are in one of them:

  ```sh
  tmux display -p '#{config_files}'   # the config file(s) tmux actually loaded
  # add the bind-key lines to one of those, then:
  tmux source-file "<that file>"
  ```

  To confirm the tool itself works in the meantime, bind live (no file needed): `tmux bind-key a run-shell "$HOME/.local/bin/overview.sh toggle"`.

- **Prints the three lines but the key still does nothing** → you're pressing the wrong prefix, or `a` is shadowed. Check your prefix (default `C-b`) and press *that*, then `a`:

  ```sh
  tmux show -g prefix
  ```

  If your prefix is `C-a`, the `a` key may clash — bind a different one (e.g. `bind-key g ...`).

**Tiles are blank or show the wrong thing** → a tile mirrors only the *active pane of the active window* of each session; make sure that's where your agent is. On tmux < 3.0 (no pane-scoped user options) the grid can misbehave — check `tmux -V`.

## Uninstall

```sh
# 1. Stop the dashboard and remove its global hooks:
~/.local/bin/overview.sh kill

# 2. Delete the three bind-key lines from your tmux config, then reload.
#    Use the file `tmux display -p '#{config_files}'` reports.

# 3. Delete the script:
rm ~/.local/bin/overview.sh
```

If you deleted the script *before* running `kill`, clear the leftover hooks by hand:

```sh
tmux set-hook -gu 'session-created[99]'
tmux set-hook -gu 'session-closed[99]'
```

**TPM users:** remove the `set -g @plugin 'justice-hwan/tmux-overview'` line and press `prefix + alt + u`.

## Contributing

Issues and PRs are welcome. Please keep the script POSIX `sh` (no bashisms — check with `sh -n` / `shellcheck -s sh`) and dependency-free, and note the tmux version you tested on. Design context and the measurements behind the current architecture live in [docs/DESIGN.md](./docs/DESIGN.md).

## License

[MIT](./LICENSE) © 2026 justice-hwan
