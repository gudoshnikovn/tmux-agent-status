#!/usr/bin/env bash
# TPM entry point for tmux-agent-status.

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(dirname "$CURRENT_DIR")"

# Optional config-file layer - fills in any @agent_status_* option not
# already set via `set -g` in .tmux.conf. See core/load-config.sh.
"$PLUGIN_ROOT/core/load-config.sh"

tmux_option() {
    local option="$1"
    local default="$2"
    local value
    value="$(tmux show-option -gqv "$option")"
    [ -n "$value" ] && echo "$value" || echo "$default"
}

pick_key="$(tmux_option "@agent_status_pick_key" "j")"

# If a previous version of this plugin left pane-border-style/
# pane-active-border-style pointed at our status conditional, restore
# whatever the user/theme had before we touched it, then drop the
# now-unused baseline options. Only runs once per pane-border-style
# still containing our marker, so it's a no-op after the first reload.
for opt in pane-border-style pane-active-border-style; do
    base_opt="@agent_status_base_${opt//-/_}"
    current="$(tmux show-option -gqv "$opt")"
    case "$current" in
        *@agent_status*)
            base_value="$(tmux show-option -gqv "$base_opt")"
            if [ -n "$base_value" ] && [ "$base_value" != "default" ]; then
                tmux set-option -g "$opt" "$base_value"
            else
                tmux set-option -gu "$opt"
            fi
            ;;
    esac
    tmux set-option -gu "$base_opt" 2>/dev/null || true
done

# Persistent "⏳2 ⚙️1 ✅3"-style summary prepended to status-right, same
# baseline-capture-once trick as the border styles above so re-sourcing
# .tmux.conf doesn't keep prepending onto its own previous output. Note
# this #() call also drives the crash/liveness sweep in
# agent-status-summary.sh - it must stay wired up even when the visible
# counter is disabled (@agent_status_summary off), since the sweep is a
# correctness fix, not just a display feature.
base_status_right="$(tmux show-option -gqv @agent_status_base_status_right)"
if [ -z "$base_status_right" ]; then
    base_status_right="$(tmux show-option -gqv status-right)"
    tmux set-option -g @agent_status_base_status_right "$base_status_right"
fi
tmux set-option -g status-right "#($PLUGIN_ROOT/core/agent-status-summary.sh)${base_status_right}"

tmux bind-key "$pick_key" display-popup -E -w 80% -h 60% "'$PLUGIN_ROOT/core/agent-picker.sh'"

# Each adapters/<tool>/ directory owns its own detection and hook
# installation - the core here never needs to know which tools exist.
# Adding support for a new tool means adding a new adapters/<tool>/
# directory with detect.sh + install-hooks.sh + process-pattern; this
# loop and everything above it stays untouched.
for adapter_dir in "$PLUGIN_ROOT"/adapters/*/; do
    [ -d "$adapter_dir" ] || continue
    if [ -x "$adapter_dir/detect.sh" ] && "$adapter_dir/detect.sh" >/dev/null 2>&1; then
        if [ -x "$adapter_dir/install-hooks.sh" ]; then
            "$adapter_dir/install-hooks.sh" >/dev/null 2>&1 || true
        fi
    fi
done
