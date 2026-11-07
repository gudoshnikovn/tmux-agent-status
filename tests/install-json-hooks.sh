#!/usr/bin/env bash
# core/install-json-hooks.sh via the Claude Code adapter: migration from the old
# direct-to-core entries, idempotence, foreign hooks, uninstall.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude-work"
export CLAUDE_SETTINGS_FILE="$TMP/.claude-work/settings.json"
OLD="$ROOT/core/agent-status.sh"

fail() { echo "FAIL: $1"; exit 1; }
count() { jq "[.hooks[][].hooks[] | select(.command | contains(\"$1\"))] | length" "$CLAUDE_SETTINGS_FILE"; }

# A settings file from before the change: stale matcher, stale event, a foreign hook.
jq -n --arg old "$OLD done --tool claude-code --label x" '{
    theme: "dark",
    hooks: {
        Stop: [{matcher: "", hooks: [{type: "command", command: $old}]},
               {matcher: "", hooks: [{type: "command", command: "/usr/bin/foreign"}]}],
        Notification: [{matcher: "", hooks: [{type: "command", command: $old}]}],
        PreCompact: [{matcher: "", hooks: [{type: "command", command: $old}]}]
    }}' > "$CLAUDE_SETTINGS_FILE"
cp "$CLAUDE_SETTINGS_FILE" "$TMP/original.json"

"$ROOT/adapters/claude-code/install-hooks.sh"
[ "$(count agent-status.sh)" = 0 ] || fail "old entries survived the migration"
[ "$(count hook.sh)" = "$(grep -cv '^#' "$ROOT/adapters/claude-code/hooks.map")" ] || fail "wrong number of new entries"
[ "$(count foreign)" = 1 ] || fail "foreign hook lost"
[ "$(jq -r '.theme' "$CLAUDE_SETTINGS_FILE")" = dark ] || fail "unrelated key lost"
[ "$(jq '.hooks.PreCompact // "gone"' "$CLAUDE_SETTINGS_FILE")" = '"gone"' ] || fail "stale event not removed"
[ "$(jq -r '.hooks.Notification[0].matcher' "$CLAUDE_SETTINGS_FILE")" = idle_prompt ] || fail "stale matcher not migrated"
jq -r '.hooks.Stop[-1].hooks[0].command' "$CLAUDE_SETTINGS_FILE" | grep -q -- '--label claude-work$' || fail "profile label missing"
cmp -s "$CLAUDE_SETTINGS_FILE.bak.tmux-agent-status" "$TMP/original.json" || fail "backup is not the original"

cp "$CLAUDE_SETTINGS_FILE" "$TMP/first.json"
"$ROOT/adapters/claude-code/install-hooks.sh"
cmp -s "$CLAUDE_SETTINGS_FILE" "$TMP/first.json" || fail "second install changed the file"

"$ROOT/adapters/claude-code/install-hooks.sh" --uninstall
[ "$(count hook.sh)" = 0 ] || fail "uninstall left entries"
[ "$(count foreign)" = 1 ] || fail "uninstall removed a foreign hook"

echo "ok: json hook install"
