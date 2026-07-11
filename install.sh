#!/bin/sh
# install.sh — copy overview.sh into a bin directory and print the tmux.conf snippet.
#
# usage: ./install.sh [destination-dir]
#   default destination: ${XDG_BIN_HOME:-$HOME/.local/bin}

set -eu

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
DEST_DIR="${1:-${XDG_BIN_HOME:-$HOME/.local/bin}}"

if [ ! -f "$SRC_DIR/overview.sh" ]; then
  echo "error: overview.sh not found next to install.sh ($SRC_DIR)" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"
cp "$SRC_DIR/overview.sh" "$DEST_DIR/overview.sh"
chmod +x "$DEST_DIR/overview.sh"

echo "installed: $DEST_DIR/overview.sh"
echo
echo "Add this to ~/.tmux.conf (keys are just suggestions - change freely),"
echo "then reload with: tmux source-file ~/.tmux.conf"
echo
# Quoted heredoc keeps the display-menu escaping byte-exact; sed fills in the path.
sed "s|__DEST__|$DEST_DIR|g" <<'EOF'
# tmux-overview
bind-key a     run-shell "__DEST__/overview.sh toggle"   # outside: open dashboard / inside: enter focused tile
bind-key A     run-shell "__DEST__/overview.sh rebuild"  # force rebuild (rarely needed - grid self-updates)
bind-key Enter run-shell "__DEST__/overview.sh zoom"     # inside dashboard: enter focused tile's session

# Filter/pick controls live in a small pop-up menu (a tmux display-menu) opened
# with <prefix> C-a, so they never clobber your global prefix keys (tmux's
# built-in find-window / previous-window stay intact). In the menu: f=filter,
# p=pick, c=clear - or navigate with the arrow keys / mouse.
bind-key C-a display-menu -T "#[align=centre] overview " \
  "Filter (regex)…" f "command-prompt -p \"overview filter (ERE):\" \"run-shell \\\"__DEST__/overview.sh filter '%%'\\\"\"" \
  "Pick sessions…"  p "run-shell \"__DEST__/overview.sh pickmenu\"" \
  "Clear filter"    c "run-shell \"__DEST__/overview.sh unfilter\""
EOF

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *) echo
     echo "note: $DEST_DIR is not on your PATH (only needed if you want to run overview.sh by name)" ;;
esac
