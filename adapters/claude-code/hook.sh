#!/usr/bin/env bash
# Claude Code's hook command: refines the status from hooks.map using the hook
# payload, which core/ must not parse, then hands off to core/agent-status.sh.
#
# Usage: hook.sh <status> --tool claude-code [--label <text>]

set -uo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

status="${1:-}"
shift || true

sep=$'\x1f'
# Without jq every field stays empty and the status passes through unchanged.
IFS="$sep" read -r event agent tool running_workers < <(jq -r '
    [.hook_event_name // "", .agent_id // "", .tool_name // "",
     ([.background_tasks[]? | select(.status == "running" and (.type == "subagent" or .type == "workflow"))] | length)]
    | map(tostring) | join("\u001f")' 2>/dev/null)

message=""
case "${event:-}" in
    # A background subagent wakes this session when it ends, so the turn isn't
    # really over. Background shells stay "done": a dev server never ends.
    Stop) [ "${running_workers:-0}" -gt 0 ] && status="working" ;;
    PermissionRequest) message="permission: ${tool:-}" ;;
    Elicitation) message="input requested" ;;
esac

# Subagent tool events arrive even after the main turn's Stop and during its
# permission prompts, so they may only clear a prompt that subagent raised.
# shortcut: a main-agent tool event can still clear a subagent's prompt; track prompt owners if that bites.
if [ -n "${agent:-}" ]; then
    if [ "$status" = "waiting" ]; then
        message="subagent ${message}"
    elif [ "$status" = "working" ]; then
        current="$(tmux show-option -p -qv -t "${TMUX_PANE:-}" @agent_status 2>/dev/null || true)"
        current_message="$(tmux show-option -p -qv -t "${TMUX_PANE:-}" @agent_status_message 2>/dev/null || true)"
        [ "$current" = "waiting" ] && [ "${current_message#subagent }" != "$current_message" ] || exit 0
    fi
fi

exec "$PLUGIN_DIR/core/agent-status.sh" "$status" "$@" --message "$message" </dev/null
