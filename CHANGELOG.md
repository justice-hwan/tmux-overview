# Changelog

Notable changes to **tmux-overview**. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims for
[Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-07-12

First tagged release: a read-only, self-updating tiled dashboard of every tmux
session — a live filter and a checkbox pick mode behind an IME-safe
`display-menu`, and per-tile RUN / IDLE / DEAD status on the pane border. Zero
dependencies beyond POSIX `sh` + tmux (verified on tmux 3.6/macOS and 3.4/Linux;
tested floor tmux ≥ 3.2).

### Features
- **Read-only mirror grid** of every session, self-updating via
  `session-created` / `session-closed` hooks, with one-key zoom into a tile.
- **Tile status on the pane border** (RUN / IDLE / DEAD), drawn by tmux itself,
  so it never flickers.
- **Filter & pick** — a live ERE filter (`filter` / `unfilter`) and a checkbox
  pick mode (`pick` / `pickmenu` / `unpick`) that compiles the selection into an
  anchored `^(a|b)$` alternation; both funnel through one `@overview_filter` →
  reconcile path.
- **`display-menu` controls** on `prefix + C-a` (`f`/`p`/`c` in-menu mnemonics),
  chosen over a modal `switch-client -T` key-table that leaked keystrokes into
  panes under an input method (IME).
- **Double-width (CJK / emoji) aware** tile truncation (approximate `wcwidth`),
  so Hangul/CJK-heavy panes truncate cleanly instead of wrapping.

### Robustness
- Session names and paths are shell-escaped everywhere they reach a command
  string (`sq` / `rsq`), so a name like `it's` can't break a tile spawn or
  inject commands.
- Fresh / short-content sessions no longer mirror as a blank tile.
- A rejected `build <pattern>` no longer strips auto-refresh hooks from a live
  dashboard; `unfilter` works when the dashboard is the only session left;
  `kill` keeps an attached client inside tmux.
- A `#` in a session name (e.g. `feature#123`) renders literally on the border;
  `@mirror_target` is read raw (`show -v`) so a name is never re-expanded.
- `pick <typo>` warns instead of silently emptying the grid; clearer failure
  messages throughout.

### Notes for existing users
- **`build`'s optional pattern is now POSIX Extended RE (`grep -E`)**, not Basic
  RE. The common subset (`^ $ . [ ] *` and literals) is unchanged; only BRE's
  backslash-metacharacters (`\|` `\(` `\{`) shift meaning, and unescaped
  alternation like `agent-(a|b)` now works. See **Upgrading** in the README for
  how to pull this release for TPM / installer / manual installs.

### Tooling
- `tests/smoke.sh` — a headless smoke test that drives the real script against a
  throwaway `tmux -L` server (adversarial names, filter validation, pick,
  injection, kill); never touches your default server.
- GitHub Actions CI running `shellcheck` + `sh -n` / `bash -n` + the smoke test
  on Linux / tmux 3.4. All scripts are `shellcheck`-clean.

[0.1.0]: https://github.com/justice-hwan/tmux-overview/releases/tag/v0.1.0
