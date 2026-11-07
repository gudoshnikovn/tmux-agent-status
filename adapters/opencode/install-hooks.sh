#!/usr/bin/env bash
# Installs the TUI plugin into OpenCode 2's config dir and registers it in
# cli.json. Pass --uninstall to remove both. OpenCode 1 isn't supported: it has
# no cli.json, and creating one would skip OpenCode's own settings migration.
set -euo pipefail

ADAPTER_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd -P "$ADAPTER_DIR/../.." && pwd -P)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
CLI_JSON="$CONFIG_DIR/cli.json"
SPEC="./tmux-agent-status"

[ -f "$CLI_JSON" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [ "${1:-}" = "--uninstall" ]; then
    rm -rf "${CONFIG_DIR:?}/tmux-agent-status"
    jq --arg spec "$SPEC" 'if .plugins then .plugins -= [$spec] | if .plugins == [] then del(.plugins) else . end else . end' "$CLI_JSON" > "$tmp"
else
    mkdir -p "$CONFIG_DIR/tmux-agent-status"
    sed "s|__REPORTER__|$PLUGIN_DIR/core/agent-status.sh|" "$ADAPTER_DIR/tui.js" > "$CONFIG_DIR/tmux-agent-status/tui.js"
    jq --arg spec "$SPEC" '.plugins = (((.plugins // []) - [$spec]) + [$spec])' "$CLI_JSON" > "$tmp"
fi

if ! cmp -s "$tmp" "$CLI_JSON"; then
    cp -n "$CLI_JSON" "$CLI_JSON.bak.tmux-agent-status" 2>/dev/null || true
    cat "$tmp" > "$CLI_JSON"
fi
