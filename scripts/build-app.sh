#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"

# Prefer the tested SDK: some newer CLT SDKs lack the SwiftUI macro plugin.
# SDKROOT can select another installed SDK explicitly.
sdk="${SDKROOT:-}"
if [[ -z "$sdk" ]]; then
    sdk="$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx --show-sdk-path)"
fi

configuration="${CONFIGURATION:-debug}"
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    printf 'CONFIGURATION must be debug or release\n' >&2
    exit 1
fi
build_args=(--configuration "$configuration" --sdk "$sdk")
swift build "${build_args[@]}" --product Gleanary
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

stage="$(mktemp -d "$project_dir/.build/gleanary-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/Gleanary.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/Gleanary" "$contents/MacOS/Gleanary"
for resource in "$bin_dir"/*.bundle; do
    [[ -d "$resource" ]] || continue
    ditto "$resource" "$contents/Resources/$(basename "$resource")"
done
# Info.plist names it in CFBundleIconFile. AppIcon.iconset beside it is the editable source;
# rebuild the .icns with `iconutil -c icns Gleanary/AppIcon/AppIcon.iconset`.
cp Gleanary/AppIcon/AppIcon.icns "$contents/Resources/AppIcon.icns"

plist="$contents/Info.plist"
cp Gleanary/Info.plist "$plist"
plutil -replace CFBundleIdentifier -string app.gleanary "$plist"
plutil -replace CFBundleExecutable -string Gleanary "$plist"
plutil -replace CFBundleName -string Gleanary "$plist"
plutil -replace CFBundlePackageType -string APPL "$plist"
plutil -replace CFBundleVersion -string 1 "$plist"
plutil -replace CFBundleShortVersionString -string 0.1 "$plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$plist"
plutil -replace NSHighResolutionCapable -bool YES "$plist"

# The neutral accent. macOS applies it only while System Settings' accent is Multicolor, so someone
# who chose an accent keeps it. actool ships with Xcode, not the Command Line Tools.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Gleanary/Assets.xcassets --compile "$contents/Resources" --platform macosx \
        --minimum-deployment-target 26.0 --accent-color AccentColor \
        --output-partial-info-plist "$stage/assets.plist" >/dev/null
    plutil -replace NSAccentColorName -string AccentColor "$plist"
else
    printf 'actool not found: building without the neutral accent\n' >&2
fi

# Ad hoc by default. Ad hoc signatures change every build, so macOS treats each build as a new
# app and asks for Keychain access again. Set CODESIGN_IDENTITY (e.g. in .env) to a
# local signing certificate to keep a stable identity across rebuilds.
codesign --force --sign "${CODESIGN_IDENTITY:--}" \
    --entitlements Gleanary/Gleanary.entitlements "$stage/Gleanary.app"
codesign --verify --strict "$stage/Gleanary.app"

# Replace only the generated bundle; the sandboxed library is untouched.
rm -rf "$project_dir/.build/Gleanary.app"
mv "$stage/Gleanary.app" "$project_dir/.build/Gleanary.app"
printf 'Built %s\n' "$project_dir/.build/Gleanary.app"
