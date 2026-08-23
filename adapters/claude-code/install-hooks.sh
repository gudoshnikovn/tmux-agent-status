#!/usr/bin/env bash
# Merges the agent-status hook commands into ~/.claude/settings.json,
# additively, without touching any other hooks already configured there.
#
# Event wiring reasoning (why these exact events/matchers) lives in
# CLAUDE.md, not here - this script is intentionally just the
# mechanical jq merge.

set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK_SCRIPT="$PLUGIN_DIR/core/agent-status.sh"
SETTINGS_FILE="${CLAUDE_SETTINGS_FILE:-$HOME/.claude/settings.json}"

if ! command -v jq >/dev/null 2>&1; then
    echo "tmux-agent-status: jq not found, skipping Claude Code hook install." >&2
    echo "Install jq (brew install jq) and re-source your tmux config, or add" >&2
    echo "hooks manually that call: $HOOK_SCRIPT <working|waiting|done|clear> --tool claude-code" >&2
    exit 0
fi

mkdir -p "$(dirname "$SETTINGS_FILE")"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

jq \
    --arg script "$HOOK_SCRIPT" \
    --arg working_cmd "$HOOK_SCRIPT working --tool claude-code" \
    --arg wait_cmd "$HOOK_SCRIPT waiting --tool claude-code" \
    --arg done_cmd "$HOOK_SCRIPT done --tool claude-code" \
    --arg clear_cmd "$HOOK_SCRIPT clear --tool claude-code" \
    '
    def is_ours: .hooks[0].command != null and (.hooks[0].command | startswith($script));

    # Remove every agent-status.sh entry already registered for this
    # event, regardless of matcher (so upgrading which matcher/command
    # we use for an event replaces the old registration instead of
    # piling up), then add back the current desired set.
    def set_hooks($event; $entries):
        .hooks[$event] //= []
        | .hooks[$event] |= map(select(is_ours | not))
        | .hooks[$event] += $entries;

    # A new prompt started - assume Claude is working on it.
    set_hooks("UserPromptSubmit"; [{"matcher": "", "hooks": [{"type": "command", "command": $working_cmd}]}])
    # A tool is about to run - re-assert "working". Note this does NOT
    # fire again after a permission prompt is resolved for the same tool
    # call (PreToolUse only fires once, before the permission check) -
    # PostToolUse below is what actually clears "waiting" in that case.
    | set_hooks("PreToolUse"; [{"matcher": "", "hooks": [{"type": "command", "command": $working_cmd}]}])
    # The permission dialog is shown - this is the one true "needs you
    # right now" moment.
    | set_hooks("PermissionRequest"; [{"matcher": "", "hooks": [{"type": "command", "command": $wait_cmd}]}])
    # A tool just finished running. This is the event that reliably fires
    # right after a permission prompt is approved and the tool executes -
    # PreToolUse does NOT re-fire for that same call, so without this,
    # "waiting" could stick until the next unrelated tool call or Stop.
    | set_hooks("PostToolUse"; [{"matcher": "", "hooks": [{"type": "command", "command": $working_cmd}]}])
    # Claude has been idle a while with nothing pending. This also acts
    # as a self-healing reset for interrupted turns, since Stop does NOT
    # fire when the user interrupts Claude.
    | set_hooks("Notification"; [{"matcher": "idle_prompt", "hooks": [{"type": "command", "command": $done_cmd}]}])
    # Turn ended normally, back to idle.
    | set_hooks("Stop"; [{"matcher": "", "hooks": [{"type": "command", "command": $done_cmd}]}])
    # An MCP tool is asking you for structured input mid-call - same
    # urgency as a permission prompt, and now its own dedicated event
    # (rather than waiting on the Notification/elicitation_dialog type,
    # which lagged the same way idle_prompt does).
    | set_hooks("Elicitation"; [{"matcher": "", "hooks": [{"type": "command", "command": $wait_cmd}]}])
    # You answered the elicitation - mirrors PostToolUse, clears "waiting".
    | set_hooks("ElicitationResult"; [{"matcher": "", "hooks": [{"type": "command", "command": $working_cmd}]}])
    # The turn ended because of an API error (rate limit, overloaded,
    # billing, etc), not a normal response - Stop does NOT fire in this
    # case, so without this the pane sticks on "working" until the next
    # idle_prompt (~60s), same class of gap as the user-interrupt case.
    | set_hooks("StopFailure"; [{"matcher": "", "hooks": [{"type": "command", "command": $done_cmd}]}])
    # The Claude Code session itself ended (exit/logout/etc), as opposed
    # to just a turn ending - clear the status instead of leaving a
    # stale color on a pane that outlives the session.
    | set_hooks("SessionEnd"; [{"matcher": "", "hooks": [{"type": "command", "command": $clear_cmd}]}])
    ' \
    "$SETTINGS_FILE" > "$tmp"

chmod +x "$HOOK_SCRIPT"
mv "$tmp" "$SETTINGS_FILE"
echo "Installed claude-status hooks into $SETTINGS_FILE"
