#!/usr/bin/env bash
# Every picker row must keep its "|" separators in the same columns, however
# long the session names and [i/N] badges are. Uses a fake tmux, no server needed.
set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAKE_BIN="$(mktemp -d)"
trap 'rm -rf "$FAKE_BIN"' EXIT

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/bin/sh
[ "$1" = list-panes ] || exit 0
printf 'done\t1\tsystem-configuration-16:1.1\tnvim\tclaude\n'
printf 'done\t2\tAgents:1.1\tAgents\tclaude\n'
printf 'waiting\t3\tshort:1.1\tw\tclaude\n'
i=1; while [ "$i" -le 10 ]; do printf 'working\t4\tmany:%s.1\tw\tclaude\n' "$i"; i=$((i + 1)); done
EOF
chmod +x "$FAKE_BIN/tmux"

# The status icons differ in byte length, so measure only after the first " | ".
widths="$(PATH="$FAKE_BIN:$PATH" "$ROOT/core/agent-picker.sh" --list none | cut -f1 |
    awk '{ rest = substr($0, index($0, " | ") + 3); print index(rest, " | ") }' | sort -u)"

if [ "$(printf '%s\n' "$widths" | wc -l | tr -d ' ')" != "1" ]; then
    echo "FAIL: target column widths differ: $(echo "$widths" | tr '\n' ' ')"
    exit 1
fi
echo "ok: picker columns aligned"
