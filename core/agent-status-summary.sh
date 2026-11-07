#!/usr/bin/env bash
# Two jobs, both re-run on every tmux status-line recompute:
#
# 1. Crash/liveness sweep: any pane whose @agent_status is non-empty
#    and whose @agent_status_tool no longer matches that tool's
#    adapters/<tool>/process-pattern (i.e. the tool's process is no
#    longer the pane's foreground command - it exited, crashed, or the
#    shell took back control) gets its status cleared. This is a
#    crash/interrupt safety net for every adapter, not a wall-clock
#    idle timeout: a pane whose tool is still the foreground process
#    keeps whatever status it last reported, no matter how long a
#    single tool call or turn takes. Deliberately runs even when the
#    summary display below is turned off (@agent_status_summary off)
#    - it's a correctness fix, not a UI feature.
#
# 2. Persistent status-line summary: counts of panes across all
#    sessions in each state, e.g. "!2 …1 ✓3". Finished panes you have
#    already looked at don't count. Empty output when nothing's active,
#    so it doesn't leave a stray gap in status-right.
#
# Invoked as a `#()` command substitution from status-right - tmux
# recalculates those on its own status-interval, and also immediately
# on `tmux refresh-client` (which agent-status.sh already calls on
# every hook-driven transition), so both jobs stay live without a
# separate timer or background process.

set -euo pipefail

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(dirname "$CURRENT_DIR")"
# Applied directly, not via agent-status.sh: that script's tty check
# would reject us, since we never run inside the pane we're clearing.
# shellcheck source=./agent-status-apply.sh
source "$CURRENT_DIR/agent-status-apply.sh"

if ! tmux has-session 2>/dev/null; then
    exit 0
fi

# --- 1. Crash/liveness sweep -----------------------------------------

sweep_rows="$(tmux list-panes -a -F '#{pane_id}	#{@agent_status}	#{@agent_status_tool}	#{pane_current_command}' 2>/dev/null || true)"

while IFS=$'\t' read -r pane_id status tool current_command; do
    [ -z "$status" ] && continue
    [ -z "$tool" ] && continue

    pattern_file="$PLUGIN_ROOT/adapters/$tool/process-pattern"
    [ -f "$pattern_file" ] || continue
    pattern="$(cat "$pattern_file")"
    [ -z "$pattern" ] && continue

    if ! printf '%s' "$current_command" | grep -Eq "$pattern"; then
        agent_status_apply_to_tmux "$pane_id" "" "" >/dev/null 2>&1 || true
    fi
done <<< "$sweep_rows"

# --- Old "done" panes go idle ------------------------------------------

# Finished long ago and never visited: you left it on purpose, stop counting
# it. Only touches a display flag, so unlike a liveness timeout it can't
# misjudge a pane that is really working.
idle_after="$(tmux show-option -gqv @agent_status_idle_after 2>/dev/null || true)"
idle_after="${idle_after:-1440}"
if [ "$idle_after" -gt 0 ] 2>/dev/null; then
    tmux list-panes -a -F '#{pane_id} #{@agent_status}:#{@agent_status_seen} #{@agent_status_updated_at}' 2>/dev/null |
        awk -v cutoff="$(( $(date +%s) - idle_after * 60 ))" '$2 == "done:" && $3 != "" && $3 < cutoff { print $1 }' |
        while read -r pane_id; do
            tmux set-option -p -t "$pane_id" @agent_status_seen 1 2>/dev/null || true
        done
fi

# --- 2. Persistent summary --------------------------------------------

# One tmux round-trip for all options - this runs on every status refresh.
# \x1f, not tab: read collapses runs of whitespace IFS, so an unset
# option between two tabs would shift every later field.
sep=$'\x1f'
IFS="$sep" read -r summary_enabled icon_waiting icon_working icon_done < <(
    tmux display-message -p "#{@agent_status_summary}${sep}#{@agent_status_summary_icon_waiting}${sep}#{@agent_status_summary_icon_working}${sep}#{@agent_status_summary_icon_done}" 2>/dev/null || true
) || true
[ "$summary_enabled" = "off" ] && exit 0

rows="$(tmux list-panes -a -F '#{@agent_status}:#{@agent_status_seen}' 2>/dev/null || true)"

waiting="$(printf '%s\n' "$rows" | grep -c '^waiting:' || true)"
working="$(printf '%s\n' "$rows" | grep -c '^working:' || true)"
done_count="$(printf '%s\n' "$rows" | grep -c '^done:$' || true)"

out=""
agent_status_load_icons
[ "$waiting" -gt 0 ] && out="${out}${icon_waiting:-$ICON_WAITING}${waiting} "
[ "$working" -gt 0 ] && out="${out}${icon_working:-$ICON_WORKING}${working} "
[ "$done_count" -gt 0 ] && out="${out}${icon_done:-$ICON_DONE}${done_count} "

printf '%s' "$out"
