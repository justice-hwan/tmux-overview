#!/bin/sh
# overview.sh — read-only live tiled dashboard for all tmux sessions
# Verified on: tmux 3.6, macOS, /bin/sh (POSIX)
#
# usage:
#   overview.sh build [pattern]    # (re)create the dashboard session
#                                  #   pattern: grep pattern for session names (default: all)
#   overview.sh toggle             # outside dashboard: open it / inside: enter focused tile
#   overview.sh rebuild            # force rebuild, then switch to the dashboard
#   overview.sh zoom               # (keybinding inside dashboard) enter focused tile's session
#   overview.sh reconcile          # sync grid with live session list (fired by hooks)
#   overview.sh kill               # remove the dashboard session and its hooks
#   overview.sh mirror <sess>      # internal: mirror loop running inside one tile
#
# Tile state: RUN (green) if the target produced output within the last
# OVERVIEW_IDLE_SEC seconds, otherwise IDLE Ns (yellow). AI agents keep the
# screen updating (spinners/streaming) while working, so RUN = busy and
# IDLE = waiting for input (or done) is a reliable heuristic.

DASH="${OVERVIEW_SESSION:-overview}"
DASH_W="${OVERVIEW_WIDTH:-188}"
DASH_H="${OVERVIEW_HEIGHT:-53}"
IDLE_SEC="${OVERVIEW_IDLE_SEC:-3}"
INTERVAL="${OVERVIEW_INTERVAL:-1}"
# Resolve to an absolute path so hook / keybinding sub-invocations always work.
SELF_PATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
[ -f "$SELF_PATH" ] || SELF_PATH="$0"

mirror() {
  t="$1"
  esc=$(printf '\033')
  while :; do
    rows=$(tmux display -p '#{pane_height}' 2>/dev/null) || exit 0
    a=$(tmux display -p -t "$t:" '#{window_activity}' 2>/dev/null)
    if [ -z "$a" ]; then
      printf '%s[H%s[41;37m %s: session ended %s[0m%s[J' "$esc" "$esc" "$t" "$esc" "$esc"
      sleep 2
      continue
    fi
    now=$(date +%s)
    idle=$((now - a))
    if [ "$idle" -le "$IDLE_SEC" ]; then
      state="RUN"
      col='42;30'   # green background = output flowing (agent busy)
    else
      state="IDLE ${idle}s"
      col='43;30'   # yellow background = no recent output (waiting for input / done)
    fi
    hdr=$(tmux display -p -t "$t:" '#{session_name} [#{pane_current_command}]' 2>/dev/null)
    body=$(tmux capture-pane -ep -t "$t:" 2>/dev/null | tail -n $((rows - 1)))
    printf '%s[H' "$esc"
    printf '%s[%sm %s  %s %s[0m%s[K\n' "$esc" "$col" "$hdr" "$state" "$esc" "$esc"
    printf '%s\n' "$body" | sed -e "s/\$/${esc}[K/"
    printf '%s[J' "$esc"
    sleep "$INTERVAL"
  done
}

HOOK_IDX=99   # global hook slot for auto-refresh (high index avoids clobbering other hooks)

set_hooks() {
  tmux set-hook -g "session-created[$HOOK_IDX]" "run-shell \"$SELF_PATH reconcile\""
  tmux set-hook -g "session-closed[$HOOK_IDX]"  "run-shell \"$SELF_PATH reconcile\""
}
unset_hooks() {
  tmux set-hook -gu "session-created[$HOOK_IDX]" 2>/dev/null
  tmux set-hook -gu "session-closed[$HOOK_IDX]"  2>/dev/null
}

# Add one mirror tile for session $1 into the grid. Returns 1 if the grid is too full.
add_tile() {
  _p=$(tmux split-window -d -P -F '#{pane_id}' -t "$DASH:0" "sh '$SELF_PATH' mirror '$1'" 2>/dev/null) || return 1
  tmux set -p -t "$_p" @mirror_target "$1"
  tmux select-pane -t "$_p" -T "$1"
}

# Make the grid match the live session list: add new sessions, drop closed ones.
# Fired by session-created / session-closed hooks; self-removes hooks if the dashboard is gone.
reconcile() {
  tmux has-session -t "$DASH" 2>/dev/null || { unset_hooks; return 0; }
  filter=$(tmux show -t "$DASH" -v @overview_filter 2>/dev/null); [ -z "$filter" ] && filter='.'
  desired=$(tmux list-sessions -F '#{session_name}' | grep -v "^${DASH}\$" | grep -e "$filter")
  [ -z "$desired" ] && return 0   # nothing to show; keep existing tile(s) instead of self-destructing
  shown=$(tmux list-panes -t "$DASH:0" -F '#{@mirror_target}')
  for s in $desired; do
    printf '%s\n' "$shown" | grep -qx "$s" || add_tile "$s"
  done
  tmux list-panes -t "$DASH:0" -F '#{pane_id} #{@mirror_target}' | while IFS=' ' read -r pid tgt; do
    [ -n "$tgt" ] && { printf '%s\n' "$desired" | grep -qx "$tgt" || tmux kill-pane -t "$pid" 2>/dev/null; }
  done
  tmux select-layout -t "$DASH:0" tiled 2>/dev/null
}

build() {
  unset_hooks                                # avoid reconcile races while (re)building
  tmux kill-session -t "$DASH" 2>/dev/null   # idempotent: allow rebuild when dashboard already exists
  filter="${1:-.}"
  targets=$(tmux list-sessions -F '#{session_name}' | grep -v "^${DASH}\$" | grep -e "$filter")
  # By default show ALL sessions in the grid (monitoring use case: see everything at once).
  # Set OVERVIEW_EXCLUDE_SELF=1 to hide the session the dashboard was launched from.
  if [ -n "$OVERVIEW_EXCLUDE_SELF" ]; then
    self=$(tmux display -p '#{session_name}' 2>/dev/null)
    [ -n "$self" ] && targets=$(printf '%s\n' "$targets" | grep -v "^${self}\$")
  fi
  [ -z "$targets" ] && { echo "no target sessions"; exit 1; }

  tmux kill-session -t "$DASH" 2>/dev/null

  first=1
  for t in $targets; do
    cmd="sh '$SELF_PATH' mirror '$t'"
    if [ "$first" = 1 ]; then
      tmux new-session -d -s "$DASH" -x "$DASH_W" -y "$DASH_H" "$cmd"
      p=$(tmux display -p -t "$DASH:0" '#{pane_id}')
      first=0
    else
      # Take the new pane id directly via -P -F: the tiled re-layout shuffles
      # pane indexes, so `list-panes | tail -1` would mis-tag tiles.
      p=$(tmux split-window -d -P -F '#{pane_id}' -t "$DASH:0" "$cmd") || {
        echo "warn: pane too small, skipping remaining sessions" >&2; break; }
      tmux select-layout -t "$DASH:0" tiled
    fi
    tmux set -p -t "$p" @mirror_target "$t"
    tmux select-pane -t "$p" -T "$t"
  done
  tmux set -w -t "$DASH:0" pane-border-status top
  tmux set -w -t "$DASH:0" pane-border-format ' #{pane_title} '
  tmux set -t "$DASH" status-style 'bg=colour24,fg=white'
  tmux set -t "$DASH" @overview_filter "$filter"   # remembered so hook-driven reconcile respects the same filter
  set_hooks                                    # auto-refresh grid on any session create/close
  echo "dashboard '$DASH' ready ($(printf '%s\n' "$targets" | wc -l | tr -d ' ') tiles), auto-refresh on"
}

zoom() {
  # run-shell context of a keybinding: switch the client to the focused tile's @mirror_target
  target=$(tmux display -p '#{@mirror_target}')
  [ -n "$target" ] && tmux switch-client -t "$target"
}

toggle() {
  # prefix+a: outside the dashboard -> open it; inside -> dive into the focused tile's session.
  if [ "$(tmux display -p '#{session_name}' 2>/dev/null)" = "$DASH" ]; then
    target=$(tmux display -p '#{@mirror_target}' 2>/dev/null)
    if [ -n "$target" ] && tmux has-session -t "$target" 2>/dev/null; then
      tmux switch-client -t "$target"   # enter the session under the currently focused tile
    else
      tmux switch-client -l             # focused pane isn't a live tile: just leave to previous session
    fi
  else
    tmux has-session -t "$DASH" 2>/dev/null || build
    tmux switch-client -t "$DASH"
  fi
}

case "$1" in
  mirror)    mirror "$2" ;;
  zoom)      zoom ;;
  toggle)    toggle ;;
  rebuild)   build "$2"; tmux switch-client -t "$DASH" ;;
  reconcile) reconcile ;;
  kill)      unset_hooks; tmux kill-session -t "$DASH" 2>/dev/null ;;
  build|"")  build "$2" ;;
  *) echo "usage: $0 [build [pattern]|toggle|rebuild|zoom|reconcile|kill|mirror <session>]"; exit 2 ;;
esac
