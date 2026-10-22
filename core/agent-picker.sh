#!/usr/bin/env bash
# Lists every pane across all tmux sessions that has an agent status
# (needs your input, still working, or just finished) and jumps to the
# one picked in fzf. Also supports dismissing panes from the list
# (ctrl-x) without losing their live status - dismissing just clears
# @agent_status, the same as the crash/liveness sweep's clear path, so
# the pane naturally reappears the next time its adapter fires a hook.

set -euo pipefail

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

list_panes() {
    local current_session="$1"
    local rows filtered rank sorted
    rows="$(tmux list-panes -a -F '#{@agent_status}	#{@agent_status_updated_at}	#{session_name}:#{window_index}.#{pane_index}	#{window_name}	#{?#{@agent_status_label},#{@agent_status_label},#{pane_current_command}}')"

    filtered="$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "waiting" || $1 == "working" || $1 == "done"')"
    [ -z "$filtered" ] && return 0

    # Needs-your-input panes first, then still-working, then just-finished;
    # within each of those groups, most-recently-changed status first.
    rank='{ order = ($1 == "waiting") ? 0 : ($1 == "working") ? 1 : 2; print order "\t" $0 }'
    sorted="$(printf '%s\n' "$filtered" | awk -F'\t' "$rank" | sort -t'	' -k1,1n -k3,3nr | cut -f2-)"

    # Rows in the session we were invoked from get a green "→" marker
    # (ANSI, relies on --ansi in the fzf invocation below) so the
    # session you're currently in stands out from every other one.
    # Several agent panes in one session get a "[i/N]" badge so it's
    # obvious they're siblings and which one is which.
    printf '%s\n' "$sorted" | awk -F'\t' -v cur="$current_session" '
    { line[NR] = $0; s = $3; sub(/:.*/, "", s); sess[NR] = s; total[s]++ }
    END {
        for (n = 1; n <= NR; n++) {
            split(line[n], f, "\t");
            if (f[1] == "waiting")      icon = "⏳ waiting";
            else if (f[1] == "working") icon = "⚙️ working";
            else                        icon = "✅ done   ";
            num = (n <= 9) ? n : " ";
            s = sess[n];
            marker = (s == cur) ? "\033[1;32m→\033[0m" : " ";
            badge = (total[s] > 1) ? sprintf("[%d/%d]", ++seen[s], total[s]) : "";
            printf "%s%s %s | %-25s %-5s | %s (%s)\t%s\n", marker, num, icon, f[3], badge, f[4], f[5], f[3];
        }
    }'
}

if [ "${1:-}" = "--list" ]; then
    list_panes "${2:-}"
    exit 0
fi

if [ "${1:-}" = "--dismiss" ]; then
    shift
    # shellcheck source=./agent-status-apply.sh
    source "$CURRENT_DIR/agent-status-apply.sh"
    for target in "$@"; do
        agent_status_apply_to_tmux "$target" "" "" >/dev/null 2>&1 || true
    done
    exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
    tmux display-message "agent-status: fzf not found (brew install fzf)"
    exit 1
fi

current_pane="${1:-}"
current_session="${current_pane%%:*}"

formatted="$(list_panes "$current_session")"

if [ -z "$formatted" ]; then
    tmux display-message "agent-status: no active panes"
    exit 0
fi

number_binds=""
for n in 1 2 3 4 5 6 7 8 9; do
    number_binds="$number_binds --bind $n:pos($n)+accept"
done

# shellcheck disable=SC2086
choice="$(printf '%s\n' "$formatted" | fzf --multi --delimiter='\t' --with-nth=1 --ansi \
    --prompt="agent panes> " --reverse \
    --header='enter: jump | 1-9: jump to row | tab: select | ctrl-x: dismiss selected | ctrl-r: refresh' \
    --color='fg:-1,bg:-1,fg+:16:bold,bg+:117,hl:25,hl+:25:bold,info:25,prompt:25,pointer:196,marker:28,header:25,border:-1,label:-1' \
    $number_binds \
    --bind "ctrl-r:reload($CURRENT_DIR/agent-picker.sh --list '$current_session')" \
    --bind "ctrl-x:execute-silent($CURRENT_DIR/agent-picker.sh --dismiss {+2})+reload($CURRENT_DIR/agent-picker.sh --list '$current_session')")" || exit 0 # Esc/ctrl-c (130) or no match (1) is a cancel, not an error

[ -z "$choice" ] && exit 0

target="$(printf '%s' "$choice" | awk -F'\t' '{print $2}')"
session="${target%%:*}"

tmux switch-client -t "$session"
tmux select-window -t "$target"
tmux select-pane -t "$target"
