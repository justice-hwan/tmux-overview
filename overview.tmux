#!/usr/bin/env bash
# overview.tmux — TPM entry point for tmux-overview.
#
# Registers the default keybindings, resolving overview.sh relative to this
# plugin's directory. Customize the keys in ~/.tmux.conf:
#
#   set -g @overview-key 'a'            # toggle dashboard (default: a)
#   set -g @overview-rebuild-key 'A'    # force rebuild    (default: A)
#   set -g @overview-enter-key 'Enter'  # zoom into tile   (default: Enter)
#   set -g @overview-menu-key 'C-a'     # filter/pick pop-up menu (default: C-a)
#
# The filter/pick controls live in a small pop-up menu (tmux `display-menu`)
# opened with <prefix> <menu-key>, so they never clobber your global prefix
# keys — tmux's built-in find-window (f) and previous-window (p) stay intact.
# In the menu:
#
#   f  regex filter prompt  (empty pattern = clear/show all)
#   p  checkbox pick menu    (per-session ✓ toggles; includes "clear all")
#   c  clear filter/pick     (show every session)
#
# Or navigate with the arrow keys / mouse; any other key (or Escape) closes it.
# A menu is a client overlay: it consumes every key, so nothing leaks into a
# work tile — unlike a modal key-table, which is fragile under IMEs.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

get_tmux_option() {
  option="$1"
  default="$2"
  value="$(tmux show-option -gqv "$option")"
  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

main() {
  toggle_key="$(get_tmux_option '@overview-key' 'a')"
  rebuild_key="$(get_tmux_option '@overview-rebuild-key' 'A')"
  enter_key="$(get_tmux_option '@overview-enter-key' 'Enter')"
  menu_key="$(get_tmux_option '@overview-menu-key' 'C-a')"

  # TPM clones without preserving the executable bit reliably; make sure of it.
  chmod +x "$CURRENT_DIR/overview.sh" 2>/dev/null || true

  tmux bind-key "$toggle_key"  run-shell "$CURRENT_DIR/overview.sh toggle"
  tmux bind-key "$rebuild_key" run-shell "$CURRENT_DIR/overview.sh rebuild"
  tmux bind-key "$enter_key"   run-shell "$CURRENT_DIR/overview.sh zoom"

  # Filter/pick live in a small pop-up menu opened by the menu key
  # (<prefix> <menu-key>). This keeps tmux's built-in find-window (f) and
  # previous-window (p) intact — f/p/c are in-menu mnemonics, not global
  # bindings. A menu is a client overlay: it consumes every key, so nothing
  # leaks into a work tile (a modal key-table would, especially under an IME).
  tmux bind-key "$menu_key" display-menu -T "#[align=centre] overview " \
    "Filter (regex)…" f "command-prompt -p \"overview filter (ERE):\" \"run-shell \\\"$CURRENT_DIR/overview.sh filter '%%'\\\"\"" \
    "Pick sessions…"  p "run-shell \"$CURRENT_DIR/overview.sh pickmenu\"" \
    "Clear filter"    c "run-shell \"$CURRENT_DIR/overview.sh unfilter\""
}

main
