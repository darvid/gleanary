#!/usr/bin/env bash
set -euo pipefail

# Packages the Developer ID app from `SIGNING=developer-id scripts/build-app.sh` into a signed
# disk image. Notarize it afterwards with scripts/notarize-app.sh.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="$root/.build/distribution"
app="$output_dir/Gleanary.app"
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
codesign --verify --deep --strict --verbose=2 "$app"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Invalid app version: %s\n' "$version" >&2
    exit 1
fi
if [[ "$(lipo -archs "$app/Contents/MacOS/Gleanary")" != arm64 ]]; then
    printf 'The release app must contain exactly the arm64 architecture\n' >&2
    exit 1
fi

stage="$(mktemp -d "$output_dir/dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Gleanary.app"
ln -s /Applications "$stage/Applications"
dmg="$output_dir/Gleanary-$version-arm64.dmg"
hdiutil create -ov -format UDZO -volname "Gleanary $version" -srcfolder "$stage" "$dmg"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
printf 'Signed DMG (not yet notarized): %s\n' "$dmg"
