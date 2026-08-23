#!/usr/bin/env bash
# Exit 0 if Claude Code appears usable on this machine.
set -euo pipefail

[ -d "$HOME/.claude" ] && exit 0
command -v claude >/dev/null 2>&1 && exit 0
exit 1
