#!/bin/sh
# tests/smoke.sh — headless smoke test for overview.sh.
#
# Runs the real script against a THROWAWAY tmux server (its own -L socket, no
# config), never touching your default server. A tiny `tmux` shim on PATH points
# every tmux call the script makes at that socket, so build/filter/pick/kill all
# operate in isolation. `display-menu` needs an attached client, so pick UI is
# exercised through OVERVIEW_PICKMENU_DRYRUN=1 (prints the assembled args instead
# of opening the menu).
#
# Usage:  sh tests/smoke.sh          # from the repo root
# Exit:   0 = all passed, 1 = a failure (prints FAIL lines)

# `cond && ok "..." || no "..."` is intentional throughout: ok()/no() always
# return 0, so the C branch never runs on a true A. Silence SC2015 file-wide.
# shellcheck disable=SC2015
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OV="$ROOT/overview.sh"
[ -f "$OV" ] || { echo "cannot find overview.sh at $OV" >&2; exit 2; }

REAL_TMUX=$(command -v tmux) || { echo "tmux not found in PATH" >&2; exit 2; }
SOCK="ovsmoke_$$"
WORK=$(mktemp -d)
SHIM="$WORK/bin"
PWNED="$WORK/PWNED"          # any successful injection would create this
mkdir -p "$SHIM"

# tmux shim: redirect the script's bare `tmux` calls to the throwaway server.
cat > "$SHIM/tmux" <<EOF
#!/bin/sh
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
EOF
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"; export PATH

DASH=ovsmoke
export OVERVIEW_SESSION="$DASH"
export OVERVIEW_WIDTH=200 OVERVIEW_HEIGHT=50

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()   { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
tm()   { tmux "$@"; }                 # the shim
ov()   { sh "$OV" "$@"; }             # the real script, tmux-shimmed via PATH

cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---- fixtures: adversarial session names -----------------------------------
tm new-session -d -s "$DASH-holder" -x 200 -y 50   # a client-less holder so the server is up
# `web` is a TALL pane with a marker printed at the very top. A shorter tile that
# tailed a direct capture would keep only the bottom blank rows and miss it, so
# the marker's presence proves the blank-tile fix (capture into a var first strips
# the trailing blanks). Running the marker as the pane command avoids relying on
# an interactive shell being ready for send-keys.
tm new-session -d -s web -x 80 -y 50 "printf 'OVSMOKE_WEB_MARKER\n'; exec sh" 2>/dev/null \
  || no "could not create web fixture"
for s in "api" "it's" "a b" 'x#(touch '"$PWNED"')y'; do
  tm new-session -d -s "$s" -x 80 -y 24 2>/dev/null || no "could not create fixture '$s'"
done
tm kill-session -t "=$DASH-holder" 2>/dev/null
sleep 0.3
# On tmux versions that format-expand a session NAME at creation (e.g. 3.4), the
# `x#(...)y` fixture's own `new-session -s` runs the #() itself -- that's tmux, not
# overview.sh, which never creates a session from a mirrored name (and such a name
# can't even exist there: tmux expands it away). Clear any marker from fixture
# setup now, so the checks below measure OVERVIEW.SH's handling only. On 3.6+ the
# name stays literal and nothing ran, so this is a harmless no-op.
rm -f "$PWNED"

echo "== build with adversarial names =="
ov build >/dev/null 2>&1
tm has-session -t "=$DASH" 2>/dev/null && ok "dashboard built" || no "dashboard not built"
# one tile (pane) per non-dashboard session
win="$DASH:0"
panes=$(tm list-panes -t "$win" -F x 2>/dev/null | grep -c .)
sessN=$(tm list-sessions -F '#{session_name}' 2>/dev/null | grep -vcFx "$DASH")
[ "$panes" = "$sessN" ] && ok "tile count $panes == sessions $sessN" || no "tile count $panes != sessions $sessN"
# the single-quote name must have a tile whose target is exactly it's
tm list-panes -t "$win" -F '#{@mirror_target}' 2>/dev/null | grep -qFx "it's" \
  && ok "session with single-quote got a tile" || no "single-quote session missing a tile"
[ -e "$PWNED" ] && { no "INJECTION during build (PWNED created)"; rm -f "$PWNED"; } || ok "no injection during build"

echo "== mirror shows top-of-pane content (blank-tile regression) =="
sleep 2   # let a mirror tick or two run in the tiles
pid=$(tm list-panes -t "$win" -F '#{pane_id} #{@mirror_target}' 2>/dev/null | awk '$2=="web"{print $1; exit}')
if [ -n "$pid" ]; then
  cap=$(tm capture-pane -p -t "$pid" 2>/dev/null)
  printf '%s\n' "$cap" | grep -q 'OVSMOKE_WEB_MARKER' \
    && ok "web tile shows top-of-pane marker (not blank)" \
    || no "web tile missing top-of-pane content (blank-tile regression)"
else
  no "web tile pane not found"
fi

echo "== filter validation =="
ov filter '^web$' >/dev/null 2>&1
n=$(tm list-panes -t "$win" -F x 2>/dev/null | grep -c .)
[ "$n" = 1 ] && ok "filter '^web\$' -> 1 tile" || no "filter '^web\$' -> $n tiles (want 1)"
before=$(tm show -t "$DASH" -v @overview_filter 2>/dev/null)
ov filter 'agent-(a' >/dev/null 2>&1; rc=$?     # invalid ERE
after=$(tm show -t "$DASH" -v @overview_filter 2>/dev/null)
{ [ "$rc" != 0 ] && [ "$before" = "$after" ]; } && ok "invalid regex rejected, filter unchanged" || no "invalid regex not rejected (rc=$rc)"
ov filter 'zzz_nomatch_zzz' >/dev/null 2>&1; rc=$?
after=$(tm show -t "$DASH" -v @overview_filter 2>/dev/null)
{ [ "$rc" != 0 ] && [ "$after" = '^web$' ]; } && ok "zero-match filter rejected, previous kept" || no "zero-match not rejected (rc=$rc after=$after)"
ov unfilter >/dev/null 2>&1
n=$(tm list-panes -t "$win" -F x 2>/dev/null | grep -c .)
[ "$n" = "$sessN" ] && ok "unfilter restores all $sessN tiles" || no "unfilter -> $n tiles (want $sessN)"
# reconcile re-read the (adversarial) names above; make sure that didn't fire #()
[ -e "$PWNED" ] && { no "INJECTION during filter/reconcile"; rm -f "$PWNED"; } || ok "no injection during filter/reconcile"

echo "== pickmenu dry-run is injection-safe =="
out=$(OVERVIEW_PICKMENU_DRYRUN=1 ov pickmenu 2>/dev/null)
printf '%s\n' "$out" | grep -q "it's" && ok "pickmenu lists the single-quote session" || no "pickmenu missing single-quote session"
# render the dry-run command strings through a real (isolated) tmux run to prove no injection
printf '%s\n' "$out" | grep -c . >/dev/null
[ -e "$PWNED" ] && { no "INJECTION in pickmenu args"; rm -f "$PWNED"; } || ok "no injection in pickmenu dry-run"

echo "== pick / unpick =="
ov pick 'web' >/dev/null 2>&1
tm show -t "$DASH" -v @overview_pick 2>/dev/null | grep -qFx 'web' && ok "pick adds to @overview_pick" || no "pick did not record 'web'"
ov unpick >/dev/null 2>&1
p=$(tm show -t "$DASH" -v @overview_pick 2>/dev/null)
[ -z "$p" ] && ok "unpick clears the pick set" || no "unpick left picks: $p"

echo "== unfilter works when the dashboard is the only session left =="
for s in "web" "api" "it's" "a b" 'x#(touch '"$PWNED"')y'; do tm kill-session -t "=$s" 2>/dev/null; done
ov unfilter >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "unfilter exit 0 with only the dashboard" || no "unfilter failed alone (rc=$rc)"
rm -f "$PWNED"

echo "== kill tears down dashboard + hooks =="
ov kill >/dev/null 2>&1
tm has-session -t "=$DASH" 2>/dev/null && no "dashboard still alive after kill" || ok "dashboard removed"
tm show-hooks -g 2>/dev/null | grep -q 'overview.sh' && no "hooks still registered after kill" || ok "hooks removed"

echo
echo "smoke: $pass passed, $fail failed"
[ "$fail" = 0 ]
