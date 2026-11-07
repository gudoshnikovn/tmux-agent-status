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

press C-b j
appears 'agent panes>' || fail "popup did not open"
# Rows sort newest first, so the cursor starts on "second".
tmux send-keys -t "$c" 'echo LIVE-OUTPUT-MARK' Enter
appears 'LIVE-OUTPUT-MARK' || fail "preview did not follow the pane"

agent_status_apply_to_tmux "$b" waiting "" "" "permission: Bash"
appears 'permission: Bash' || fail "row did not pick up the new status"
# "first" now sorts above "second"; the cursor must have stayed on "second".
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
