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
cat <<EOF
# tmux-overview
bind-key a     run-shell "$DEST_DIR/overview.sh toggle"   # outside: open dashboard / inside: enter focused tile
bind-key A     run-shell "$DEST_DIR/overview.sh rebuild"  # force rebuild (rarely needed - grid self-updates)
bind-key Enter run-shell "$DEST_DIR/overview.sh zoom"     # inside dashboard: enter focused tile's session
EOF

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *) echo
     echo "note: $DEST_DIR is not on your PATH (only needed if you want to run overview.sh by name)" ;;
esac
