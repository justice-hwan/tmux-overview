#!/bin/sh
# overview.sh — read-only live tiled dashboard for all tmux sessions
# Verified on: tmux 3.6, macOS, /bin/sh (POSIX). Requires tmux 3.0+.
#
# usage:
#   overview.sh build [pattern]    # (re)create the dashboard session
#                                  #   pattern: grep pattern for session names (default: all)
#   overview.sh toggle             # outside dashboard: open it / inside: enter focused tile
#   overview.sh rebuild            # force a full re-sync of the grid
#   overview.sh zoom               # (keybinding inside dashboard) enter focused tile's session
#   overview.sh reconcile          # sync grid with live session list (fired by hooks)
#   overview.sh kill               # remove the dashboard session and its hooks
#   overview.sh mirror <sess>      # internal: mirror loop running inside one tile
#
# Env: OVERVIEW_SESSION (name, default "overview"), OVERVIEW_WIDTH/HEIGHT,
#      OVERVIEW_IDLE_SEC (RUN->IDLE threshold, default 3), OVERVIEW_INTERVAL
#      (refresh seconds, default 1), OVERVIEW_EXCLUDE_SELF=1 (hide launcher session).
#
# Tile state is shown on each tile's top border (drawn by tmux, so it never
# flickers): RUN (green) if the target produced output within the last
# OVERVIEW_IDLE_SEC seconds, otherwise IDLE Ns (yellow); DEAD (red) if the
# target session is gone. AI agents keep the screen updating (spinners/
# streaming) while working, so RUN = busy and IDLE = waiting for input (or
# done) is a reliable heuristic.

DASH="${OVERVIEW_SESSION:-overview}"
DASH_W="${OVERVIEW_WIDTH:-188}"
DASH_H="${OVERVIEW_HEIGHT:-53}"
IDLE_SEC="${OVERVIEW_IDLE_SEC:-3}"
INTERVAL="${OVERVIEW_INTERVAL:-1}"
# Resolve to an absolute path so hook / keybinding sub-invocations always work.
SELF_PATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
[ -f "$SELF_PATH" ] || SELF_PATH="$0"

# Per-tile status shown on the pane's top border. tmux redraws the border
# itself, so the colour never flickers the way a per-second in-pane repaint did.
# The mirror loop writes these pane-local user options only when they change:
#   @ov_state  RUN | IDLE | DEAD      @ov_idle  idle seconds      @ov_cmd  [command]
# Colours are written as separate #[..] blocks on purpose: a comma inside a
# #{?..} conditional is parsed as a branch separator, so #[fg=x,bg=y] would break it.
BORDER_FMT='#{?#{==:#{@ov_state},RUN},#[fg=black]#[bg=green] RUN ,#{?#{==:#{@ov_state},DEAD},#[fg=white]#[bg=red] DEAD ,#[fg=black]#[bg=yellow] IDLE #{@ov_idle}s }}#[default] #{pane_title} #{@ov_cmd}'

# tmux target for the dashboard's single window (by id, so base-index doesn't matter).
dash_win() { tmux list-windows -t "=$DASH" -F '#{window_id}' 2>/dev/null | head -n1; }

# The command a tile runs: env is baked in because tiles spawn in the tmux
# server's environment, not the caller's.
tile_cmd() {
  printf "OVERVIEW_IDLE_SEC=%s OVERVIEW_INTERVAL=%s sh '%s' mirror '%s'" \
    "$IDLE_SEC" "$INTERVAL" "$SELF_PATH" "$1"
}

# Hard-truncate each stdin line to $1 visible columns, ANSI-aware: SGR color
# sequences are copied without counting, UTF-8 multibyte glyphs count as one, and
# a reset is appended when a line is cut. Keeps a wide source TUI from wrapping
# into a broken mess inside a narrower tile. Also appends clear-to-EOL per line.
clip_to_width() {
  LC_ALL=C awk -v w="$1" '
    BEGIN { esc=sprintf("%c",27); for (k=0;k<256;k++) ord[sprintf("%c",k)]=k }
    { n=length($0); i=1; vis=0; out=""; trunc=0
      while (i<=n) {
        c=substr($0,i,1)
        if (c==esc) {                       # copy a full escape sequence, uncounted
          seq=c; i++
          if (substr($0,i,1)=="[") { seq=seq"["; i++
            while (i<=n) { ch=substr($0,i,1); seq=seq ch; i++; if (ch ~ /[@-~]/) break } }
          out=out seq; continue
        }
        b=ord[c]
        if (b>=128 && b<192) { out=out c; i++; continue }   # UTF-8 continuation byte
        if (vis>=w) { trunc=1; break }
        out=out c; vis++; i++
      }
      if (trunc) out=out esc"[0m"
      print out esc"[K"
    }'
}

mirror() {
  t="$1"
  esc=$(printf '\033')
  # Self-reference MUST use $TMUX_PANE: `tmux display -p` without -t resolves to
  # the window's ACTIVE pane, not the pane this loop is running in.
  me="$TMUX_PANE"
  [ -n "$me" ] || me=$(tmux display -p '#{pane_id}' 2>/dev/null)
  last=""
  while :; do
    rows=$(tmux display -p -t "$me" '#{pane_height}' 2>/dev/null) || exit 0
    cols=$(tmux display -p -t "$me" '#{pane_width}' 2>/dev/null)
    a=$(tmux display -p -t "=$t:" '#{window_activity}' 2>/dev/null)
    if [ -z "$a" ]; then
      # target session is gone: red DEAD on the border + an in-pane banner
      [ "$last" = DEAD ] || { tmux set -p -t "$me" @ov_state DEAD 2>/dev/null; last=DEAD; }
      printf '%s[H%s[41;37m %s: session ended %s[0m%s[J' "$esc" "$esc" "$t" "$esc" "$esc"
      sleep 2
      continue
    fi
    now=$(date +%s)
    idle=$((now - a))
    if [ "$idle" -le "$IDLE_SEC" ]; then st="RUN"; id=""; else st="IDLE"; id="$idle"; fi
    cmd=$(tmux display -p -t "=$t:" '#{pane_current_command}' 2>/dev/null)
    [ -n "$cmd" ] && cmd="[$cmd]"
    sig="$st/$id/$cmd"
    if [ "$sig" != "$last" ]; then
      # Update border state only on change; the write itself makes tmux repaint
      # the border, so there is no per-second in-pane redraw to flicker.
      tmux set -p -t "$me" @ov_state "$st" 2>/dev/null
      tmux set -p -t "$me" @ov_idle  "$id"  2>/dev/null
      tmux set -p -t "$me" @ov_cmd   "$cmd" 2>/dev/null
      last="$sig"
    fi
    printf '%s[H' "$esc"
    tmux capture-pane -ep -t "=$t:" 2>/dev/null | tail -n "$rows" | clip_to_width "$cols"
    printf '%s[J' "$esc"
    sleep "$INTERVAL"
  done
}

HOOK_IDX=99   # global hook slot for auto-refresh (high index avoids clobbering other hooks)

set_hooks() {
  # Bake OVERVIEW_SESSION into the hook so reconcile targets the right dashboard
  # (hooks run in the server env and would otherwise fall back to the default name).
  _h="run-shell \"OVERVIEW_SESSION='$DASH' $SELF_PATH reconcile\""
  tmux set-hook -g "session-created[$HOOK_IDX]" "$_h"
  tmux set-hook -g "session-closed[$HOOK_IDX]"  "$_h"
}
unset_hooks() {
  tmux set-hook -gu "session-created[$HOOK_IDX]" 2>/dev/null
  tmux set-hook -gu "session-closed[$HOOK_IDX]"  2>/dev/null
}

# Add one mirror tile for session $2 into window $1. Returns 1 if the split fails.
add_tile() {
  _p=$(tmux split-window -d -P -F '#{pane_id}' -t "$1" "$(tile_cmd "$2")" 2>/dev/null) || return 1
  tmux set -p -t "$_p" @mirror_target "$2"
  tmux set -p -t "$_p" @ov_state RUN            # seed so the border shows RUN, not "IDLE s", before the first mirror tick
  tmux select-pane -t "$_p" -T "$2"
}

# Sessions to mirror: everything except the dashboard, matching the optional filter.
targets_for() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vFx "$DASH" | grep -e "${1:-.}"
}

# Make the grid match the live session list: add new sessions, drop closed ones.
# Fired by session-created / session-closed hooks; self-removes hooks if the dashboard is gone.
reconcile() {
  tmux has-session -t "=$DASH" 2>/dev/null || { unset_hooks; return 0; }
  win=$(dash_win); [ -n "$win" ] || return 0
  filter=$(tmux show -t "$DASH" -v @overview_filter 2>/dev/null); [ -z "$filter" ] && filter='.'
  desired=$(targets_for "$filter")
  [ -z "$desired" ] && return 0   # nothing to show; keep existing tile(s) instead of self-destructing
  shown=$(tmux list-panes -t "$win" -F '#{@mirror_target}' 2>/dev/null)
  # add tiles for sessions not shown yet (line-based: allows spaces in names)
  printf '%s\n' "$desired" | while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf '%s\n' "$shown" | grep -qFx "$s" || add_tile "$win" "$s"
  done
  # drop tiles whose target session no longer exists
  tmux list-panes -t "$win" -F '#{pane_id} #{@mirror_target}' 2>/dev/null | while IFS=' ' read -r pid tgt; do
    [ -n "$tgt" ] || continue
    printf '%s\n' "$desired" | grep -qFx "$tgt" || tmux kill-pane -t "$pid" 2>/dev/null
  done
  tmux select-layout -t "$win" tiled 2>/dev/null
}

build() {
  unset_hooks                                # avoid reconcile races while (re)building
  filter="${1:-.}"
  targets=$(targets_for "$filter")
  # By default show ALL sessions in the grid (monitoring use case: see everything at once).
  # Set OVERVIEW_EXCLUDE_SELF=1 to hide the session the dashboard was launched from.
  if [ -n "$OVERVIEW_EXCLUDE_SELF" ]; then
    self=$(tmux display -p '#{session_name}' 2>/dev/null)
    [ -n "$self" ] && targets=$(printf '%s\n' "$targets" | grep -vFx "$self")
  fi
  [ -z "$targets" ] && { echo "no target sessions"; exit 1; }

  # If a client is already viewing an existing dashboard, move it to another
  # session first so kill-session (detach-on-destroy) doesn't kick it out of tmux.
  if tmux has-session -t "=$DASH" 2>/dev/null; then
    alt=$(tmux list-sessions -F '#{session_name}' | grep -vFx "$DASH" | head -n1)
    if [ -n "$alt" ]; then
      tmux list-clients -t "$DASH" -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
        [ -n "$c" ] && tmux switch-client -c "$c" -t "$alt" 2>/dev/null
      done
    fi
    tmux kill-session -t "=$DASH" 2>/dev/null
  fi

  win=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -z "$win" ]; then
      win=$(tmux new-session -d -s "$DASH" -x "$DASH_W" -y "$DASH_H" -P -F '#{window_id}' "$(tile_cmd "$t")")
      p=$(tmux list-panes -t "$win" -F '#{pane_id}' | head -n1)
      tmux set -p -t "$p" @mirror_target "$t"
      tmux set -p -t "$p" @ov_state RUN
      tmux select-pane -t "$p" -T "$t"
    else
      add_tile "$win" "$t" || echo "warn: could not add tile for '$t' (grid full?)" >&2
      tmux select-layout -t "$win" tiled
    fi
  done <<EOF
$targets
EOF
  [ -n "$win" ] || { echo "no target sessions"; exit 1; }

  tmux set -w -t "$win" pane-border-status top
  tmux set -w -t "$win" pane-border-format "$BORDER_FMT"
  tmux set -t "$DASH" status-style 'bg=colour24,fg=white'
  tmux set -t "$DASH" @overview_filter "$filter"   # remembered so hook-driven reconcile respects the same filter
  set_hooks                                         # auto-refresh grid on any session create/close
  reconcile                                         # pick up any session created during the brief hooks-off window
  n=$(tmux list-panes -t "$win" -F x 2>/dev/null | grep -c .)
  echo "dashboard '$DASH' ready ($n tiles), auto-refresh on"
}

# Switch the current client into the session under the focused tile.
enter_tile() {
  target=$(tmux display -p '#{@mirror_target}' 2>/dev/null)
  [ -n "$target" ] && tmux has-session -t "=$target" 2>/dev/null && tmux switch-client -t "$target"
}

toggle() {
  # prefix+a: outside the dashboard -> open it; inside -> dive into the focused tile's session.
  if [ "$(tmux display -p '#{session_name}' 2>/dev/null)" = "$DASH" ]; then
    enter_tile || tmux switch-client -l   # focused pane isn't a live tile: just leave to previous session
  else
    tmux has-session -t "=$DASH" 2>/dev/null || build
    tmux switch-client -t "$DASH"
  fi
}

case "$1" in
  mirror)    mirror "$2" ;;
  zoom)      enter_tile ;;
  toggle)    toggle ;;
  rebuild)
    # Refresh in place when the dashboard exists (no kill => never kicks an attached client).
    if tmux has-session -t "=$DASH" 2>/dev/null; then
      set_hooks; reconcile
    else
      build; tmux switch-client -t "$DASH"
    fi
    ;;
  reconcile) reconcile ;;
  kill)      unset_hooks; tmux kill-session -t "=$DASH" 2>/dev/null ;;
  build|"")  build "$2" ;;
  *) echo "usage: $0 [build [pattern]|toggle|rebuild|zoom|reconcile|kill|mirror <session>]"; exit 2 ;;
esac
