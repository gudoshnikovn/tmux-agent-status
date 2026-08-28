#!/usr/bin/env bash
# One-shot helper: explicitly approve every shell hook currently declared
# in ~/.hermes/config.yaml, without setting hooks_auto_accept (which would
# weaken consent for every future hook, ours or not - see CLAUDE.md).
#
# Hermes's own consent model (agent/shell_hooks.py) has no "approve all"
# subcommand and does not persist a decline - dismissing the interactive
# [y/N] prompt (Enter, "n", Ctrl-C) just means it asks again next launch.
# The only way to record a lasting approval without a TTY prompt is
# --accept-hooks (or HERMES_ACCEPT_HOOKS=1): it makes register_from_config()
# write an allowlist entry for every (event, command) pair currently in the
# config, and once an entry exists in ~/.hermes/shell-hooks-allowlist.json
# it is never re-prompted on any future run, with or without the flag.
#
# register_from_config() only runs for commands in Hermes's
# _AGENT_COMMANDS set (None/chat/acp/rl) - `hermes hooks list` and other
# subcommands return before ever reaching it, so the trigger has to be an
# actual (even trivial) agent invocation. `-z` ("oneshot") is the
# cheapest one: hook registration happens during startup, before the
# prompt is sent, so this still records approvals even if the model
# call itself later fails or times out.
#
# Caveat: this approves ALL not-yet-approved hooks in config.yaml this
# run, not just the ones this plugin installed - fine for a single-user
# machine, worth knowing if someone else's hooks are also pending
# approval.
#
# To undo an approval later: `hermes hooks revoke "<exact command>"`.

set -euo pipefail

PLUGIN_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK_SCRIPT="$PLUGIN_DIR/core/agent-status.sh"
ALLOWLIST_FILE="$HOME/.hermes/shell-hooks-allowlist.json"

if ! command -v hermes >/dev/null 2>&1; then
    echo "hermes not found on PATH" >&2
    exit 1
fi

echo "Approving all pending Hermes shell hooks (writes to ~/.hermes/shell-hooks-allowlist.json)..."
hermes --accept-hooks -z "ok" < /dev/null >/dev/null 2>&1 &
HERMES_PID=$!

# Wait for OUR command to actually show up allowlisted, not just for the
# allowlist file to exist - it may already exist (possibly empty, e.g.
# right after an uninstall-hooks.sh revoke) before this run adds anything,
# so a plain "-f" check would return instantly and kill hermes before
# registration finished.
for _ in $(seq 1 20); do
    if [ -f "$ALLOWLIST_FILE" ] && grep -qF "$HOOK_SCRIPT" "$ALLOWLIST_FILE"; then
        break
    fi
    sleep 1
done
kill "$HERMES_PID" >/dev/null 2>&1 || true
wait "$HERMES_PID" 2>/dev/null || true

echo "Done. Current allowlist status:"
hermes hooks list
