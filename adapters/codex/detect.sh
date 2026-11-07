#!/usr/bin/env bash
# Exit 0 if codex appears usable on this machine.
set -euo pipefail

command -v codex >/dev/null 2>&1 && exit 0
exit 1
