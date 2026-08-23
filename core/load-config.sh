#!/usr/bin/env bash
# Optional config-file layer, sourced by tmux/agent-status.tmux before it
# reads any @agent_status_* option. Lets you set defaults in a plain
# `key = value` file instead of (or alongside) `set -g @agent_status_*`
# lines in .tmux.conf.
#
# File location: $TMUX_AGENT_STATUS_CONFIG, or
# ~/.config/tmux-agent-status/config if unset. Missing file is a no-op.
#
# Format: one `key = value` per line, `#` comments, blank lines ignored.
# `key` maps to the tmux user option `@agent_status_<key>` - see
# config.example for the full list.
#
# Precedence: a value already set on @agent_status_<key> (e.g. by an
# explicit `set -g` in .tmux.conf) is left alone - this file only fills
# in options that aren't already set, the same "capture only if unset"
# trick agent-status.tmux uses for base_border_style. This makes the
# file and .tmux.conf's `set -g` lines compose regardless of which one
# runs first: whichever explicitly sets a value, wins.

set -euo pipefail

config_file="${TMUX_AGENT_STATUS_CONFIG:-$HOME/.config/tmux-agent-status/config}"

[ -f "$config_file" ] || exit 0

while IFS= read -r line || [ -n "$line" ]; do
    # Strip comments and surrounding whitespace.
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue

    case "$line" in
        *=*)
            key="${line%%=*}"
            value="${line#*=}"
            key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            ;;
        *)
            continue
            ;;
    esac

    [ -z "$key" ] && continue

    option="@agent_status_$key"
    existing="$(tmux show-option -gqv "$option" 2>/dev/null || true)"
    [ -n "$existing" ] && continue

    tmux set-option -g "$option" "$value" 2>/dev/null || true
done < "$config_file"
