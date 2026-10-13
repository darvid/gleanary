#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workspace"

# Restart only this workspace's app before replacing its generated bundle.
bash .superset/teardown.sh
bash scripts/build-app.sh

# Keep the Run pane attached until the native app exits. A separate instance
# avoids Launch Services reusing an app launched from another workspace.
trap 'bash "$workspace/.superset/teardown.sh"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
open -n -W "$workspace/.build/Infactory.app" &
wait "$!"
