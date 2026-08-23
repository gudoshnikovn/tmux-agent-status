#!/usr/bin/env bash
# Merges the agent-status shell-hook commands into ~/.hermes/config.yaml,
# additively, without touching any other hooks already configured there.
#
# Event mapping (see CLAUDE.md, "The Hermes adapter", for the full
# reasoning):
#   pre_llm_call          -> working  (turn start, closest to UserPromptSubmit)
#   pre_tool_call         -> working  (a tool is about to run)
#   pre_approval_request  -> waiting  (an approval decision is about to be requested)
#   post_tool_call        -> working  (a tool just finished)
#   post_approval_response -> working (an approval decision resolved)
#   on_session_end         -> done    (turn ended, any outcome - see CLAUDE.md)
#
# Not wired: a "turn failed via API error" analog (Hermes has no single
# event for "turn abandoned", only per-attempt events that may still
# retry). Panes running Hermes instead rely on the crash/liveness sweep
# in core/agent-status-summary.sh to clear a stale status once the
# `hermes` process is no longer the pane's foreground command.
#
# Hermes shell hooks require either an interactive first-use approval
# or a non-interactive opt-in (HERMES_ACCEPT_HOOKS=1 / --accept-hooks /
# hooks_auto_accept: true in config.yaml) or they silently never
# register. This script deliberately does NOT set hooks_auto_accept -
# that flag weakens Hermes's consent model for every shell hook, not
# just ours. Run `hermes` once after installing and approve the prompt,
# or set one of the opt-ins yourself if you want non-interactive
# installs (e.g. in CI).

set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK_SCRIPT="$PLUGIN_DIR/core/agent-status.sh"
CONFIG_FILE="${HERMES_CONFIG_FILE:-$HOME/.hermes/config.yaml}"

print_manual_instructions() {
    cat >&2 <<EOF
tmux-agent-status: could not automatically edit $CONFIG_FILE
(need python3 with pyyaml, or yq, on PATH). Add this to its hooks:
block manually:

hooks:
  pre_llm_call:
    - command: "$HOOK_SCRIPT working --tool hermes"
  pre_tool_call:
    - command: "$HOOK_SCRIPT working --tool hermes"
  pre_approval_request:
    - command: "$HOOK_SCRIPT waiting --tool hermes"
  post_tool_call:
    - command: "$HOOK_SCRIPT working --tool hermes"
  post_approval_response:
    - command: "$HOOK_SCRIPT working --tool hermes"
  on_session_end:
    - command: "$HOOK_SCRIPT done --tool hermes"
EOF
}

mkdir -p "$(dirname "$CONFIG_FILE")"
if [ ! -f "$CONFIG_FILE" ]; then
    printf 'hooks: {}\n' > "$CONFIG_FILE"
fi

merge_with_python() {
    python3 - "$CONFIG_FILE" "$HOOK_SCRIPT" <<'PYEOF'
import sys
import yaml

config_file, hook_script = sys.argv[1], sys.argv[2]

with open(config_file) as f:
    config = yaml.safe_load(f) or {}

config.setdefault("hooks", {})

events = {
    "pre_llm_call": "working",
    "pre_tool_call": "working",
    "pre_approval_request": "waiting",
    "post_tool_call": "working",
    "post_approval_response": "working",
    "on_session_end": "done",
}

for event, status in events.items():
    command = f"{hook_script} {status} --tool hermes"
    entries = config["hooks"].get(event, [])
    if not isinstance(entries, list):
        entries = []
    # Strip any entry already registered by our script (regardless of
    # which status it points at), then add back the current one - same
    # dedup-by-command-prefix approach as the Claude Code adapter.
    entries = [e for e in entries if not (isinstance(e, dict) and str(e.get("command", "")).startswith(hook_script))]
    entries.append({"command": command})
    config["hooks"][event] = entries

with open(config_file, "w") as f:
    yaml.safe_dump(config, f, default_flow_style=False, sort_keys=False)
PYEOF
}

if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    merge_with_python
    echo "Installed agent-status hooks into $CONFIG_FILE"
    echo "Run 'hermes' once and approve the shell-hook prompt (or set HERMES_ACCEPT_HOOKS=1) to activate them." >&2
elif command -v yq >/dev/null 2>&1; then
    for spec in \
        "pre_llm_call:working" \
        "pre_tool_call:working" \
        "pre_approval_request:waiting" \
        "post_tool_call:working" \
        "post_approval_response:working" \
        "on_session_end:done"
    do
        event="${spec%%:*}"
        status="${spec#*:}"
        command_str="$HOOK_SCRIPT $status --tool hermes"
        # Drop any existing entry for this event whose command starts
        # with our script path, then append the current one.
        yq -i ".hooks.\"$event\" = ((.hooks.\"$event\" // []) | map(select(.command | test(\"^$HOOK_SCRIPT\") | not)) + [{\"command\": \"$command_str\"}])" "$CONFIG_FILE"
    done
    echo "Installed agent-status hooks into $CONFIG_FILE"
    echo "Run 'hermes' once and approve the shell-hook prompt (or set HERMES_ACCEPT_HOOKS=1) to activate them." >&2
else
    print_manual_instructions
fi
