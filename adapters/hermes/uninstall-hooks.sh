#!/usr/bin/env bash
# Reverses adapters/hermes/install-hooks.sh: removes only the entries this
# plugin added to ~/.hermes/config.yaml's `hooks:` block (matched the same
# way install-hooks.sh dedups them - by command prefix, so unrelated hooks
# from other tools/plugins are left untouched), then revokes those same
# commands from ~/.hermes/shell-hooks-allowlist.json via `hermes hooks
# revoke` so they don't linger there as stale approvals.
#
# Not run automatically on tmux reload/unload - install-hooks.sh is the
# only one wired into tmux/agent-status.tmux's adapter loop. This is a
# manual "I want tmux-agent-status out of my Hermes config" command.

set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK_SCRIPT="$PLUGIN_DIR/core/agent-status.sh"
CONFIG_FILE="${HERMES_CONFIG_FILE:-$HOME/.hermes/config.yaml}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "No $CONFIG_FILE found - nothing to remove."
    exit 0
fi

remove_with_python() {
    python3 - "$CONFIG_FILE" "$HOOK_SCRIPT" <<'PYEOF'
import sys
import yaml

config_file, hook_script = sys.argv[1], sys.argv[2]

with open(config_file) as f:
    config = yaml.safe_load(f) or {}

hooks = config.get("hooks")
if not isinstance(hooks, dict):
    sys.exit(0)

removed_commands = set()
for event in list(hooks.keys()):
    entries = hooks.get(event)
    if not isinstance(entries, list):
        continue
    kept = []
    for e in entries:
        if isinstance(e, dict) and str(e.get("command", "")).startswith(hook_script):
            removed_commands.add(e["command"])
        else:
            kept.append(e)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

with open(config_file, "w") as f:
    yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)

for command in sorted(removed_commands):
    print(command)
PYEOF
}

remove_with_yq() {
    for status in working waiting done; do
        command_str="$HOOK_SCRIPT $status --tool hermes"
        for event in pre_llm_call pre_tool_call pre_approval_request post_tool_call post_approval_response on_session_end; do
            yq -i ".hooks.\"$event\" |= (if . == null then null else map(select(.command != \"$command_str\")) end)" "$CONFIG_FILE"
        done
        echo "$command_str"
    done
}

removed=""
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    removed="$(remove_with_python)"
elif command -v yq >/dev/null 2>&1; then
    removed="$(remove_with_yq)"
else
    echo "tmux-agent-status: could not automatically edit $CONFIG_FILE" >&2
    echo "(need python3 with pyyaml, or yq, on PATH). Remove any hooks:" >&2
    echo "entries whose command starts with $HOOK_SCRIPT manually." >&2
    exit 1
fi

if [ -z "$removed" ]; then
    echo "No tmux-agent-status hooks found in $CONFIG_FILE - nothing to remove."
    exit 0
fi

echo "Removed from $CONFIG_FILE:"
echo "$removed" | sed 's/^/  /'

if command -v hermes >/dev/null 2>&1; then
    echo "Revoking matching allowlist entries..."
    while IFS= read -r command_str; do
        [ -n "$command_str" ] || continue
        hermes hooks revoke "$command_str" >/dev/null 2>&1 || true
    done <<< "$removed"
    echo "Done."
else
    echo "hermes not found on PATH - allowlist entries (if any) were left in place;" >&2
    echo "run 'hermes hooks revoke \"<command>\"' for each command above once it's back on PATH." >&2
fi
