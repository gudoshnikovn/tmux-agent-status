#!/usr/bin/env bash
# adapters/claude-code/hook.sh: payload -> status. The file transport makes the
# decision observable without tmux; a fake tmux supplies the pane's current state.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/tmux" <<'FAKE'
#!/bin/sh
case "$*" in
    *"@agent_status_message"*) printf '%s\n' "$FAKE_MESSAGE" ;;
    *"@agent_status"*) printf '%s\n' "$FAKE_STATUS" ;;
esac
FAKE
chmod +x "$TMP/tmux"
export PATH="$TMP:$PATH" TMUX_PANE=%1 TMUX_AGENT_STATUS_TRANSPORT=file TMUX_AGENT_STATUS_BRIDGE_FILE="$TMP/bridge"
fails=0

check() { # name mapped-status payload pane-status pane-message expected-line-suffix ("" = dropped)
    : > "$TMP/bridge"
    printf '%s' "$3" | FAKE_STATUS="$4" FAKE_MESSAGE="$5" "$ROOT/adapters/claude-code/hook.sh" "$2" --tool claude-code
    got="$(sed 's/^[^ ]* pane=%1 //' "$TMP/bridge")"
    if [ "$got" != "$6" ]; then
        echo "FAIL $1: expected [$6], got [$got]"
        fails=$((fails + 1))
    fi
}

line() { printf 'status=%s tool=claude-code label= message=%s' "$1" "${2:-}"; }

check "plain stop" done '{"hook_event_name":"Stop","background_tasks":[]}' working "" "$(line done)"
check "background shell ends the turn but is named" done \
    '{"hook_event_name":"Stop","background_tasks":[{"type":"shell","status":"running","description":"gh run\nwatch"},{"type":"shell","status":"completed","description":"x"}]}' \
    working "" "$(line done "bg shell: gh run watch")"
check "two background tasks" done \
    '{"hook_event_name":"Stop","background_tasks":[{"type":"shell","status":"running","description":"a"},{"type":"monitor","status":"running","description":"b"}]}' \
    working "" "$(line done "bg shell: a; monitor: b")"
check "idle_prompt keeps the background note" done '{"hook_event_name":"Notification"}' done "bg shell: a" ""
check "idle_prompt still heals an interrupt" done '{"hook_event_name":"Notification"}' working "" "$(line done)"
check "background subagent keeps it working" done \
    '{"hook_event_name":"Stop","background_tasks":[{"type":"subagent","status":"running"}]}' working "" "$(line working)"
check "finished subagent does not" done \
    '{"hook_event_name":"Stop","background_tasks":[{"type":"subagent","status":"completed"}]}' working "" "$(line done)"
check "permission names the tool" waiting \
    '{"hook_event_name":"PermissionRequest","tool_name":"Bash"}' working "" "$(line waiting "permission: Bash")"
check "subagent cannot revive a finished pane" working \
    '{"hook_event_name":"PostToolUse","agent_id":"a1","tool_name":"Bash"}' done "" ""
check "subagent cannot clear the main agent's prompt" working \
    '{"hook_event_name":"PostToolUse","agent_id":"a1"}' waiting "permission: Bash" ""
check "subagent prompt is marked" waiting \
    '{"hook_event_name":"PermissionRequest","agent_id":"a1","tool_name":"Bash"}' working "" "$(line waiting "subagent permission: Bash")"
check "subagent clears its own prompt" working \
    '{"hook_event_name":"PostToolUse","agent_id":"a1"}' waiting "subagent permission: Bash" "$(line working)"
check "main agent event passes" working '{"hook_event_name":"PostToolUse","tool_name":"Bash"}' waiting "permission: Bash" "$(line working)"
check "garbage payload passes through" working 'not json' done "" "$(line working)"

[ "$fails" -eq 0 ] && echo "ok: claude hook decisions"
exit "$fails"
