#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
executable="$workspace/.build/Gleanary.app/Contents/MacOS/Gleanary"

# Match the executable path, never the shared app name or bundle ID.
while read -r pid command; do
    [[ "$command" == "$executable" ]] || continue
    kill -TERM "$pid" 2>/dev/null || continue
    for ((attempt = 0; attempt < 50; attempt++)); do
        current="$(ps -ww -p "$pid" -o comm= 2>/dev/null || true)"
        [[ "$current" == "$executable" ]] || break
        sleep 0.2
    done
    if [[ "$current" == "$executable" ]]; then
        printf 'Gleanary did not stop. Quit this workspace app and retry.\n' >&2
        exit 1
    fi
done < <(ps -axww -o pid=,comm=)
