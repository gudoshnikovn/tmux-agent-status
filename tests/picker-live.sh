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

# Only this server's pickers: the user's own popup may be open on the real server.
leftovers() { ps -axo pid=,etime=,args= | grep "[f]zf.sock" | grep "$ROOT" || true; }
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

# Grouped: the cursor and 1-9 reach panes only, whichever pane is first or second.
tmux set-option -g @agent_status_view session
press C-b j
appears "$heading" || fail "@agent_status_view did not set the default"
press Enter
nap 0.5
first_pane="$(tmux display-message -p '#{pane_id}')"
press C-b j
appears "$heading" || fail "popup did not reopen"
press C-j
press Enter
nap 0.5
second_pane="$(tmux display-message -p '#{pane_id}')"
[ "$first_pane" != "$second_pane" ] || fail "one ctrl-j should land on the next pane, not a heading"
press C-b j
appears "$heading" || fail "popup did not reopen"
press 2
nap 0.5
[ "$(tmux display-message -p '#{pane_id}')" = "$second_pane" ] || fail "2 should go to the second pane"
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
