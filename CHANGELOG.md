# Changelog

Notable changes to **tmux-overview**. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/); the project isn't tagged with
release versions yet, so entries are grouped by change set, newest first.

## Unreleased

### Fixed
- **Session names with a single quote (e.g. `it's`) broke tile spawn, pick, and
  pickmenu** and spewed recurring `no such pane` errors on every hook-driven
  reconcile. All session names and paths are now shell-escaped wherever they are
  interpolated into a command string (`sq` for the one-layer split-window
  operand; `rsq` for two-layer `run-shell "…"` strings). A crafted name can no
  longer inject commands either.
- **Fresh or short-content sessions mirrored as a completely blank tile.** The
  mirror loop now captures into a variable before `tail`, so command
  substitution strips the source pane's trailing blank rows and the content rows
  survive even when the source pane is taller than the tile. (Regression from the
  pane-border status refactor.)
- **A rejected `build <pattern>`** (invalid regex or zero matches) no longer
  strips the auto-refresh hooks from a still-running dashboard — validation now
  runs before `unset_hooks`.
- **`unfilter` / the menu's *Clear filter*** now works when the dashboard is the
  only remaining session (the zero-match guard no longer applies to clearing).
- **Status-line output and pick-menu labels** no longer let `#{…}`/`#(…)` in a
  user filter or a session name run through tmux format expansion (`fmt_lit`).
- **`kill`** now moves any attached client off the dashboard first, so it doesn't
  drop you out of tmux (matching what `build` already did).
- A **`#` in a session name** (e.g. `feature#123`) now renders literally on the
  tile border instead of being interpreted as a tmux format directive. Display
  paths (pane title, `@ov_cmd`) escape `#`, and `@mirror_target` is read raw via
  `show -v` so a name is never re-expanded on read (some tmux versions re-expand
  a value referenced with `#{@opt}`).

### Added
- **Double-width (CJK / emoji) awareness in tile truncation.** East Asian
  Wide/Fullwidth glyphs and common emoji now count as two columns (approximate
  `wcwidth`), so Hangul/CJK-heavy panes truncate cleanly instead of wrapping.
- **`tests/smoke.sh`** — a headless smoke test that drives the real script
  against a throwaway `tmux -L` server (adversarial names, filter validation,
  pick, injection, kill). Never touches your default tmux server.
- All scripts are **`shellcheck`-clean** and syntax-checked (`sh -n` / `bash -n`).
  A GitHub Actions CI workflow (`.github/workflows/ci.yml`) runs shellcheck,
  syntax checks, and the smoke test on **Linux / tmux 3.4** — cross-version
  coverage that already caught a Linux-only behavior the macOS/3.6 run missed.
- An **Upgrading** section in the READMEs covering TPM / installer / manual.

### Changed
- **`pick <name>`** now warns when the current selection matches no live session
  (a CLI typo is no longer a silent empty grid); picking a not-yet-existing name
  is still allowed and re-picks when it reappears.
- Clearer diagnostics: tile-spawn and dashboard-creation failures no longer
  misreport as `(grid full?)` / `no target sessions`.
- The `overview.sh` header states the tested version floor (tmux ≥ 3.2)
  consistently with the README and `docs/DESIGN.md`.

## Filter & pick, via a display-menu

- Added a live ERE filter (`filter` / `unfilter`) and a checkbox pick mode
  (`pick` / `pickmenu` / `unpick`) that compiles the selected names into an
  anchored `^(a|b)$` alternation; both funnel through the same
  `@overview_filter` → reconcile path.
- **`build`'s optional pattern changed from POSIX Basic RE (`grep`) to Extended
  RE (`grep -E`).** The common subset (`^ $ . [ ] *` and literals) is unchanged;
  only BRE's backslashed metacharacters (`\|` `\(` `\{`) shift meaning, and
  unescaped alternation like `agent-(a|b)` now works. This is the one behavior
  change for existing `build '<pattern>'` users.
- Filter/pick controls live in a `prefix + C-a` `display-menu` pop-up (f/p/c as
  in-menu mnemonics), replacing an earlier modal `switch-client -T` key-table
  that leaked keystrokes into panes under an input method (IME).

## Tile status on the pane border

- Moved each tile's RUN / IDLE / DEAD status onto the pane border, drawn by tmux
  itself, to eliminate the per-second repaint flicker.

## Initial release

- Read-only mirror-grid dashboard of every tmux session, self-updating via
  `session-created` / `session-closed` hooks, with one-key zoom. Zero
  dependencies beyond POSIX `sh` + tmux.
