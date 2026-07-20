#!/bin/sh
# overview.sh — read-only live tiled dashboard for all tmux sessions
# Verified on: tmux 3.6, macOS, /bin/sh (POSIX). Requires tmux >= 3.2 (the
# newest feature used, display-menu, is 3.0+; 3.2 is the tested floor).
#
# usage:
#   overview.sh build [pattern]    # (re)create the dashboard session
#                                  #   pattern: ERE (grep -E) for session names (default: all)
#   overview.sh toggle             # outside dashboard: open it / inside: enter focused tile
#   overview.sh rebuild            # force a full re-sync of the grid
#   overview.sh zoom               # (keybinding inside dashboard) enter focused tile's session
#   overview.sh reconcile          # sync grid with live session list (fired by hooks)
#   overview.sh kill               # remove the dashboard session and its hooks
#   overview.sh filter [regex]     # set/apply-in-place the live ERE filter (no arg: show current)
#   overview.sh unfilter           # clear the filter (regex or pick) and show every session
#   overview.sh pick [session]     # toggle a session in the checkbox pick set (no arg: show picks)
#   overview.sh unpick             # alias for unfilter
#   overview.sh pickmenu           # open a display-menu checkbox UI over live sessions
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

# --- quoting helpers -------------------------------------------------------
# Session names come from `list-sessions` and are user/branch-controlled: they
# may hold spaces, quotes, '#', '$', etc. Each gets interpolated into a command
# string that passes one or two parser layers before /bin/sh runs it, so an
# unescaped name like `it's` breaks every tile spawn (and, crafted, could inject
# commands). These helpers make interpolation safe.

# sq <s> : echo $s as a single-quoted, /bin/sh-safe token ('' -> '\'').
# Enough wherever the value reaches sh through exactly ONE layer -- e.g. the
# command operand of split-window / new-session, which tmux runs verbatim via
# `sh -c` and does NOT format-expand (verified).
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# rsq <s> : like sq(), but also safe to embed inside a tmux `run-shell "..."`
# argument, which tmux runs through its command lexer AND format expansion before
# handing the result to sh. tmux un-escapes in the order lexer(\, ") -> format(#)
# -> then sh word-splits ('), so we escape sh-quote first, then \, ", #, $. Note
# '$' IS expanded by tmux here (unlike the split-window operand), so neutralise
# it too. Verified end-to-end against tmux for ' " # $ space and #(...)/$(...).
rsq() {
  printf '%s' "$(sq "$1")" \
    | sed 's/\\/\\\\/g' \
    | sed 's/"/\\"/g' \
    | sed 's/#/##/g' \
    | sed 's/\$/\\$/g'
}

# fmt_lit <s> : double '#' so a tmux format parser (display-message, run-shell,
# pane-border-format) treats the text as a literal instead of running
# #{...}/#(...)/#h. Used for user-supplied text echoed back to the status line.
fmt_lit() { printf '%s' "$1" | sed 's/#/##/g'; }
# ---------------------------------------------------------------------------

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
  printf 'OVERVIEW_SESSION=%s OVERVIEW_IDLE_SEC=%s OVERVIEW_INTERVAL=%s sh %s mirror %s' \
    "$(sq "$DASH")" "$IDLE_SEC" "$INTERVAL" "$(sq "$SELF_PATH")" "$(sq "$1")"
}

# Hard-truncate each stdin line to $1 visible columns, ANSI- and width-aware:
# SGR/escape sequences are copied without counting, UTF-8 glyphs count by display
# width (East Asian Wide/Fullwidth and common emoji = 2 columns, via approximate
# wcwidth below; everything else = 1), and a reset is appended when a line is cut.
# Keeps a wide source TUI or a CJK-heavy pane from wrapping into a broken mess
# inside a narrower tile. Also appends clear-to-EOL per line.
clip_to_width() {
  LC_ALL=C awk -v wmax="$1" '
    # wide(cp): 1 if the codepoint occupies 2 terminal columns. Decimal literals
    # only -- POSIX awk (incl. macOS nawk) does not parse 0x.. hex constants, so
    # hex ranges would silently all read as 0 and every glyph would count as 1.
    function wide(cp) {
      return (cp>=4352  && cp<=4447)  ||                         # Hangul Jamo
             (cp>=11904 && cp<=12350) || (cp>=12353 && cp<=13311) ||
             (cp>=13312 && cp<=19903) || (cp>=19968 && cp<=40959) ||  # CJK
             (cp>=40960 && cp<=42191) || (cp>=44032 && cp<=55203) ||  # Hangul
             (cp>=63744 && cp<=64255) || (cp>=65072 && cp<=65103) ||
             (cp>=65280 && cp<=65376) || (cp>=65504 && cp<=65510) ||  # Fullwidth
             (cp>=127744 && cp<=129791) || (cp>=131072 && cp<=262141) # emoji, CJK ext
    }
    BEGIN { esc=sprintf("%c",27); for (k=0;k<256;k++) ord[sprintf("%c",k)]=k }
    { n=length($0); i=1; vis=0; out=""; trunc=0
      while (i<=n) {
        c=substr($0,i,1); b=ord[c]
        if (c==esc) {                       # copy a full escape sequence, uncounted
          seq=c; i++
          if (substr($0,i,1)=="[") { seq=seq"["; i++
            while (i<=n) { ch=substr($0,i,1); seq=seq ch; i++; if (ch ~ /[@-~]/) break } }
          out=out seq; continue
        }
        if (b<128) { L=1 } else if (b<224) { L=2 } else if (b<240) { L=3 } else { L=4 }
        cp = (L==1) ? b : (b<224 ? b%32 : (b<240 ? b%16 : b%8))
        for (j=1;j<L;j++) cp = cp*64 + (ord[substr($0,i+j,1)]%64)
        w = (L>=3 && wide(cp)) ? 2 : 1      # only 3+ byte seqs reach wide ranges
        if (vis+w > wmax) { trunc=1; break }
        out=out substr($0,i,L); vis+=w; i+=L
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
    # Self-heal: if a stray mouse action (or a leftover mode from a previous occupant
    # of this pane) stranded this tile in copy-mode, tmux would pause the live repaint
    # below and the tile would eat f/p/c as copy-mode motions. Kick it back to normal
    # every tick so the mirror stays live and never hijacks the overview control keys.
    case "$(tmux display -p -t "$me" '#{pane_in_mode}' 2>/dev/null)" in
      1) tmux copy-mode -q -t "$me" 2>/dev/null ;;
    esac
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
      tmux set -p -t "$me" @ov_cmd   "$(fmt_lit "$cmd")" 2>/dev/null   # shown in border format
      last="$sig"
    fi
    # Capture into a var first: command substitution strips trailing blank rows,
    # so `tail -n rows` keeps the CONTENT rows even when the source pane is taller
    # than this tile. (A fresh session has its prompt at the top; piping capture
    # straight into tail would keep only the bottom blank rows -> an empty tile.)
    body=$(tmux capture-pane -ep -t "=$t:" 2>/dev/null)
    printf '%s[H' "$esc"
    printf '%s\n' "$body" | tail -n "$rows" | clip_to_width "$cols"
    printf '%s[J' "$esc"
    sleep "$(mirror_interval)" 2>/dev/null || sleep 1   # live interval; degrade to 1s if `sleep` lacks fractional support
  done
}

# mirror_interval : the sleep this tile should use right now. Reads the live
# @overview_interval session option (set by build / the refresh menu / the CLI),
# so a change takes effect within one frame -- no rebuild. "auto" scales with the
# current tile count: 0.25 s per tile, clamped to [0.25, 1] s (snappy when few
# sessions, ~1 s when many). Falls back to the baked $INTERVAL if unset.
mirror_interval() {
  iv=$(tmux show -t "$DASH" -v @overview_interval 2>/dev/null)
  [ -n "$iv" ] || iv="$INTERVAL"
  if [ "$iv" = auto ]; then
    n=$(tmux list-panes -t "=$DASH:" -F x 2>/dev/null | grep -c .)
    [ "$n" -ge 1 ] 2>/dev/null || n=1
    iv=$(awk -v n="$n" 'BEGIN{ v=0.25*n; if(v<0.25)v=0.25; if(v>1)v=1; printf "%g", v }')
  fi
  printf '%s' "$iv"
}

HOOK_IDX=99   # global hook slot for auto-refresh (high index avoids clobbering other hooks)

set_hooks() {
  # Bake OVERVIEW_SESSION into the hook so reconcile targets the right dashboard
  # (hooks run in the server env and would otherwise fall back to the default name).
  _h="run-shell \"OVERVIEW_SESSION=$(rsq "$DASH") sh $(rsq "$SELF_PATH") reconcile\""
  tmux set-hook -g "session-created[$HOOK_IDX]" "$_h"
  tmux set-hook -g "session-closed[$HOOK_IDX]"  "$_h"
}
unset_hooks() {
  tmux set-hook -gu "session-created[$HOOK_IDX]" 2>/dev/null
  tmux set-hook -gu "session-closed[$HOOK_IDX]"  2>/dev/null
}

# Move any client currently viewing the dashboard onto another session, so a
# following kill-session (default detach-on-destroy) doesn't drop the user out
# of tmux. No-op if the dashboard, or any alternate session, is absent.
detach_clients_from_dash() {
  tmux has-session -t "=$DASH" 2>/dev/null || return 0
  alt=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vFx "$DASH" | head -n1)
  [ -n "$alt" ] || return 0
  tmux list-clients -t "$DASH" -F '#{client_name}' 2>/dev/null | while IFS= read -r c; do
    [ -n "$c" ] && tmux switch-client -c "$c" -t "$alt" 2>/dev/null
  done
}

# Add one mirror tile for session $2 into window $1. Returns 1 if the split fails.
add_tile() {
  _p=$(tmux split-window -d -P -F '#{pane_id}' -t "$1" "$(tile_cmd "$2")" 2>/dev/null) || return 1
  tmux set -p -t "$_p" @mirror_target "$2"      # RAW (matching key); never rendered as a format
  tmux set -p -t "$_p" @ov_state RUN            # seed so the border shows RUN, not "IDLE s", before the first mirror tick
  tmux select-pane -t "$_p" -T "$(fmt_lit "$2")"  # title IS rendered (#{pane_title} in the border) -> escape '#'
}

# Sessions to mirror: everything except the dashboard, matching the optional
# filter. The matcher is `grep -E` (POSIX Extended RE) -- changed from plain grep
# (Basic RE) when filter/pick landed. The common subset (^ $ . [ ] * and
# literals) is unchanged; only BRE's backslashed metacharacters (\| \( \{) shift
# meaning. See docs/DESIGN.md §4.6 and CHANGELOG.md. valid_regex()/filter_cmd()
# below build on this.
targets_for() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vFx "$DASH" | grep -E -e "${1:-.}"
}

# valid_regex <pattern> : true if $1 is a syntactically valid ERE. Probed
# against an empty line so it's only ever a syntax check: grep's exit status
# is 0 (matched) or 1 (no match) for any valid pattern, and >1 for a syntax
# error, regardless of whether the empty line happens to match.
valid_regex() {
  printf '\n' | grep -E -e "$1" >/dev/null 2>&1
  [ $? -le 1 ]
}

# msg <text...> : surface a short message on the status line when running
# inside tmux (e.g. from a keybinding's run-shell) and always on stderr too.
msg() {
  tmux display-message "overview: $(fmt_lit "$*")" 2>/dev/null
  echo "overview: $*" >&2
}

# show_filter : print the currently active regex-mode filter.
show_filter() {
  tmux has-session -t "=$DASH" 2>/dev/null || { echo "no dashboard"; exit 1; }
  f=$(tmux show -t "$DASH" -v @overview_filter 2>/dev/null)
  case "$f" in
    ''|.) echo "overview: filter (none - showing all)" ;;
    *)    echo "overview: filter '$f'" ;;
  esac
}

# filter_cmd <pattern> : validate an ERE, store it in @overview_filter, and
# reconcile in place. '' is normalized to '.' (= show everything / unfilter).
# Rejects (leaving the existing filter untouched) on invalid ERE syntax or on
# a pattern that currently matches zero sessions, so a typo can't blank the
# dashboard (see docs/DESIGN.md). Entering regex mode always discards any
# active pick selection (the two modes are mutually exclusive).
filter_cmd() {
  pat="${1:-.}"
  valid_regex "$pat" || { msg "invalid regex: $1"; exit 1; }
  if ! tmux has-session -t "=$DASH" 2>/dev/null; then
    build "$pat"; return
  fi
  # Reject a filter that matches nothing so a typo can't blank the dashboard --
  # but never for the clear/unfilter case (pat='.'), which must succeed even when
  # the dashboard is the only session left.
  if [ "$pat" != '.' ] && [ -z "$(targets_for "$pat")" ]; then
    msg "no sessions match '$1' (filter unchanged)"; exit 1
  fi
  tmux set -t "$DASH" @overview_pick ''        # regex mode wins: discard any pick selection
  tmux set -t "$DASH" @overview_filter "$pat"
  set_hooks
  reconcile
  tmux has-session -t "=$DASH" 2>/dev/null || build "$pat"   # extreme-case safety net
  if [ "$pat" = '.' ]; then msg "filter cleared"; else msg "filter: $pat"; fi
}

# unfilter : clear the filter (regex or pick, whichever is active) and show
# every session again. No-op (not an error) when there is no dashboard yet.
unfilter() {
  tmux has-session -t "=$DASH" 2>/dev/null || { msg "no dashboard"; return 0; }
  filter_cmd '.'
}

# ere_escape <name> : make a session name safe to use as a literal inside an
# ERE alternation (escape ERE metacharacters). LC_ALL=C keeps sed byte-safe
# regardless of locale, so this also works for multibyte session names.
ere_escape() {
  printf '%s' "$1" | LC_ALL=C sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

# compile_pick : stdin = newline-separated session names, stdout = an
# anchored ERE alternation matching exactly that set, e.g. ^(a|b|c)$. Empty
# (or all-blank) input yields empty output — callers treat that as "no
# selection", which is equivalent to unfilter (see apply_pick()).
compile_pick() {
  alt=''
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    e=$(ere_escape "$nm")
    alt="${alt:+$alt|}$e"
  done
  [ -n "$alt" ] && printf '^(%s)$' "$alt"
}

# apply_pick <names> : $1 = newline-separated session names (may be empty).
# Persists the raw set to @overview_pick, compiles it into @overview_filter,
# and reconciles. An empty set falls back to unfilter (§ pick edge cases).
apply_pick() {
  tmux set -t "$DASH" @overview_pick "$1"
  re=$(printf '%s\n' "$1" | compile_pick)
  if [ -z "$re" ]; then
    unfilter
    return
  fi
  tmux set -t "$DASH" @overview_filter "$re"
  set_hooks
  reconcile
  tmux has-session -t "=$DASH" 2>/dev/null || build "$re"
}

# pick_toggle <session> : toggle exact-name membership in the pick set, then
# recompile+reconcile. If the dashboard doesn't exist yet, build one showing
# just that session and seed the pick set so later toggles/pickmenu agree.
pick_toggle() {
  if ! tmux has-session -t "=$DASH" 2>/dev/null; then
    e=$(ere_escape "$1")
    build "^($e)\$"
    tmux has-session -t "=$DASH" 2>/dev/null && tmux set -t "$DASH" @overview_pick "$1"
    return
  fi
  picks=$(tmux show -t "$DASH" -v @overview_pick 2>/dev/null)
  if printf '%s\n' "$picks" | grep -qFx "$1"; then
    picks=$(printf '%s\n' "$picks" | grep -vFx "$1")
  else
    picks=$(printf '%s\n' "$picks"; printf '%s\n' "$1")
  fi
  picks=$(printf '%s\n' "$picks" | grep -v '^$')
  apply_pick "$picks"
  # Picking a not-yet-existing name is allowed (it re-picks when the session
  # reappears), so don't reject -- but warn when the current selection matches
  # no live session, so a CLI typo isn't a silent empty grid.
  [ -n "$picks" ] && [ -z "$(targets_for "$(printf '%s\n' "$picks" | compile_pick)")" ] &&
    msg "picks match no live session"
}

# show_picks : print the current pick selection (one name per line), or
# "(none)" when nothing is picked.
show_picks() {
  tmux has-session -t "=$DASH" 2>/dev/null || { echo "no dashboard"; exit 1; }
  p=$(tmux show -t "$DASH" -v @overview_pick 2>/dev/null)
  p=$(printf '%s\n' "$p" | grep -v '^$')
  if [ -z "$p" ]; then
    echo "overview: pick (none)"
  else
    echo "overview: pick"
    printf '%s\n' "$p" | while IFS= read -r nm; do echo "  $nm"; done
  fi
}

# pickmenu : open a display-menu checkbox UI over the live session list; each
# item toggles that session's pick membership then reopens the menu (a fresh
# invocation, since display-menu has no built-in checkbox/reopen primitive).
# Args are accumulated with `set --` inside a `while ... done <<EOF` loop —
# NOT a `| while` pipe — so the loop body runs in the *current* shell rather
# than a subshell and the accumulation survives past the loop (same trick
# build() already relies on above).
# For automated testing (display-menu needs a real attached client, so it
# can't be driven headlessly): set OVERVIEW_PICKMENU_DRYRUN=1 to print the
# assembled `display-menu` arguments one per line instead of opening the menu.
pickmenu() {
  tmux has-session -t "=$DASH" 2>/dev/null || { msg "no dashboard"; exit 1; }
  picks=$(tmux show -t "$DASH" -v @overview_pick 2>/dev/null)
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -vFx "$DASH")
  set -- -T '#[align=centre] overview: pick '
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    mark='  '
    printf '%s\n' "$picks" | grep -qFx "$s" && mark='✓ '
    cmd="run-shell \"OVERVIEW_SESSION=$(rsq "$DASH") sh $(rsq "$SELF_PATH") pick $(rsq "$s")\" ; run-shell \"OVERVIEW_SESSION=$(rsq "$DASH") sh $(rsq "$SELF_PATH") pickmenu\""
    set -- "$@" "$mark$(fmt_lit "$s")" '' "$cmd"
  done <<EOF
$sessions
EOF
  set -- "$@" '' 'clear all (unpick)' '' "run-shell \"OVERVIEW_SESSION=$(rsq "$DASH") sh $(rsq "$SELF_PATH") unpick\""
  if [ -n "${OVERVIEW_PICKMENU_DRYRUN:-}" ]; then
    for a in "$@"; do printf '%s\n' "$a"; done
    return 0
  fi
  tmux display-menu "$@"
}

# Make the grid match the live session list: add new sessions, drop closed ones.
# Fired by session-created / session-closed hooks; self-removes hooks if the dashboard is gone.
reconcile() {
  tmux has-session -t "=$DASH" 2>/dev/null || { unset_hooks; return 0; }
  win=$(dash_win); [ -n "$win" ] || return 0
  filter=$(tmux show -t "$DASH" -v @overview_filter 2>/dev/null); [ -z "$filter" ] && filter='.'
  desired=$(targets_for "$filter")
  [ -z "$desired" ] && return 0   # nothing to show; keep existing tile(s) instead of self-destructing
  # Existing tiles' target names, read RAW via `show -v` -- never as a #{@opt}
  # format. Some tmux versions re-expand a user-option value referenced with
  # #{@mirror_target}, which would run #(...) embedded in a session name. Reading
  # per pane also preserves a trailing space that a -F read + word-split drops.
  shown=$(tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | while IFS= read -r pid; do
    tmux show -p -t "$pid" -v @mirror_target 2>/dev/null
  done)
  # add tiles for sessions not shown yet (line-based: allows spaces in names)
  printf '%s\n' "$desired" | while IFS= read -r s; do
    [ -n "$s" ] || continue
    printf '%s\n' "$shown" | grep -qFx "$s" || add_tile "$win" "$s" ||
      echo "overview: reconcile could not add tile for '$s'" >&2
  done
  # drop tiles whose target session no longer exists (raw per-pane read, same reason)
  tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null | while IFS= read -r pid; do
    tgt=$(tmux show -p -t "$pid" -v @mirror_target 2>/dev/null)
    [ -n "$tgt" ] || continue
    printf '%s\n' "$desired" | grep -qFx "$tgt" || tmux kill-pane -t "$pid" 2>/dev/null
  done
  tmux select-layout -t "$win" tiled 2>/dev/null
}

build() {
  filter="${1:-.}"
  valid_regex "$filter" || { msg "invalid regex: $1"; exit 1; }
  targets=$(targets_for "$filter")
  # By default show ALL sessions in the grid (monitoring use case: see everything at once).
  # Set OVERVIEW_EXCLUDE_SELF=1 to hide the session the dashboard was launched from.
  if [ -n "$OVERVIEW_EXCLUDE_SELF" ]; then
    self=$(tmux display -p '#{session_name}' 2>/dev/null)
    [ -n "$self" ] && targets=$(printf '%s\n' "$targets" | grep -vFx "$self")
  fi
  [ -z "$targets" ] && { echo "no target sessions" >&2; exit 1; }

  # Validation passed -- only now is it safe to touch hooks or tear down the old
  # grid. unset_hooks MUST stay below the guards above: a rejected rebuild (bad
  # regex / zero matches) exiting earlier must not strip auto-refresh from a live
  # dashboard. detach_clients_from_dash keeps an attached client inside tmux when
  # the following kill-session (detach-on-destroy) replaces the grid in place.
  unset_hooks
  detach_clients_from_dash
  tmux kill-session -t "=$DASH" 2>/dev/null

  win=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ -z "$win" ]; then
      win=$(tmux new-session -d -s "$DASH" -x "$DASH_W" -y "$DASH_H" -P -F '#{window_id}' "$(tile_cmd "$t")")
      p=$(tmux list-panes -t "$win" -F '#{pane_id}' | head -n1)
      tmux set -p -t "$p" @mirror_target "$t"
      tmux set -p -t "$p" @ov_state RUN
      tmux select-pane -t "$p" -T "$(fmt_lit "$t")"
    else
      add_tile "$win" "$t" || echo "overview: could not add tile for '$t'" >&2
      tmux select-layout -t "$win" tiled
    fi
  done <<EOF
$targets
EOF
  [ -n "$win" ] || { echo "overview: could not create dashboard session '$DASH'" >&2; exit 1; }

  tmux set -w -t "$win" pane-border-status top
  tmux set -w -t "$win" pane-border-format "$BORDER_FMT"
  tmux set -t "$DASH" status-style 'bg=colour24,fg=white'
  # The dashboard is a read-only mirror grid. Force mouse OFF for THIS session only
  # (global mouse stays as the user set it): otherwise a stray trackpad scroll/click
  # over a tile drops that pane into copy-mode, which freezes its ~1s refresh AND makes
  # the tile swallow the f/p/c control keys as copy-mode motions instead of letting the
  # overview control menu handle them. Session-scoped, so every other session is unaffected.
  tmux set -t "$DASH" mouse off
  tmux set -t "$DASH" @overview_filter "$filter"   # remembered so hook-driven reconcile respects the same filter
  tmux set -t "$DASH" @overview_pick ''             # (re)building is regex mode: discard any pick selection
  tmux set -t "$DASH" @overview_interval "$(interval_default)"  # live refresh interval; the menu/CLI change it without a rebuild
  set_hooks                                         # auto-refresh grid on any session create/close
  reconcile                                         # pick up any session created during the brief hooks-off window
  n=$(tmux list-panes -t "$win" -F x 2>/dev/null | grep -c .)
  echo "dashboard '$DASH' ready ($n tiles), auto-refresh on"
}

# Switch the current client into the session under the focused tile.
enter_tile() {
  target=$(tmux show -p -v @mirror_target 2>/dev/null)   # raw read: never format-expand a name
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

# --- refresh interval ------------------------------------------------------
# The mirror re-reads @overview_interval every tick (see mirror_interval), so
# these change the refresh rate live. Value: a number of seconds (fractional
# where `sleep` supports it) or "auto" (scale with the tile count).

# valid_interval <v> : true if v is "auto" or a positive number (int or decimal).
valid_interval() {
  [ "$1" = auto ] && return 0
  case "$1" in ''|*[!0-9.]*) return 1 ;; esac
  awk -v v="$1" 'BEGIN{ exit !(v ~ /^([0-9]+|[0-9]*\.[0-9]+|[0-9]+\.)$/ && v+0>0) }'
}

# interval_default : seed value for a fresh dashboard -- the @overview-interval
# tmux option, else $OVERVIEW_INTERVAL, else 1 (invalid config falls back to 1).
interval_default() {
  d=$(tmux show -gqv @overview-interval 2>/dev/null)
  [ -n "$d" ] || d="${OVERVIEW_INTERVAL:-1}"
  valid_interval "$d" || d=1
  printf '%s' "$d"
}

# set_interval <v> : validate and apply live (persist in @overview_interval); the
# mirror picks it up on its next tick, so no rebuild is needed.
set_interval() {
  tmux has-session -t "=$DASH" 2>/dev/null || { msg "no dashboard"; return 0; }
  valid_interval "$1" || { msg "invalid interval '$1' (seconds, or 'auto')"; exit 1; }
  tmux set -t "$DASH" @overview_interval "$1"
  case "$1" in auto) msg "refresh: auto" ;; *) msg "refresh: ${1}s" ;; esac
}

# show_interval : print the current interval.
show_interval() {
  iv=$(tmux show -t "$DASH" -v @overview_interval 2>/dev/null)
  [ -n "$iv" ] || iv=$(interval_default)
  case "$iv" in auto) echo "overview: refresh auto" ;; *) echo "overview: refresh ${iv}s" ;; esac
}

# _interval_item <value> : the run-shell command string a refresh-menu item runs.
_interval_item() {
  printf 'run-shell "OVERVIEW_SESSION=%s sh %s interval %s"' "$(rsq "$DASH")" "$(rsq "$SELF_PATH")" "$1"
}

# intervalmenu : the "refresh" preset submenu (opened from the C-a menu). Each
# item sets the interval live; the current value is marked with a bullet.
# OVERVIEW_PICKMENU_DRYRUN prints the assembled args instead of opening the menu.
intervalmenu() {
  tmux has-session -t "=$DASH" 2>/dev/null || { msg "no dashboard"; exit 1; }
  cur=$(tmux show -t "$DASH" -v @overview_interval 2>/dev/null)
  [ -n "$cur" ] || cur=$(interval_default)
  m1='  '; [ "$cur" = 0.25 ] && m1='• '
  m2='  '; [ "$cur" = 0.5 ]  && m2='• '
  m3='  '; [ "$cur" = 1 ]    && m3='• '
  m4='  '; [ "$cur" = 2 ]    && m4='• '
  ma='  '; [ "$cur" = auto ] && ma='• '
  cust="command-prompt -p \"refresh (s or auto):\" \"run-shell \\\"OVERVIEW_SESSION=$(rsq "$DASH") sh $(rsq "$SELF_PATH") interval '%%'\\\"\""
  set -- -T '#[align=centre] overview: refresh ' \
    "${m1}0.25s" 1 "$(_interval_item 0.25)" \
    "${m2}0.5s"  2 "$(_interval_item 0.5)" \
    "${m3}1s"    3 "$(_interval_item 1)" \
    "${m4}2s"    4 "$(_interval_item 2)" \
    "${ma}auto"  a "$(_interval_item auto)" \
    '' 'custom…' c "$cust"
  if [ -n "${OVERVIEW_PICKMENU_DRYRUN:-}" ]; then
    for a in "$@"; do printf '%s\n' "$a"; done
    return 0
  fi
  tmux display-menu "$@"
}
# ---------------------------------------------------------------------------

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
  kill)      unset_hooks; detach_clients_from_dash; tmux kill-session -t "=$DASH" 2>/dev/null ;;
  filter)
    if [ $# -ge 2 ]; then filter_cmd "$2"; else show_filter; fi
    ;;
  unfilter)  unfilter ;;
  pick)
    if [ $# -ge 2 ]; then pick_toggle "$2"; else show_picks; fi
    ;;
  unpick)    unfilter ;;
  pickmenu)  pickmenu ;;
  interval)     if [ $# -ge 2 ]; then set_interval "$2"; else show_interval; fi ;;
  intervalmenu) intervalmenu ;;
  build|"")  build "$2" ;;
  *) echo "usage: $0 [build [pattern]|toggle|rebuild|zoom|reconcile|kill|filter [regex]|unfilter|pick [session]|unpick|pickmenu|interval [s|auto]|intervalmenu|mirror <session>]"; exit 2 ;;
esac
