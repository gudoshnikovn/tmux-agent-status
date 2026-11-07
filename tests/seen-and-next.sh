#!/usr/bin/env bash
# Seen tracking, notification suppression, counter and the jump-to-next key,
# against a real tmux server and client.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=./lib/tmux.sh
source "$ROOT/tests/lib/tmux.sh"
# shellcheck source=../core/agent-status-apply.sh
source "$ROOT/core/agent-status-apply.sh"

tmux set-option -g @agent_status_notify_system off
"$ROOT/tmux/agent-status.tmux"

fail() { echo "FAIL: $1"; exit 1; }
opt() { tmux show-option -p -qv -t "$1" "$2"; }
active() { tmux display-message -p '#{pane_id}'; }
waitseen() { for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(opt "$1" @agent_status_seen)" = "$2" ] && return 0; nap 0.1; done; return 1; }

tmux list-clients -F '#{client_flags}' | grep -q focused || fail "attached client is not reported as focused"

a="$(active)"
b="$(tmux new-window -d -P -F '#{pane_id}' -t main)"
c="$(tmux new-window -d -P -F '#{pane_id}' -t main)"
[ "$(tmux show-hooks -g | grep -c 'agent-status-seen')" -ge 3 ] || fail "seen hooks not installed"

agent_status_apply_to_tmux "$a" done "" ""
[ "$(opt "$a" @agent_status_seen)" = 1 ] || fail "done in the focused pane should be seen at once"

agent_status_apply_to_tmux "$b" done "" ""
[ -z "$(opt "$b" @agent_status_seen)" ] || fail "done in a background pane must stay unseen"
counter="$("$ROOT/core/agent-status-summary.sh")"
[ "$counter" = "✅1 " ] || fail "counter should skip seen panes, got [$counter]"

agent_status_apply_to_tmux "$c" waiting "" "" "permission: Bash"
[ "$(opt "$c" @agent_status_message)" = "permission: Bash" ] || fail "message not stored"
first="$(opt "$c" @agent_status_updated_at)"
tmux set-option -p -t "$c" @agent_status_updated_at 5
agent_status_apply_to_tmux "$c" waiting "" "" "permission: Bash"
[ "$(opt "$c" @agent_status_updated_at)" = 5 ] || fail "same-status re-fire moved the age (was $first)"

"$ROOT/core/agent-picker.sh" --next "" "$a"; nap 0.3
[ "$(active)" = "$c" ] || fail "next should go to the waiting pane first"
"$ROOT/core/agent-picker.sh" --next "" "$c"; nap 0.3
[ "$(active)" = "$b" ] || fail "next should go on to the unseen done pane"
waitseen "$b" 1 || fail "visiting a done pane should mark it seen"
agent_status_apply_to_tmux "$b" done "" ""
[ "$(opt "$b" @agent_status_seen)" = 1 ] || fail "same-status re-fire must not unsee"

"$ROOT/core/agent-picker.sh" --next "" "$b"; nap 0.3
[ "$(active)" = "$c" ] || fail "only the waiting pane is left"
agent_status_apply_to_tmux "$c" working "" ""
[ -z "$(opt "$c" @agent_status_message)" ] || fail "message must not outlive its status"
agent_status_apply_to_tmux "$c" "" "" ""
"$ROOT/core/agent-picker.sh" --next "" "$c"; nap 0.2
[ "$(active)" = "$c" ] || fail "nothing to jump to, should stay put"

agent_status_apply_to_tmux "$b" working "" ""
agent_status_apply_to_tmux "$b" done "" ""
tmux set-option -p -t "$b" @agent_status_updated_at "$(( $(date +%s) - 1441 * 60 ))"
[ "$("$ROOT/core/agent-status-summary.sh")" = "" ] || fail "a day-old done should drop out of the counter"
[ "$(opt "$b" @agent_status_seen)" = 1 ] || fail "a day-old done should be idle"
agent_status_apply_to_tmux "$b" working "" ""
agent_status_apply_to_tmux "$b" done "" ""
[ "$("$ROOT/core/agent-status-summary.sh")" = "✅1 " ] || fail "a fresh done should count"
tmux set-option -p -t "$b" @agent_status_updated_at 5
tmux set-option -g @agent_status_idle_after 0
[ "$("$ROOT/core/agent-status-summary.sh")" = "✅1 " ] || fail "idle_after 0 should disable going idle"

"$ROOT/tmux/agent-status.tmux"
[ "$(tmux show-hooks -g client-focus-in | wc -l | tr -d ' ')" = 1 ] || fail "reload stacked a hook"

echo "ok: seen tracking and next key"
