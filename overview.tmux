#!/usr/bin/env bash
# overview.tmux — TPM entry point for tmux-overview.
#
# Registers the default keybindings, resolving overview.sh relative to this
# plugin's directory. Customize the keys in ~/.tmux.conf:
#
#   set -g @overview-key 'a'            # toggle dashboard (default: a)
#   set -g @overview-rebuild-key 'A'    # force rebuild    (default: A)
#   set -g @overview-enter-key 'Enter'  # zoom into tile   (default: Enter)

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

  # TPM clones without preserving the executable bit reliably; make sure of it.
  chmod +x "$CURRENT_DIR/overview.sh" 2>/dev/null || true

  tmux bind-key "$toggle_key"  run-shell "$CURRENT_DIR/overview.sh toggle"
  tmux bind-key "$rebuild_key" run-shell "$CURRENT_DIR/overview.sh rebuild"
  tmux bind-key "$enter_key"   run-shell "$CURRENT_DIR/overview.sh zoom"
}

main
