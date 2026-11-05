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

version="$(< version.txt)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'version.txt must contain a major.minor.patch version\n' >&2
    exit 1
fi

# SIGNING=local (the default) builds .build/Gleanary.app for development. SIGNING=developer-id
# builds the arm64 release app in .build/distribution, signed for notarization.
signing="${SIGNING:-local}"
configuration="${CONFIGURATION:-debug}"
output_dir="$project_dir/.build"
build_args=(--sdk "$sdk")
case "$signing" in
    local) ;;
    developer-id)
        : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
        if [[ "$SIGNING_IDENTITY" != "Developer ID Application: "* ]]; then
            printf 'SIGNING_IDENTITY must be a Developer ID Application identity\n' >&2
            exit 1
        fi
        configuration=release
        output_dir="$project_dir/.build/distribution"
        build_args+=(--arch arm64)
        ;;
    *)
        printf 'SIGNING must be local or developer-id\n' >&2
        exit 1
        ;;
esac
if [[ "$configuration" != debug && "$configuration" != release ]]; then
    printf 'CONFIGURATION must be debug or release\n' >&2
    exit 1
fi
build_args+=(--configuration "$configuration")
mkdir -p "$output_dir"
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
plutil -replace CFBundleVersion -string "$version" "$plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$plist"
plutil -replace NSHighResolutionCapable -bool YES "$plist"

# The neutral accent. macOS applies it only while System Settings' accent is Multicolor, so someone
# who chose an accent keeps it. actool ships with Xcode, not the Command Line Tools.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool Gleanary/Assets.xcassets --compile "$contents/Resources" --platform macosx \
        --minimum-deployment-target 26.0 --accent-color AccentColor \
        --output-partial-info-plist "$stage/assets.plist" >/dev/null
    plutil -replace NSAccentColorName -string AccentColor "$plist"
elif [[ "$signing" == developer-id ]]; then
    printf 'actool not found: release builds need Xcode for the accent color\n' >&2
    exit 1
else
    printf 'actool not found: building without the neutral accent\n' >&2
fi
cp LICENSE "$contents/Resources/LICENSE"

# Ad hoc by default. Ad hoc signatures change every build, so macOS treats each build as a new
# app and asks for Keychain access again. Set CODESIGN_IDENTITY (e.g. in .env) to a
# local signing certificate to keep a stable identity across rebuilds.
if [[ "$signing" == developer-id ]]; then
    # Notarization requires the hardened runtime and a secure timestamp.
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" \
        --entitlements Gleanary/Gleanary.entitlements "$stage/Gleanary.app"
else
    codesign --force --sign "${CODESIGN_IDENTITY:--}" \
        --entitlements Gleanary/Gleanary.entitlements "$stage/Gleanary.app"
fi
codesign --verify --deep --strict "$stage/Gleanary.app"

# Replace only the generated bundle; the sandboxed library is untouched.
rm -rf "$output_dir/Gleanary.app"
mv "$stage/Gleanary.app" "$output_dir/Gleanary.app"
printf 'Built %s\n' "$output_dir/Gleanary.app"
