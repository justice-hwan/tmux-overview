# Design Notes — tmux-overview

This document records the feasibility study behind tmux-overview's architecture: why it is a
*read-only mirror grid with zoom* rather than a "true" interactive live grid, and what was
actually measured to reach that conclusion.

> Verification environment: tmux **3.6** (Homebrew) on macOS, one attached client at **188×53**.
> Every claim marked *(measured)* was reproduced on a live tmux server with real test sessions.
> Anything not measured is flagged explicitly.

---

## 1. Problem

Running several AI coding agents, each in its own tmux session, turns monitoring into serial
polling: `prefix + )` / session pickers show one session at a time. The goal is a *simultaneous*
view — every session visible at once, with an at-a-glance signal for "agent busy" vs "agent
waiting for input", plus a fast path to jump in and intervene.

## 2. Three approaches evaluated

| Approach | Verdict | Evidence (measured) | Key traps |
|---|---|---|---|
| **(a) True interactive live grid** — one nested `tmux attach` per tile | **Partially possible — rejected** | A writable nested attach forces the *target* window down to the tile size *(measured: 200×50 → 80×19 with `window-size latest`)*, and the size does **not** restore after detach *(measured: stays 80×19)*. | ① The forced resize reflows and visually wrecks a running TUI (e.g. Claude Code) mid-task. ② `window-size manual` prevents the resize *(measured: 200×50 preserved)* but then the tile shows only a **top-left crop** — agent output lives at the *bottom* of the screen, so you see nothing useful. ③ Nested prefix collision (prefix must be sent twice to reach the inner tmux). ④ `link-window` only shares the window between sessions *(measured: `linked_sessions=2`)*; a client still renders a single window — no grid. ⑤ `join-pane` does produce a real interactive grid *(measured: works)* but moving a session's last pane **destroys the source session** *(measured)* — structurally destructive. |
| **(b) Read-only live mirror grid** — poll `capture-pane -ep` | **Feasible — verified** | `capture-pane -ep` preserves ANSI colors/attributes *(measured: raw `ESC[42m`-style escapes in the capture)*. Six tiles polling at 1 s: tmux server **0.7 % CPU, 5.6 MB RSS** *(measured)*. `#{window_activity}` (epoch) updates every second while a pane is streaming output *(measured: delta = 2 across a 2 s gap)* — the basis for RUN/IDLE. Zero impact on targets (pure reads). `tmux display -p` / `capture-pane` work fine from inside detached panes *(measured)*. | ① Latency up to the polling interval (default 1 s). ② Read-only — no typing into tiles. ③ If the target is wider than the tile, lines wrap *(measured: 120-col target in a 93-col tile)*. ④ No scrollback browsing inside a tile. |
| **(c) Hybrid** — (b) as the default view + `switch-client` zoom for intervention | **Feasible — chosen** | Everything from (b), plus: storing/reading a `@mirror_target` pane user option works *(measured)*, and `switch-client` swaps the *same* client (188×53) between sessions — the resize side effects of (a) are impossible by construction, because session sizes stay constant when a single client hops between them. | The zoom keybinding itself can only run from an attached client, so it was verified component-wise (option round-trip + `switch-client`) rather than end-to-end at study time. |

### 2.1 Side note: what about a *read-only* nested attach?

`tmux attach -r` does **not** resize the target *(measured: an 80×20 read-only client attached to a
120×30 session leaves it at 120×30)* — in tmux ≥ 3.2, `-r` implies the `ignore-size` flag. A
"poll-free true live mirror" sounds attractive, but `ignore-size` means a small tile shows only the
**top-left crop** of the target screen. Agent output — the part you care about — is at the bottom,
so the bottom-aligned `capture-pane | tail` mirror of (b) is strictly better for monitoring. The
conclusion stands.

## 3. Why the hybrid (c) wins

1. **Monitoring is fully covered by (b).** For "glance at what every agent is doing", a 1-second
   mirror is plenty, and a RUN/IDLE header carries more information than flipping through
   sessions one by one.
2. **Intervention is better served by zoom.** A TUI like Claude Code is unpleasant to drive inside
   a narrow tile even if it were interactive. You want full size to type anyway; `switch-client`
   is instantaneous and side-effect-free.
3. **Non-invasive.** Existing sessions, layouts, and hooks are untouched; the dashboard is just
   one more session plus two indexed global hooks.

## 4. Architecture

### 4.1 Dashboard session layout

```
session "overview"  (dedicated session; excluded from its own mirror targets)
└── window 0  (layout: tiled, pane-border-status top)
    ├── pane %a  ← mirror loop → session "proj-a"   [@mirror_target=proj-a, pane title=proj-a]
    ├── pane %b  ← mirror loop → session "proj-b"   [@mirror_target=proj-b]
    └── ...      (at 188×53: six tiles of roughly 93×17 each, measured)
```

The first row of every tile is a status header (background color encodes state); the rest mirrors
the bottom `rows − 1` lines of the target session's active pane.

### 4.2 Mirror loop

- **Capture**: `tmux capture-pane -ep -t '<session>:'` — the `<session>:` target form resolves to
  the active pane of the session's active window; `-e` keeps ANSI escapes, `-p` prints to stdout.
- **Rendering**: instead of `clear`, repaint with `ESC[H` (home) + `ESC[K` after each line (erase
  residue) + a final `ESC[J` — flicker-free. Capturing into a shell variable
  (`body=$(...)`) lets command substitution strip trailing blank lines, which makes the bottom
  alignment clean.
- **Bottom alignment**: `| tail -n $((rows − 1))` — agent activity is always at the bottom of the
  screen, so tail is the right crop.
- **Interval**: 1 s by default (`OVERVIEW_INTERVAL`). Measured headroom is large (six tiles at
  1 s ≈ 0.7 % CPU on the tmux server); adaptive polling (fast while RUN, slow while IDLE) is a
  possible refinement, not a need.

### 4.3 State detection

| Signal | Mechanism (measured) | Interpretation |
|---|---|---|
| Busy vs waiting | `#{window_activity}` epoch — updates every second while output streams | `now − activity ≤ OVERVIEW_IDLE_SEC` → **RUN** (spinner/streaming = agent working); otherwise **IDLE Ns** (output stopped = waiting for input, or done) |
| What is running | `#{pane_current_command}` | shown in the header (`node`, `claude`, `zsh`, ...) |
| Tile title | `select-pane -T` + `pane-border-status top` + `pane-border-format ' #{pane_title} '` | session name on the tile border |
| Session death | `tmux display -p -t <t>:` failing | red "session ended" banner |

The RUN/IDLE split is a deliberate heuristic: AI agents repaint the screen continuously while
working, so "output stopped for N seconds" is a strong proxy for "wants input". Its failure modes
(silent long thinking; "done" vs "waiting" both reading IDLE) are documented in the README. A
future refinement is grepping the last non-blank captured line for prompt patterns (`❯`,
`esc to interrupt`, ...) to split "done" from "waiting".

### 4.4 Grid assembly — a real bug worth recording

The `tiled` re-layout **shuffles pane indexes**, so grabbing "the newest pane" with
`list-panes | tail -1` mis-tags tiles *(this was hit and confirmed during development)*. The new
pane id must be taken directly from the split:

```sh
p=$(tmux split-window -d -P -F '#{pane_id}' -t "$DASH:0" "$cmd")
tmux select-layout -t "$DASH:0" tiled
tmux set -p -t "$p" @mirror_target "$t"   # zoom target, stored on the pane itself
tmux select-pane -t "$p" -T "$t"          # border title
```

### 4.5 Hook-driven reconciliation

`build` registers `session-created[99]` and `session-closed[99]` as *indexed* global hooks, so any
hooks the user already has at other indexes keep working. Both fire `overview.sh reconcile`, which:

1. exits (and unregisters the hooks — self-healing) if the dashboard session no longer exists;
2. reads the remembered filter from the `@overview_filter` session option;
3. diffs desired sessions against the tiles' `@mirror_target` pane options;
4. adds missing tiles, kills stale ones, and re-applies the `tiled` layout.

`build` also unregisters the hooks first and re-registers them last, to avoid reconcile racing a
rebuild in progress.

Known gap: `OVERVIEW_EXCLUDE_SELF` is evaluated only inside `build` (it needs to know which session
the user launched from — information a server-side hook doesn't have), so a hook-driven reconcile
can re-add the launcher session. Persistent exclusion should use the filter pattern instead.

## 5. Minimum tmux version — rationale

Feature-by-feature floor of everything the script uses:

| Feature used | Introduced in |
|---|---|
| `split-window -P -F '#{pane_id}'` | 1.7 |
| `capture-pane -e` (ANSI-preserving) | 1.8 |
| `show-options -v` (value-only) | 1.8 |
| `pane-border-status` / `pane-border-format` | 2.3 |
| `select-pane -T` (pane titles) | 2.6 |
| **Pane user options** (`set -p @mirror_target`, `#{@mirror_target}` in formats) | **3.0** |
| **Indexed/array hooks** (`set-hook -g 'session-created[99]'`, `-gu` with index) | **3.0** (hooks moved into the options tree as array options) |
| `attach -r` implying `ignore-size` (only referenced in §2.1, not required by the script) | 3.2 |

The hard theoretical floor is therefore **tmux 3.0**. However, the tool has only been exercised on
tmux 3.6, and 3.0/3.1 behavior around pane options in formats and indexed hook unset has not been
verified here — so the *supported* floor is conservatively declared as **tmux ≥ 3.2**. Reports of
success or failure on 3.0/3.1 are welcome.

## 6. Limitations and honest risks

1. **Read-only + up to 1 s latency.** No typing into tiles (by design), no scrollback browsing,
   no cursor/IME rendering. Intervene via zoom.
2. **Width mismatch wraps lines** *(measured: 120-col target → 93-col tile)*. Cropping long lines
   to the tile width while preserving ANSI state is impractical in shell; accept it, reduce tile
   count, or filter.
3. **Physical tile ceiling.** At 188×53 the practical range is 6–9 tiles; past that,
   `split-window` fails with "pane too small" (the script warns and skips the rest). Filter when
   you have many sessions.
4. **Active-pane-only capture.** Each tile shows the active pane of the session's *active* window;
   an agent in a background window is not what you'll see. Pinning a specific
   `session:window.pane` per tile is a possible extension.
5. **IDLE is a heuristic** — see §4.3.
6. **Polling load scales with tiles × frequency.** Currently negligible *(measured 0.7 % CPU)*,
   but the tmux server is a single process and it performs every capture; dozens of tiles at
   sub-second intervals would concentrate load there.
7. **The dashboard is a session** and appears in session lists/pickers.

## 7. Alternatives considered

| Tool | What it is | Relation to this need |
|---|---|---|
| **claude-squad** | TUI managing multiple terminal AI agents (Claude Code / Codex / Aider) via tmux sessions + git worktrees | Closest existing tool, but it is a **list + single preview** — not a simultaneous grid. Worth a look if you also want worktree automation. |
| **Claude Code agent teams** | Native orchestration of multiple Claude Code instances (tmux-based) | Solves orchestration, not "watch arbitrary sessions I started myself". |
| **`watch --color` one-liner** *(verified)* | Ad-hoc mirror pane for a single session, no script needed | `tmux split-window "watch --color -t -n 1 'tmux capture-pane -ep -t work: | tail -40'"` — fine for temporarily watching exactly one session. |

## Appendix: measurement log summary

- `tmux -V` → tmux 3.6
- Writable nested attach: target 200×50 → **shrunk to 80×19**; not restored after detach
- Read-only nested attach (`-r`): target **stays 120×30** (no resize; top-left crop in the small client)
- `window-size manual` + 80×20 nested client: target **stays 200×50** (tile shows a crop)
- `link-window`: `linked=1 linked_sessions=2` — still one rendered window per client; no grid
- `join-pane` across sessions: works, but moving the last pane **destroys the source session**
- `capture-pane -ep`: ANSI escapes preserved verbatim (`ESC[30m ESC[42m ...`)
- Six tiles, 1 s polling: tmux server **0.7 % CPU / 5.6 MB RSS**
- State detection: streaming session tagged `RUN`, sleeping session tagged `IDLE 79s` — 6/6 tiles
  correct, no mis-tagging
- `#{window_activity}` epoch advances every second during streaming (delta = 2 over a 2 s gap)
