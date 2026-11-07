#!/usr/bin/env bash
# The open picker follows the pane and its status without a keypress, keeps the
# cursor on the same pane when rows reorder, and leaves nothing running.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=./lib/tmux.sh
source "$ROOT/tests/lib/tmux.sh"
# shellcheck source=../core/agent-status-apply.sh
source "$ROOT/core/agent-status-apply.sh"

tmux set-option -g @agent_status_notify_system off
tmux set-option -g @agent_status_notify off
"$ROOT/tmux/agent-status.tmux"

fail() { echo "FAIL: $1"; screen; exit 1; }
outer=("$REAL_TMUX" -L "$SOCKET-outer")
screen() { "${outer[@]}" capture-pane -p; }
press() { "${outer[@]}" send-keys "$@"; nap 0.3; }
appears() { for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do screen | grep -q "$1" && return 0; nap 0.2; done; return 1; }

b="$(tmux new-window -d -P -F '#{pane_id}' -t main -n first)"
c="$(tmux new-window -d -P -F '#{pane_id}' -t main -n second)"
agent_status_apply_to_tmux "$b" working "" ""
tmux set-option -p -t "$b" @agent_status_updated_at 1000
agent_status_apply_to_tmux "$c" working "" ""
tmux set-option -p -t "$c" @agent_status_updated_at 2000

# Logs every poke the refresher sends to fzf.
real_curl="$(command -v curl)"
cat > "$TMP/bin/curl" <<FAKE
#!/bin/sh
echo poke >> "$TMP/pokes"
exec "$real_curl" "\$@"
FAKE
chmod +x "$TMP/bin/curl"
pokes() { wc -l < "$TMP/pokes" 2>/dev/null | tr -d ' ' || echo 0; }

press C-b j
appears 'agent panes>' || fail "popup did not open"
screen | grep -q '+T' && fail "tracking indicator on screen"
: > "$TMP/pokes"
nap 3.5
[ "$(pokes)" = 0 ] || fail "idle picker still redraws: $(pokes) pokes in 3.5s"
# Rows sort newest first, so the cursor starts on "second".
tmux send-keys -t "$c" 'echo LIVE-OUTPUT-MARK' Enter
appears 'LIVE-OUTPUT-MARK' || fail "preview did not follow the pane"

agent_status_apply_to_tmux "$b" waiting "" "" "permission: Bash"
appears 'permission: Bash' || fail "row did not pick up the new status"
# "first" would now sort above "second"; rows hold still, so Enter lands on "second".
press Enter
nap 0.5
[ "$(tmux display-message -p '#{window_name}')" = second ] || fail "cursor moved off its pane when rows reordered"

# Only this test's pickers: the user's own popup may be open on the real server.
leftovers() { ps -axo pid=,etime=,args= | grep "[f]zf.sock" | grep "$TMP" || true; }
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(leftovers)" ] && break
    echo "t+$i: $(leftovers | cut -c1-170)"
    nap 0.5
done
[ -z "$(leftovers)" ] || fail "refresher left running"

# Keys must work during a reload. A slow ps stretches the reload to 1s, and each key
# goes in right after the refresher pokes fzf, so a blocking reload can't hide.
real_ps="$(command -v ps)"
cat > "$TMP/bin/ps" <<FAKE
#!/bin/sh
case " \$* " in *args=*) sleep 1 ;; esac
exec "$real_ps" "\$@"
FAKE
chmod +x "$TMP/bin/ps"
reloading() { # text for the row that changes
    local before
    before="$(pokes)"
    agent_status_apply_to_tmux "$b" working "" "" "$1"
    for _ in $(seq 40); do [ "$(pokes)" != "$before" ] && return 0; nap 0.05; done
    fail "refresher never poked fzf"
}

press C-b j
appears 'agent panes>' || fail "popup did not reopen"
nap 1.2
reloading "move test"
"${outer[@]}" send-keys C-k
nap 0.15
"${outer[@]}" send-keys Enter
nap 0.4
screen | grep -q 'agent panes>' && fail "keys were swallowed during a reload"
[ "$(tmux display-message -p '#{pane_id}')" != "$c" ] || fail "ctrl-k during a reload did not move the cursor"

press C-b j
appears 'agent panes>' || fail "popup did not reopen"
nap 1.2
press Tab
screen | grep -q '(1)' || fail "tab did not select a row"
reloading "selection test"
appears 'selection test' || fail "row did not update"
screen | grep -q '(1)' || fail "a reload dropped the multi-selection"
press Escape

press C-b j
appears 'agent panes>' || fail "popup did not reopen"
nap 1.2
reloading "exit test"
"${outer[@]}" send-keys C-q
nap 0.3
screen | grep -q 'agent panes>' && fail "ctrl-q was swallowed during a reload"
rm -f "$TMP/bin/ps"

# ctrl-s switches views in the open picker; closing it goes back to the default.
heading='→ main '
press C-b j
appears 'agent panes>' || fail "popup did not reopen"
screen | grep -q "$heading" && fail "session headings before switching"
press C-s
appears "$heading" || fail "ctrl-s did not switch to the session view"
press C-s
for _ in 1 2 3 4 5 6 7 8 9 10; do screen | grep -q "$heading" || break; nap 0.2; done
screen | grep -q "$heading" && fail "ctrl-s did not switch back"
press C-s
appears "$heading" || fail "ctrl-s did not switch again"
press Escape
press C-b j
appears 'agent panes>' || fail "popup did not reopen"
screen | grep -q "$heading" && fail "closing the picker should reset the view"
press Escape

# Grouped: the cursor and 1-9 reach panes only, in both directions, and the
# highlight stays off headings. Rows: aaa heading, a, main heading, then two panes.
tmux new-session -d -s aaa
a_pane="$(tmux display-message -p -t aaa '#{pane_id}')"
agent_status_apply_to_tmux "$a_pane" working "" ""
tmux set-option -g @agent_status_view session
current() { tmux display-message -p '#{pane_id}'; }
back_home() { tmux switch-client -t main; tmux select-window -t main:0; nap 0.2; }
open() { press C-b j; appears "$heading" || fail "grouped popup did not open"; nap 0.3; }
pick() { press Enter; nap 0.5; current; back_home; }
second_row="$b"; third_row="$c"
# Same status in main; which sorts first depends on age, so read it from the list.
echo session > "$TMP/view"
first_main="$("$ROOT/core/agent-picker.sh" --list main "" "$TMP/view" | awk -F'\t' '$2 ~ /^main:/ { print $2; exit }')"
first_main_id="$(tmux display-message -p -t "$first_main" '#{pane_id}')"
if [ "$first_main_id" = "$c" ]; then second_row="$c"; third_row="$b"; fi

open
screen_e() { "${outer[@]}" capture-pane -ep; }
screen_e | grep 'aaa' | head -1 | grep -q '48;5;117' && fail "highlight spilled onto the first heading"
[ "$(pick)" = "$a_pane" ] || fail "cursor should start on the first pane, not its heading"

open
press C-j
screen_e | grep '→.*main' | head -1 | grep -q '48;5;117' && fail "highlight spilled onto the heading of the selected pane"
[ "$(pick)" = "$second_row" ] || fail "ctrl-j should cross the heading to the next session's pane"

open
press C-j
press C-j
press C-k
press C-k
[ "$(pick)" = "$a_pane" ] || fail "ctrl-k should cross the heading back"

open
press C-k
[ "$(pick)" = "$a_pane" ] || fail "ctrl-k at the top should stay on the first pane"

open
"${outer[@]}" send-keys C-j C-j
nap 0.5
[ "$(pick)" = "$third_row" ] || fail "a burst of ctrl-j should count each pane once"

open
press 2
nap 0.5
[ "$(current)" = "$second_row" ] || fail "2 should go to the second pane"
back_home

open
press 3
nap 0.5
[ "$(current)" = "$third_row" ] || fail "3 should go to the third pane"
back_home
tmux set-option -gu @agent_status_view

# An fzf without these flags must still get a working, static picker.
real_fzf="$(command -v fzf)"
cat > "$TMP/bin/fzf" <<FAKE
#!/bin/sh
case " \$* " in *--listen*) echo "unknown option" >&2; exit 2 ;; esac
exec "$real_fzf" "\$@"
FAKE
chmod +x "$TMP/bin/fzf"
press C-b j
appears 'agent panes>' || fail "picker broke on an older fzf"
press Escape

echo "ok: live picker"
