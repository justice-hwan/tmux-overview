# tmux-overview

> Watch every tmux session at once — a read-only, live tiled dashboard with zoom.

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Shell: POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25.svg)
![tmux: 3.2+](https://img.shields.io/badge/tmux-3.2%2B-1BB916.svg)

[한국어 README](./README.ko.md)

If you run several AI coding agents (Claude Code, Codex, Aider, ...) in separate tmux sessions, keeping an eye on them means cycling through sessions one at a time. **tmux-overview** mirrors the active pane of *every* session into a single tiled grid, live, so you can see at a glance who is working (**RUN**) and who is waiting for input (**IDLE**) — and jump straight into a session the moment it needs you. It is a single dependency-free POSIX shell script; the mirroring is purely read-only, so your working sessions are never touched, resized, or interrupted.

## Demo

![tmux-overview — six live sessions mirrored in one grid, each with a RUN/IDLE border](./assets/overview.png)

<details>
<summary>Text-only preview (for environments where the image doesn't render)</summary>

```
┌ RUN  agent-api [node] ─────────────────┐┌ IDLE 42s  agent-web [node] ────────────┐
│ ⏺ Running tests… (esc to interrupt)    ││ ❯ Plan ready. Proceed? (y/n)           │
│   PASS src/routes/auth.test.ts         ││                                        │
│   PASS src/routes/user.test.ts         ││                                        │
└────────────────────────────────────────┘└────────────────────────────────────────┘
┌ RUN  agent-docs [claude] ──────────────┐┌ IDLE 317s  scratch [zsh] ──────────────┐
│ ⏺ Editing migration guide…             ││ ~ $                                    │
│   +42 −7 README.md                     ││                                        │
│                                        ││                                        │
└────────────────────────────────────────┘└────────────────────────────────────────┘
```

</details>

Green border = output flowing in the last few seconds (agent busy). Yellow border = output stopped for N seconds (waiting for input, or done). Red border = session ended.

## Features

- **Live tiled mirror of all sessions.** Each tile mirrors one session's active pane via `tmux capture-pane -ep` about once a second — ANSI colors preserved, output bottom-aligned (where agent activity is), and each line hard-truncated (ANSI- and UTF-8-aware) to the tile width so a wider agent TUI stays aligned instead of wrapping into a broken mess. Flicker-free repaint.
- **RUN / IDLE status on each tile's border.** Shown in the tile's top border — the divider that also carries the session name — and drawn by tmux itself, so it never flickers. Based on `window_activity`: output within the last 3 s → **RUN** (green); otherwise **IDLE Ns** (yellow); a vanished session shows **DEAD** (red). The color changes live with state. Since agents keep the screen updating while working (spinners, streaming), this cleanly separates "busy" from "waiting for you".
- **Self-updating grid.** Global `session-created` / `session-closed` hooks (registered at index `[99]`, so they coexist with your own hooks) reconcile the grid automatically — new sessions get a tile, closed ones lose theirs. If the dashboard is gone, the hooks remove themselves.
- **One-key zoom.** Focus a tile, hit a key, and you `switch-client` full-screen into that session — same terminal client, so no nested-attach resize side effects. Same key brings you back to the grid.
- **Session filtering, two ways.** A live ERE filter (`filter '<regex>'`, cleared with `unfilter`) narrows the grid to matching session names, remembered in the `@overview_filter` session option so hook-driven updates keep respecting it. Or pick sessions one at a time with a checkbox menu (`pickmenu` / `pick <session>`) when you don't want to write a regex. The two modes share one underlying filter and are mutually exclusive — switching to one clears the other.
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

# Filter/pick live in a small pop-up menu (a tmux display-menu) opened with
# <prefix> C-a, so they never clobber your global prefix keys (find-window /
# previous-window stay intact). In the menu: f=filter, p=pick, c=clear, r=refresh - or
# use the arrow keys / mouse.
bind-key C-a display-menu -T "#[align=centre] overview " \
  "Filter (regex)…" f "command-prompt -p \"overview filter (ERE):\" \"run-shell \\\"$HOME/.local/bin/overview.sh filter '%%'\\\"\"" \
  "Pick sessions…"  p "run-shell \"$HOME/.local/bin/overview.sh pickmenu\"" \
  "Clear filter"    c "run-shell \"$HOME/.local/bin/overview.sh unfilter\"" \
  "Refresh interval…" r "run-shell \"$HOME/.local/bin/overview.sh intervalmenu\""
EOF

# 3. Reload, then CONFIRM the keys registered — this one check catches the most
#    common setup mistake (bindings added to a file tmux didn't load):
tmux source-file ~/.tmux.conf
tmux list-keys | grep overview.sh          # must print four lines (a/A/Enter + the C-a menu); if empty, see Troubleshooting
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
set -g @overview-menu-key 'C-a'     # filter/pick pop-up menu (default: C-a)
set -g @overview-interval '1'       # refresh interval in seconds, or 'auto' (default: 1)
```

The filter and pick controls live in a small pop-up menu (a tmux `display-menu`) opened with `prefix + C-a`, so they never overwrite your global prefix keys — tmux's built-in `find-window` (`f`) and `previous-window` (`p`) stay exactly where they are. In the menu, press `f` filter, `p` pick, `c` clear — or use the arrow keys / mouse; any other key (or Escape) closes it. A menu is a client overlay, so its keys are consumed by the menu and never leak into a mirror tile.

## Upgrading

Already installed? Pull the new version the same way you installed it.

- **TPM.** `prefix + U` (TPM's update) fetches the latest revision; `overview.tmux` re-registers the keybindings — including the `prefix + C-a` menu — on the next reload. Nothing else to do. If a dashboard is open, run `overview.sh kill` once (or `prefix + a` to leave and reopen) so the next open uses the new script.
- **Bundled installer.** Re-run `./install.sh` from an updated clone; it overwrites `overview.sh` in place. The installer also **re-prints the keybinding snippet** — compare it against your `~/.tmux.conf` and add anything new (e.g. the `bind-key C-a display-menu …` block if you're coming from a version without it), then `tmux source-file ~/.tmux.conf`.
- **Manual install.** Copy the new `overview.sh` over your old one (same path as before, e.g. `~/.local/bin/overview.sh`) and update the pasted keybinding block in `~/.tmux.conf` to match the current [Keybindings](#keybindings) snippet, then reload.

The bindings you paste into `~/.tmux.conf` are a **snapshot** — only TPM re-syncs them automatically, so manual/installer users should re-check the snippet after any release that changes keys (like the move to the `C-a` menu). See [CHANGELOG.md](./CHANGELOG.md) for what changed between versions.

## Keybindings

For manual installs, add this to `~/.tmux.conf` (adjust the path to where you put the script):

```tmux
# tmux-overview
bind-key a     run-shell "$HOME/.local/bin/overview.sh toggle"   # outside: open dashboard / inside: enter focused tile
bind-key A     run-shell "$HOME/.local/bin/overview.sh rebuild"  # force rebuild (rarely needed — grid self-updates)
bind-key Enter run-shell "$HOME/.local/bin/overview.sh zoom"     # inside dashboard: enter focused tile's session

# Filter/pick controls live in a small pop-up menu (a display-menu) so they never
# clobber your global prefix keys — find-window and previous-window stay intact.
# In the menu: f=filter, p=pick, c=clear, r=refresh (or use the arrow keys / mouse).
bind-key C-a display-menu -T "#[align=centre] overview " \
  "Filter (regex)…" f "command-prompt -p \"overview filter (ERE):\" \"run-shell \\\"$HOME/.local/bin/overview.sh filter '%%'\\\"\"" \
  "Pick sessions…"  p "run-shell \"$HOME/.local/bin/overview.sh pickmenu\"" \
  "Clear filter"    c "run-shell \"$HOME/.local/bin/overview.sh unfilter\"" \
  "Refresh interval…" r "run-shell \"$HOME/.local/bin/overview.sh intervalmenu\""
```

All keys are freely customizable — these are only suggestions. In particular, if you use `C-a` as your tmux prefix, `prefix + a` may clash with a habit or another binding; pick any key you like (`bind-key g ...` etc.). The `C-a` menu leader is likewise just a default — swap it for any free key if `C-a` is taken. The script itself never binds keys.

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
| `overview.sh build [pattern]` | (Re)create the dashboard. Optional `pattern` (POSIX ERE, i.e. `grep -E` syntax) filters session names (default: all). |
| `overview.sh toggle` | Outside the dashboard: open (building if needed). Inside: switch into the focused tile's session (or back to the previous session if the tile is dead). |
| `overview.sh rebuild` | Force a re-sync of the grid in place (no teardown, so an attached client is never dropped), or build it if absent. |
| `overview.sh zoom` | Inside the dashboard: switch into the focused tile's session. |
| `overview.sh reconcile` | Sync the grid with the live session list (normally fired by hooks). |
| `overview.sh kill` | Remove the dashboard session and unregister its hooks. |
| `overview.sh filter [regex]` | Validate `regex` (ERE), apply it in place, and remember it in `@overview_filter`. No arg: print the current filter. `filter ''` is equivalent to `unfilter`. Rejected (existing filter kept) on invalid syntax or on a pattern matching zero sessions. |
| `overview.sh unfilter` | Clear the filter (regex or pick, whichever is active) and show every session again. No dashboard: no-op. |
| `overview.sh pick [session]` | Toggle `session` in the checkbox pick set, recompiled into `@overview_filter` behind the scenes. No arg: print the current picks. |
| `overview.sh unpick` | Alias for `unfilter` (clears both pick and regex state). |
| `overview.sh pickmenu` | Open a `display-menu` checkbox UI over the live session list (bound to a key; see Keybindings). |
| `overview.sh mirror <session>` | Internal — the mirror loop that runs inside each tile. |

## Configuration

All configuration is via environment variables, read each time the script runs:

| Variable | Default | Description |
|---|---|---|
| `OVERVIEW_SESSION` | `overview` | Name of the dashboard session. |
| `OVERVIEW_WIDTH` | `188` | Width the dashboard session is created with (it is created detached; match your terminal size so the tile layout is computed correctly). |
| `OVERVIEW_HEIGHT` | `53` | Height the dashboard session is created with. |
| `OVERVIEW_IDLE_SEC` | `3` | Seconds without output before a tile flips RUN → IDLE. |
| `OVERVIEW_INTERVAL` | `1` | Default mirror refresh interval — seconds (fractional OK), or `auto`. Also settable with `set -g @overview-interval`, or live from the **Refresh interval** menu (see below). |
| `OVERVIEW_EXCLUDE_SELF` | *(unset)* | If set (to anything), the session you launch the dashboard **from** is left out of the grid. Applied at build time only — see Limitations. |

Since keybindings invoke the script through `run-shell`, set variables inline in the binding:

```tmux
bind-key a run-shell "OVERVIEW_WIDTH=220 OVERVIEW_HEIGHT=60 OVERVIEW_IDLE_SEC=5 $HOME/.local/bin/overview.sh toggle"
```

### Filtering

There are two ways to show only some sessions. They share one underlying filter and are mutually exclusive — switching to one clears the other. Both are stored in dashboard session options (`@overview_filter`, and `@overview_pick` for the pick set), so hook-driven reconciles keep honoring whichever is active, and the filter survives `rebuild`/`toggle`.

**Regex mode.** Type an ERE (POSIX Extended Regular Expression — same dialect as `grep -E`) and it's validated, applied in place, and remembered:

```sh
overview.sh filter '^agent-'   # only sessions whose names start with "agent-"
overview.sh filter             # print the current filter
overview.sh unfilter           # back to showing every session
```

`prefix + C-a` opens the control menu; choose **Filter** (`f`) to type a pattern (`command-prompt`), or **Clear filter** (`c`) to drop it. An invalid regex or one that matches zero sessions is rejected and the previous filter is kept — a typo can't blank the dashboard. `build [pattern]` still works exactly like this for scripting/bindings (same ERE syntax, same option):

```tmux
# a binding that always builds a filtered dashboard:
bind-key A run-shell "$HOME/.local/bin/overview.sh build '^agent-'"
```

> **Prompt caveat.** What you type at the **Filter** prompt is substituted into a shell command by tmux *before* the script sees it, so a pattern containing a literal `'`, `"`, or `#{…}`/`#(…)` may not reach the matcher intact (it's your own input, so this is a nuisance, not a security hole). Stick to plain ERE at the prompt, or use **Pick** for awkward names; `overview.sh filter '<regex>'` from the CLI has no such caveat.

**Pick mode.** When you'd rather check off sessions by name than write a regex, `prefix + C-a` then **Pick sessions** (`p`) opens a `display-menu` checkbox over the live session list — each item toggles that session and reopens the menu. Under the hood, the selected names are compiled into an anchored ERE alternation (`^(name1|name2)$`) and applied through the same `@overview_filter` path as regex mode, so both share one code path with no special-casing in the hook-driven reconcile logic.

```sh
overview.sh pickmenu            # open the checkbox menu (needs an attached client)
overview.sh pick 'agent-a'      # toggle one session from the CLI (works headless too)
overview.sh pick                # print the current picks
overview.sh unpick              # clear the pick set (alias for unfilter)
```

A session killed while picked drops out of the grid immediately (like regex mode) — unless it was the *only* remaining tile, which stays as a **DEAD** tile, because a tmux window must keep at least one pane. Its name stays in `@overview_pick` — if a same-named session reappears, it's automatically picked again. Session names containing metacharacters (`( ) [ ] . * + ? ^ $ | \`) are escaped automatically, so `pick` always matches by exact name regardless of regex syntax.

### Refresh interval

Each tile re-renders on a timer (default **1 s**). Change it live from `prefix + C-a` → **Refresh interval** (`r`): pick a preset (0.25 / 0.5 / 1 / 2 s), **auto**, or **custom…**. The current value is marked, and changes apply within one frame — no rebuild.

- **Fixed** — a number of seconds. Sub-second values (0.25, 0.5) feel snappier when you have only a few sessions; they need a `sleep` that accepts fractional seconds (macOS and GNU coreutils do — a strict-POSIX `sleep` degrades to 1 s).
- **`auto`** — scales with the number of tiles: ~0.25 s for one or two sessions, rising to 1 s at four or more. Fast when there's little to watch, calm when the grid is full.

Set the default a freshly-built dashboard starts with in `~/.tmux.conf`:

```tmux
set -g @overview-interval '0.5'    # or 'auto', or any number of seconds
```

Or drive it directly: `overview.sh interval 0.5` / `overview.sh interval auto` / `overview.sh interval` (print the current value). Menu and CLI changes are runtime; a full rebuild (`prefix + A`) re-reads `@overview-interval`.

## How it works

- **Mirroring.** Each tile runs `overview.sh mirror <session>`: a loop that captures the target session's active pane with `tmux capture-pane -ep` (`-e` preserves ANSI colors/attributes), takes the bottom `rows` lines (the status label lives on the border, so the whole pane body is content), hard-truncates each to the tile width with an ANSI- and width-aware `awk` pass (SGR color sequences are copied uncounted, UTF-8 glyphs count by display width — wide CJK/emoji as two columns via an approximate `wcwidth`, combining/zero-width marks not special-cased — and a reset is appended on cut), and repaints the tile using cursor-home + per-line erase escapes (`ESC[H`, `ESC[K`, `ESC[J`) — no full clears, so no flicker. Capturing is a pure read: the target session is never attached, resized, or sent input.
- **State detection.** The mirror loop compares `#{window_activity}` (last output, epoch seconds) against now — within `OVERVIEW_IDLE_SEC` → RUN, beyond it → IDLE with the idle duration — and writes the result into pane-local options (`@ov_state`, `@ov_idle`, `@ov_cmd`) only when it changes. The tile's top border, set via `pane-border-format`, renders those into a colored RUN/IDLE/DEAD label beside the session name and `#{pane_current_command}`; because tmux redraws the border itself, the color updates with state without the per-second in-pane repaint that used to flicker. If the target session vanishes, the border turns red **DEAD** and the pane shows a `session ended` banner until reconcile removes it.
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
tmux list-keys | grep overview.sh     # should print four lines
```

- **Prints nothing** → the bindings aren't loaded — you either skipped the `bind-key` lines, didn't reload, or put them in a file tmux doesn't read. Ask tmux exactly which files it loaded and make sure your bindings are in one of them:

  ```sh
  tmux display -p '#{config_files}'   # the config file(s) tmux actually loaded
  # add the bind-key lines to one of those, then:
  tmux source-file "<that file>"
  ```

  To confirm the tool itself works in the meantime, bind live (no file needed): `tmux bind-key a run-shell "$HOME/.local/bin/overview.sh toggle"`.

- **Prints the four lines but the key still does nothing** → you're pressing the wrong prefix, or `a` is shadowed. Check your prefix (default `C-b`) and press *that*, then `a`:

  ```sh
  tmux show -g prefix
  ```

  If your prefix is `C-a`, the `a` key may clash — bind a different one (e.g. `bind-key g ...`).

**Tiles are blank or show the wrong thing** → a tile mirrors only the *active pane of the active window* of each session; make sure that's where your agent is. On tmux < 3.0 (no pane-scoped user options) the grid can misbehave — check `tmux -V`.

## Uninstall

```sh
# 1. Stop the dashboard and remove its global hooks:
~/.local/bin/overview.sh kill

# 2. Delete the tmux-overview bind-key lines from your tmux config, then reload.
#    (the three prefix keys plus the C-a menu binding)
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
