#!/usr/bin/env bash
# Lists every pane across all tmux sessions that has an agent status
# (needs your input, still working, or just finished) and jumps to the
# one picked in fzf. Also supports dismissing panes from the list
# (ctrl-x) without losing their live status - dismissing just clears
# @agent_status, the same as the crash/liveness sweep's clear path, so
# the pane naturally reappears the next time its adapter fires a hook.

set -euo pipefail

CURRENT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./agent-status-apply.sh
source "$CURRENT_DIR/agent-status-apply.sh"

# Foreground processes on any tty that look like a known agent, as "tty<TAB>name".
# Runtimes count by their script: "node /path/to/gemini" is gemini.
running_agents() {
    local names
    names="$(tmux show-option -gqv @agent_status_agents 2>/dev/null || true)"
    [ -n "$names" ] || names="claude codex gemini kimi opencode hermes aider cursor-agent copilot droid qwen grok pi amp"
    ps -axo tty=,stat=,args= 2>/dev/null | awk -v names="$names" '
    function base(p) { sub(/.*\//, "", p); return p }
    BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) known[list[i]] = 1 }
    $2 ~ /\+/ {
        name = base($3);
        if (name ~ /^(node|bun|deno|python[0-9.]*)$/) name = base($4);
        if (name in known) print $1 "\t" name;
    }'
}

# Picker views: each name here needs a render_<name> function below, reading rows
# on stdin, and may reorder them in order_view. Rows arrive as: status, updated_at,
# target, window, label, seen, message.
VIEWS="status session"

configured_view() {
    local view
    view="$(tmux show-option -gqv @agent_status_view 2>/dev/null || true)"
    case " $VIEWS " in
        *" ${view:-none} "*) printf '%s' "$view" ;;
        *) printf 'status' ;;
    esac
}

# Sessions in alphabetical order so they never jump around; rows keep their order
# within each one.
order_view() {
    case "$1" in
        session)
            awk -F'\t' '{ s = $3; sub(/:.*/, "", s); print s "\t" $0 }' | sort -s -f -t'	' -k1,1 | cut -f2-
            ;;
        *) cat ;;
    esac
}

render_awk() {
    agent_status_load_icons
    awk -F'\t' -v cur="$1" -v now="$(date +%s)" -v i_waiting="$ICON_WAITING" -v i_working="$ICON_WORKING" \
        -v i_done="$ICON_DONE" -v i_idle="$ICON_IDLE" -v i_unknown="$ICON_UNKNOWN" "$RENDER_COMMON$2"
}

RENDER_COMMON='
function age(updated, d) {
    if (updated == "") return "-";
    d = now - updated;
    if (d < 60) return d "s";
    if (d < 3600) return int(d / 60) "m";
    if (d < 86400) return int(d / 3600) "h";
    return int(d / 86400) "d";
}
# Why the pane is in this state, in colour and undimmed (22): on an idle row it is
# the one part still worth reading, e.g. a background shell it waits on.
function reason(msg) {
    return (msg != "") ? " · \033[22;36m" msg "\033[0m" : "";
}
function set_status_cell(status, seen) {
    dim = "";
    if (status == "waiting")      cell = sprintf("%s %-7s", i_waiting, "waiting");
    else if (status == "working") cell = sprintf("%s %-7s", i_working, "working");
    else if (status == "unknown") { cell = sprintf("%s %-7s", i_unknown, "unknown"); dim = "\033[2m"; }
    else if (seen != "")          { cell = sprintf("%s %-7s", i_idle, "idle"); dim = "\033[2m"; }
    else                          cell = sprintf("%s %-7s", i_done, "done");
}
'

# Flat list, needs-you first. The pane we were invoked from gets a green "→" marker
# (ANSI, relies on --ansi in the fzf invocation below); no marker if that pane has no
# agent. Several agent panes in one session get a "[i/N]" badge so it's obvious
# they're siblings.
render_status() {
    render_awk "$1" '
    { line[NR] = $0; s = $3; sub(/:.*/, "", s); sess[NR] = s; total[s]++ }
    END {
        # shortcut: awk may count bytes, so non-ASCII session names can still drift; upgrade if those show up.
        for (n = 1; n <= NR; n++) {
            split(line[n], f, "\t");
            s = sess[n];
            badge[n] = (total[s] > 1) ? sprintf("[%d/%d]", ++seen[s], total[s]) : "";
            if (length(f[3]) > target_w) target_w = length(f[3]);
            if (length(badge[n]) > badge_w) badge_w = length(badge[n]);
        }
        fmt = "%s%s%s %s %3s | %-" target_w "s %-" badge_w "s | %s (%s)%s%s\t%s\n";
        for (n = 1; n <= NR; n++) {
            split(line[n], f, "\t");
            set_status_cell(f[1], f[6]);
            num = (n <= 9) ? n : " ";
            marker = (f[3] == cur) ? "\033[1;32m→\033[0m" : " ";
            why = reason(f[7]);
            printf fmt, marker, dim, num, cell, age(f[2]), f[3], badge[n], f[4], f[5], why, (dim != "") ? "\033[0m" : "", f[3];
        }
    }'
}

# A heading per session, then its panes. fzf has no unselectable rows, so a heading
# is a row with target "=<first pane>" that picker-skip-heading.sh keeps the cursor
# off, and only panes get numbers. Search runs before this, so a heading exists only
# if one of its panes matched.
render_session() {
    render_awk "$1" '
    {
        line[NR] = $0; s = $3; sub(/:.*/, "", s); sess[NR] = s;
        p = $3; sub(/^[^:]*:/, "", p); pane[NR] = p;
        if (length(p) > pane_w) pane_w = length(p);
        if (!(s in first)) first[s] = $3;
        if ($1 == "done" && $6 != "") key = "idle"; else key = $1;
        count[s, key]++;
    }
    function rollup(s, out) {
        out = "";
        if (count[s, "waiting"]) out = out " " i_waiting count[s, "waiting"];
        if (count[s, "working"]) out = out " " i_working count[s, "working"];
        if (count[s, "done"]) out = out " " i_done count[s, "done"];
        if (count[s, "idle"]) out = out " " i_idle count[s, "idle"];
        if (count[s, "unknown"]) out = out " " i_unknown count[s, "unknown"];
        return out;
    }
    END {
        fmt = "%s%s%s %s %3s | %-" pane_w "s | %s (%s)%s%s\t%s\n";
        for (n = 1; n <= NR; n++) {
            split(line[n], f, "\t");
            s = sess[n];
            if (s != prev) {
                printf "  \033[1m%s\033[0m%s\t=%s\n", s, rollup(s), first[s];
                prev = s;
            }
            set_status_cell(f[1], f[6]);
            why = reason(f[7]);
            marker = (f[3] == cur) ? "\033[1;32m→\033[0m" : " ";
            printf fmt, marker, dim, (n <= 9) ? n : " ", cell, age(f[2]), pane[n], f[4], f[5], why, (dim != "") ? "\033[0m" : "", f[3];
        }
    }'
}

# Keeps the rows matching the picker's query, in order. fzf only filters what it's given,
# so searching happens here, on each pane's own text, not on the rendered list: a session
# name finds all its panes without being on their rows, and headings can't match.
filter_rows() {
    local query="$1"
    if [ -z "$query" ]; then
        cat
        return 0
    fi
    awk -F'\t' '{
        state = ($1 == "done" && $6 != "") ? "idle" : $1;
        print $3 " " $4 " " $5 " " state " " $7 "\t" $0;
    }' | { fzf --filter="$query" --no-sort --delimiter='\t' --nth=1 || true; } | cut -f2-
}

list_panes() {
    local current_pane="$1"
    local order_file="${2:-}"
    local view="${3:-}"
    local positions_file="${4:-}"
    local query="${5:-}"
    local rows filtered rank sorted out
    [ -n "$view" ] || view="$(configured_view)"
    rows="$(tmux list-panes -a -F '#{@agent_status}	#{@agent_status_updated_at}	#{session_name}:#{window_index}.#{pane_index}	#{window_name}	#{?#{@agent_status_label},#{@agent_status_label},#{pane_current_command}}	#{@agent_status_seen}	#{@agent_status_message}	#{pane_tty}	#{@agent_status_tool}')"

    # Panes with a status, plus agents that never reported (no adapter, not
    # restarted since the hooks went in): named by process, state unknown. A pane
    # whose adapter has reported before stays out: its status was cleared on purpose.
    filtered="$(printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' '
        FILENAME != "-" { agent[$1] = $2; next }
        $1 == "waiting" || $1 == "working" || $1 == "done" { print; next }
        { tty = $8; sub(/^\/dev\//, "", tty); if ($1 == "" && $9 == "" && (tty in agent)) { $1 = "unknown"; $5 = agent[tty]; print } }
    ' <(running_agents) -)"
    [ -z "$filtered" ] && return 0

    # Needs-your-input panes first, then still-working, then finished and
    # not looked at yet, then the rest; most-recently-changed first within each.
    rank='{ order = ($1 == "waiting") ? 0 : ($1 == "working") ? 1 : ($1 == "done" && $6 == "") ? 2 : ($1 == "done") ? 3 : 4; print order "\t" $0 }'
    sorted="$(printf '%s\n' "$filtered" | awk -F'\t' "$rank" | sort -t'	' -k1,1n -k3,3nr | cut -f2-)"

    # While the picker is open rows keep their place, so they can't move under the
    # cursor; new panes go last. fzf's --track would follow them instead, but it
    # blocks all input during every reload.
    if [ -n "$order_file" ]; then
        sorted="$(printf '%s\n' "$sorted" | awk -F'\t' 'NR == FNR { place[$1] = FNR; next } { print (($3 in place) ? place[$3] : 999999) "\t" $0 }' "$order_file" - | sort -s -t'	' -k1,1n | cut -f2-)"
    fi

    sorted="$(printf '%s\n' "$sorted" | filter_rows "$query")"
    out=""
    [ -z "$sorted" ] || out="$(printf '%s\n' "$sorted" | order_view "$view" | "render_$view" "$current_pane")"
    # Which list position the Nth numbered row sits at, for the 1-9 keys.
    [ -z "$positions_file" ] || printf '%s\n' "$out" | awk -F'\t' 'NF > 1 && $2 !~ /^=/ { print NR }' > "$positions_file"
    [ -z "$out" ] || printf '%s\n' "$out"
}

jump_to() {
    local target="$1" client="${2:-}"
    tmux switch-client ${client:+-c "$client"} -t "${target%%:*}"
    tmux select-window -t "$target"
    tmux select-pane -t "$target"
}

# Longest-waiting pane, then finished panes not looked at yet, cycling onward
# from the current one so repeated presses visit all of them.
jump_next() {
    local client="$1" current_pane="$2" target
    target="$(tmux list-panes -a -F '#{@agent_status}	#{@agent_status_updated_at}	#{session_name}:#{window_index}.#{pane_index}	#{@agent_status_seen}	#{pane_id}' |
        awk -F'\t' -v OFS='\t' '$1 == "waiting" { print 0, $2, $3, $5 } $1 == "done" && $4 == "" { print 1, $2, $3, $5 }' |
        sort -t'	' -k1,1n -k2,2n |
        awk -F'\t' -v cur="$current_pane" '
            NR == 1 { first = $3 }
            found && !pick { pick = $3 }
            $4 == cur { found = 1 }
            END { if (pick == "") pick = first; print pick }')"
    if [ -z "$target" ]; then
        tmux display-message ${client:+-c "$client"} "agent-status: nothing needs you"
        return 0
    fi
    jump_to "$target" "$client"
}

if [ "${1:-}" = "--list" ]; then
    list_panes "${2:-}" "${3:-}" "$(cat "${4:-/dev/null}" 2>/dev/null || true)" "${4:+$4.positions}" "${5:-}"
    exit 0
fi

# Switches the open picker to the next view. The state lives only as long as the
# picker, so reopening goes back to the configured default.
if [ "${1:-}" = "--next-view" ]; then
    current="$(cat "$2" 2>/dev/null || true)"
    # shellcheck disable=SC2086
    printf '%s\n' $VIEWS $VIEWS | awk -v cur="$current" 'found { print; exit } $0 == cur { found = 1 }' > "$2.tmp"
    mv "$2.tmp" "$2"
    exit 0
fi

if [ "${1:-}" = "--next" ]; then
    jump_next "${2:-}" "${3:-}"
    exit 0
fi

if [ "${1:-}" = "--dismiss" ]; then
    shift
    for target in "$@"; do
        case "$target" in =*) continue ;; esac # a session heading, not a pane
        agent_status_apply_to_tmux "$target" "" "" >/dev/null 2>&1 || true
    done
    exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
    tmux display-message "agent-status: fzf not found (brew install fzf)"
    exit 1
fi

current_pane="${1:-}"

formatted="$(list_panes "$current_pane" "" status)"

if [ -z "$formatted" ]; then
    tmux display-message "agent-status: no active panes"
    exit 0
fi

live_dir="$(mktemp -d)"
trap 'rm -rf "$live_dir"; [ -z "${refresher:-}" ] || kill "$refresher" 2>/dev/null || true' EXIT

order_file="$live_dir/order"
printf '%s\n' "$formatted" | cut -f2 > "$order_file"
view_file="$live_dir/view"
configured_view > "$view_file"
list_cmd="$CURRENT_DIR/agent-picker.sh --list '$current_pane' '$order_file' '$view_file' {q}"
formatted="$(list_panes "$current_pane" "$order_file" "$(cat "$view_file")" "$view_file.positions")"

# Display only, never parsed: drops trailing blank lines so "follow" lands on the
# prompt. Noting the target tells the refresher below which pane is on show.
preview="target={2}; target=\"\${target#=}\"; printf %s \"\$target\" > '$live_dir/focus'; tmux capture-pane -ep -t \"\$target\" | awk 'NF { last = NR } { line[NR] = \$0 } END { for (i = 1; i <= last; i++) print line[i] }' | tail -n 300"
preview_size="$(tmux show-option -gqv @agent_status_preview_size 2>/dev/null || true)"

number_binds=()
for n in 1 2 3 4 5 6 7 8 9; do
    number_binds+=(--bind "$n:transform(awk 'NR == $n { print \"pos(\" \$0 \")\" }' '$view_file.positions')+accept")
done
skip_heading="$CURRENT_DIR/picker-skip-heading.sh {n} {2} '$live_dir/last-pane'"

# Keep the open picker live: check once a second and poke fzf only when something
# changed, since every reload redraws the list and can swallow a keypress. A unix
# socket in a private dir, because anyone reaching fzf's listener can make it run
# commands. Older fzf lacks these flags, so ask it first and fall back to static.
live_sock="$live_dir/fzf.sock"
live_args=()
fzf_status=0
fzf --listen="$live_sock" --id-nth=2 --filter=x </dev/null >/dev/null 2>&1 || fzf_status=$?
if command -v curl >/dev/null 2>&1 && [ "$fzf_status" -ne 2 ]; then
    live_args=(--listen="$live_sock" --id-nth=2)
    (
        rows_seen=""
        view_seen=""
        # Popup teardown can skip the EXIT trap, so also stop when the picker is gone.
        while kill -0 "$$" 2>/dev/null; do
            sleep 1
            rows="$(tmux list-panes -a -F '#{pane_id}:#{@agent_status}:#{@agent_status_seen}:#{@agent_status_message}' 2>/dev/null || true)"
            view="$(tmux capture-pane -ep -t "$(cat "$live_dir/focus" 2>/dev/null || true)" 2>/dev/null | cksum || true)"
            actions=""
            if [ -n "$rows_seen" ] && [ "$rows" != "$rows_seen" ]; then
                actions="reload-sync($list_cmd)+refresh-preview"
            elif [ -n "$view_seen" ] && [ "$view" != "$view_seen" ]; then
                actions="refresh-preview"
            fi
            rows_seen="$rows"
            view_seen="$view"
            [ -z "$actions" ] || curl -s --unix-socket "$live_sock" -X POST http://localhost -d "$actions" >/dev/null 2>&1 || true
        done
    ) </dev/null >/dev/null 2>&1 &
    refresher=$!
fi

choice="$(printf '%s\n' "$formatted" | fzf --multi --disabled --delimiter='\t' --with-nth=1 --ansi \
    --bind "change:reload-sync($list_cmd)+first" \
    --prompt="agent panes> " --reverse \
    --preview="$preview" --preview-window="down:${preview_size:-75%}:follow:border-top" \
    --header=$'enter: jump | 1-9: jump to row | ctrl-j/k, ↓/↑: move | esc/ctrl-q: exit\ntab: select | ctrl-x: dismiss selected | ctrl-r: refresh | ctrl-s: switch view' \
    --color='fg:-1,bg:-1,fg+:16:bold,bg+:117,hl:25,hl+:25:bold,info:25,prompt:25,pointer:196,marker:28,header:25,border:-1,label:-1' \
    "${number_binds[@]}" ${live_args[@]+"${live_args[@]}"} \
    --bind "focus:transform($skip_heading)" --bind "load:transform($skip_heading)" \
    --bind "ctrl-r:reload($list_cmd)" \
    --bind "ctrl-s:execute-silent($CURRENT_DIR/agent-picker.sh --next-view '$view_file')+reload-sync($list_cmd)+first" \
    --bind "ctrl-x:execute-silent($CURRENT_DIR/agent-picker.sh --dismiss {+2})+reload($list_cmd)")" || exit 0 # Esc/ctrl-c (130) or no match (1) is a cancel, not an error

[ -z "$choice" ] && exit 0

target="$(printf '%s' "$choice" | awk -F'\t' '{ print $2 }')"
jump_to "${target#=}"
