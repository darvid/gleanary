#!/usr/bin/env bash
set -euo pipefail

workspace="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$workspace"
root="${SUPERSET_ROOT_PATH:?Superset must set SUPERSET_ROOT_PATH to the main checkout}"
root="$(cd "$root" && pwd)"

# Copy only untracked root env files; preserve workspace edits on reruns.
shopt -s nullglob
for source in "$root"/.env "$root"/.env.*; do
    [[ -f "$source" ]] || continue
    name="$(basename "$source")"
    if git -C "$root" ls-files --error-unmatch -- "$name" >/dev/null 2>&1; then
        continue
    fi
    [[ ! -e "$workspace/$name" && ! -L "$workspace/$name" ]] || continue
    (umask 077; cp "$source" "$workspace/$name")
    chmod go-rwx "$workspace/$name"
    printf 'Copied %s from the main checkout\n' "$name"
done

# Do not install repository hooks: worktrees share them with the checkout.
swift package --force-resolved-versions resolve