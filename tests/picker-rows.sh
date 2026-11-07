#!/usr/bin/env bash
# Picker row contents and order, with fake tmux and ps.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/tmux" <<'FAKE'
#!/bin/sh
case "$1" in
list-panes)
    t="$(printf '\t')"
    cat <<ROWS
done${t}100${t}seen:1.1${t}w${t}claude${t}1${t}${t}/dev/ttys001
done${t}200${t}fresh:1.1${t}w${t}claude${t}${t}${t}/dev/ttys002
waiting${t}300${t}ask:1.1${t}w${t}claude${t}${t}permission: Bash${t}/dev/ttys003
working${t}400${t}busy:1.1${t}w${t}claude${t}${t}${t}/dev/ttys004
${t}${t}nohook:1.1${t}w${t}opencode${t}${t}${t}/dev/ttys005
${t}${t}wrapped:1.1${t}w${t}node${t}${t}${t}/dev/ttys006
${t}${t}plain:1.1${t}w${t}zsh${t}${t}${t}/dev/ttys007
${t}${t}back:1.1${t}w${t}zsh${t}${t}${t}/dev/ttys008
ROWS
    ;;
esac
FAKE
cat > "$TMP/ps" <<'FAKE'
#!/bin/sh
cat <<PROCS
ttys005  S+   /home/me/.opencode/bin/opencode
ttys006  S+   node /usr/local/bin/gemini --flag
ttys007  S+   grep opencode
ttys008  S    opencode
ttys004  S+   claude
PROCS
FAKE
chmod +x "$TMP/tmux" "$TMP/ps"

out="$(PATH="$TMP:$PATH" "$ROOT/core/agent-picker.sh" --list none | cut -f1 | sed $'s/\033\\[[0-9;]*m//g')"
fail() { echo "FAIL: $1"; printf '%s\n' "$out"; exit 1; }

order="$(printf '%s\n' "$out" | sed -E 's/.* \| ([a-z]+):.*/\1/' | tr '\n' ' ')"
case "$order" in
    "ask busy fresh seen "*) ;;
    *) fail "wrong order: $order" ;;
esac
printf '%s\n' "$out" | grep -q 'ask:1.1.* · permission: Bash' || fail "message missing"
printf '%s\n' "$out" | grep -q '💤 idle .*seen:1.1' || fail "seen pane not shown as idle"
printf '%s\n' "$out" | grep -q '✅ done .*fresh:1.1' || fail "unseen pane not shown as done"
printf '%s\n' "$out" | grep -q '○ no hooks.*nohook:1.1.*(opencode)' || fail "agent without hooks missing"
printf '%s\n' "$out" | grep -q '○ no hooks.*wrapped:1.1.*(gemini)' || fail "runtime-wrapped agent missing"
printf '%s\n' "$out" | grep -q 'plain:1.1' && fail "grep opencode is not an agent"
printf '%s\n' "$out" | grep -q 'back:1.1' && fail "background process is not the pane's agent"
echo "ok: picker rows"
