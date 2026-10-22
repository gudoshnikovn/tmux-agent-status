# Shared "write one status transition into the real tmux server" logic.
# Sourced (not executed) by both:
#   - agent-status.sh, transport=direct: calls this immediately, in the
#     same process as the hook, since tmux is reachable locally - this
#     is the pre-existing behavior, just factored out.
#   - agent-status-bridge-watch.sh, transport=file: calls this once per
#     line relayed from the bridge file, running on the host where tmux
#     actually lives, on behalf of a hook that ran inside a
#     container/VM/remote host and couldn't reach the tmux socket
#     directly (see README's "Agent running in a container/VM/remote
#     host" section).
#
# Defines agent_status_apply_to_tmux <pane_id> <status> <tool> and
# nothing else - no top-level code, no `set -e` (the sourcing script
# owns its own shell options).

agent_status_apply_to_tmux() {
    local pane="$1"
    local status="$2"
    local tool="$3"
    local label="${4:-}"

    [ -z "$pane" ] && return 0
    tmux has-session 2>/dev/null || return 0

    # Read the previous value before overwriting it - needed below to
    # tell a real transition (e.g. "working" -> "waiting") from a
    # same-status re-fire, so the transient notification doesn't spam
    # on every re-fire.
    local prev_status
    prev_status="$(tmux show-option -p -qv -t "$pane" @agent_status 2>/dev/null || true)"

    case "$status" in
        working|waiting|done)
            tmux set-option -p -t "$pane" @agent_status "$status" 2>/dev/null || true
            ;;
        *)
            status=""
            tmux set-option -p -t "$pane" @agent_status "" 2>/dev/null || true
            ;;
    esac

    tmux set-option -p -t "$pane" @agent_status_updated_at "$(date +%s)" 2>/dev/null || true

    if [ -n "$tool" ]; then
        tmux set-option -p -t "$pane" @agent_status_tool "$tool" 2>/dev/null || true
    fi

    # Display-only, e.g. which Claude Code profile (claude vs claude-personal).
    if [ -n "$label" ]; then
        tmux set-option -p -t "$pane" @agent_status_label "$label" 2>/dev/null || true
    fi

    # The status-line #() summary is a global format, but tmux does not
    # recompute it on every option change - only on the next natural
    # redraw. Force it immediately instead of waiting/polling.
    tmux refresh-client 2>/dev/null || true

    # Transient "psst, look over here" notification: only on a real
    # transition into waiting/done (not a same-status re-fire, and not
    # on "working" - that would fire on every single tool call). Opt
    # out with `set -g @agent_status_notify off`.
    local notify_enabled
    notify_enabled="$(tmux show-option -gqv @agent_status_notify 2>/dev/null || true)"
    if [ "$notify_enabled" != "off" ] && [ "$status" != "$prev_status" ] && { [ "$status" = "waiting" ] || [ "$status" = "done" ]; }; then
        local duration location icon
        duration="$(tmux show-option -gqv @agent_status_notify_duration 2>/dev/null || true)"
        [ -z "$duration" ] && duration=3000

        location="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true)"

        case "$status" in
            waiting) icon="⏳ waiting" ;;
            done)    icon="✅ done" ;;
        esac

        tmux display-message -d "$duration" -t "$pane" "$icon: $location" 2>/dev/null || true

        # macOS notification-center alert - unlike the tmux message
        # above, this isn't dismissed by keypresses in the terminal.
        local system_notify
        system_notify="$(tmux show-option -gqv @agent_status_notify_system 2>/dev/null || true)"
        if [ "$system_notify" != "off" ] && command -v osascript >/dev/null 2>&1; then
            # Escape backslashes/quotes - session/window/pane names are
            # user-controlled and get embedded in an AppleScript string.
            local safe_location
            safe_location="$(printf '%s' "$location" | sed 's/\\/\\\\/g; s/"/\\"/g')"
            osascript -e "display notification \"$safe_location\" with title \"tmux-agent-status\" subtitle \"$icon\"" >/dev/null 2>&1 &
        fi

        # Optional sound - off by default. Opt in with
        # `set -g @agent_status_notify_sound on`.
        local sound_enabled
        sound_enabled="$(tmux show-option -gqv @agent_status_notify_sound 2>/dev/null || true)"
        if [ "$sound_enabled" = "on" ] && command -v afplay >/dev/null 2>&1; then
            local sound_file
            sound_file="$(tmux show-option -gqv @agent_status_notify_sound_file 2>/dev/null || true)"
            [ -z "$sound_file" ] && sound_file="/System/Library/Sounds/Glass.aiff"
            afplay "$sound_file" >/dev/null 2>&1 &
        fi
    fi
}
