#!/usr/bin/env bash
# Exit 0 if opencode appears usable on this machine.
set -euo pipefail

command -v opencode >/dev/null 2>&1 && exit 0
exit 1
