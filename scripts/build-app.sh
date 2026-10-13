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
swift build "${build_args[@]}" --product Infactory
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

stage="$(mktemp -d "$project_dir/.build/infactory-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/Infactory.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/Infactory" "$contents/MacOS/Infactory"
for resource in "$bin_dir"/*.bundle; do
    [[ -d "$resource" ]] || continue
    ditto "$resource" "$contents/Resources/$(basename "$resource")"
done

plist="$contents/Info.plist"
cp Infactory/Info.plist "$plist"
plutil -replace CFBundleIdentifier -string app.getinfactory "$plist"
plutil -replace CFBundleExecutable -string Infactory "$plist"
plutil -replace CFBundleName -string Infactory "$plist"
plutil -replace CFBundlePackageType -string APPL "$plist"
plutil -replace CFBundleVersion -string 1 "$plist"
plutil -replace CFBundleShortVersionString -string 0.1 "$plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$plist"
plutil -replace NSHighResolutionCapable -bool YES "$plist"

# Ad hoc by default. Ad hoc signatures change every build, so macOS treats each build as a new
# app and asks for Keychain access again. Set CODESIGN_IDENTITY (e.g. in .env) to a
# local signing certificate to keep a stable identity across rebuilds.
codesign --force --sign "${CODESIGN_IDENTITY:--}" \
    --entitlements Infactory/Infactory.entitlements "$stage/Infactory.app"
codesign --verify --strict "$stage/Infactory.app"

# Replace only the generated bundle; the sandboxed library is untouched.
rm -rf "$project_dir/.build/Infactory.app"
mv "$stage/Infactory.app" "$project_dir/.build/Infactory.app"
printf 'Built %s\n' "$project_dir/.build/Infactory.app"
