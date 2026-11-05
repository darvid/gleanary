#!/usr/bin/env bash
set -euo pipefail

# Submits the signed DMG to Apple, then staples the ticket and writes SHA256SUMS. Store the
# credentials once with `xcrun notarytool store-credentials gleanary-notary`, or set
# NOTARY_PROFILE to another profile name.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$root/.build/distribution"
app="$output_dir/Gleanary.app"
profile="${NOTARY_PROFILE:-gleanary-notary}"
auth_args=(--keychain-profile "$profile")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    auth_args+=(--keychain "$NOTARY_KEYCHAIN")
fi
submission="$output_dir/notarization.json"
log="$output_dir/notarization-log.json"

if [[ ! -d "$app" ]]; then
    printf 'Build the Developer ID app with mise run signed-app first\n' >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
dmg="$output_dir/Gleanary-$version-arm64.dmg"
if [[ ! -f "$dmg" ]]; then
    printf 'Build the disk image with mise run dmg first\n' >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$dmg"

# Apple checks the signed app inside the final signed disk image.
printf 'Submitting to Apple using Keychain profile: %s\n' "$profile"
submission_exit=0
xcrun notarytool submit "$dmg" "${auth_args[@]}" \
    --wait --output-format json > "$submission" || submission_exit=$?

submission_id="$(plutil -extract id raw -o - "$submission" 2>/dev/null || true)"
status="$(plutil -extract status raw -o - "$submission" 2>/dev/null || true)"
if [[ -n "$submission_id" ]]; then
    printf 'Submission: %s (%s)\n' "$submission_id" "$status"
    xcrun notarytool log "$submission_id" "${auth_args[@]}" "$log"
    printf 'Notarization log: %s\n' "$log"
fi
if [[ "$submission_exit" != 0 || "$status" != Accepted ]]; then
    printf 'Notarization was not accepted. Details: %s\n' "$submission" >&2
    exit 1
fi

xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
# Record the hash only after stapling has finished changing the file.
cd "$output_dir"
shasum -a 256 "$(basename "$dmg")" > SHA256SUMS
printf 'Notarized release: %s\n' "$dmg"
