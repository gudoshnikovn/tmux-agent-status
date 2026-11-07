#!/bin/sh
# fzf transform: keeps the cursor off session headings, which fzf can't make
# unselectable. Prints the action that moves on in the direction of travel.
# Usage: picker-skip-heading.sh <item index> <item target> <state file>
index="$1"
target="$2"
state="$3"

case "$target" in
    =*)
        last="$(cat "$state" 2>/dev/null || echo -1)"
        if [ "$index" -gt "$last" ] || [ "$index" -eq 0 ]; then
            echo down
        else
            echo up
        fi
        ;;
    *) printf '%s' "$index" > "$state" ;;
esac
