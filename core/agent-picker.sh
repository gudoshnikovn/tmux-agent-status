#!/usr/bin/env bash
# Lists every pane across all tmux sessions that has an agent status
# (needs your input, still working, or just finished) and jumps to the
# one picked in fzf.

set -euo pipefail

if ! command -v fzf >/dev/null 2>&1; then
    tmux display-message "agent-status: fzf not found (brew install fzf)"
    exit 1
fi

rows="$(tmux list-panes -a -F '#{@agent_status}	#{session_name}:#{window_index}.#{pane_index}	#{window_name}	#{pane_current_command}')"

filtered="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "waiting" || $1 == "working" || $1 == "done"')"

if [ -z "$filtered" ]; then
    tmux display-message "agent-status: no active panes"
    exit 0
fi

# Needs-your-input panes first, then still-working, then just-finished.
rank='{ order = ($1 == "waiting") ? 0 : ($1 == "working") ? 1 : 2; print order "\t" $0 }'
sorted="$(printf '%s\n' "$filtered" | awk -F'\t' "$rank" | sort -t'	' -k1,1n | cut -f2-)"

choice="$(printf '%s\n' "$sorted" | awk -F'\t' '{
    if ($1 == "waiting")     icon = "⏳ waiting";
    else if ($1 == "working") icon = "⚙️ working";
    else                       icon = "✅ done   ";
    printf "%s | %-25s | %s (%s)\t%s\n", icon, $2, $3, $4, $2;
}' | fzf --delimiter='\t' --with-nth=1 --ansi --prompt="agent panes> " --height=~40% --reverse)"

[ -z "$choice" ] && exit 0

target="$(printf '%s' "$choice" | awk -F'\t' '{print $2}')"
session="${target%%:*}"

tmux switch-client -t "$session"
tmux select-window -t "$target"
tmux select-pane -t "$target"
