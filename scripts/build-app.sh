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
swift build "${build_args[@]}" --product Infact
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

stage="$(mktemp -d "$project_dir/.build/infact-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/Infact.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/Infact" "$contents/MacOS/Infact"
for resource in "$bin_dir"/*.bundle; do
    [[ -d "$resource" ]] || continue
    ditto "$resource" "$contents/Resources/$(basename "$resource")"
done

plist="$contents/Info.plist"
cp Infact/Info.plist "$plist"
plutil -replace CFBundleIdentifier -string app.getinfact "$plist"
plutil -replace CFBundleExecutable -string Infact "$plist"
plutil -replace CFBundleName -string Infact "$plist"
plutil -replace CFBundlePackageType -string APPL "$plist"
plutil -replace CFBundleVersion -string 1 "$plist"
plutil -replace CFBundleShortVersionString -string 0.1 "$plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$plist"
plutil -replace NSHighResolutionCapable -bool YES "$plist"

codesign --force --sign - --entitlements Infact/Infact.entitlements "$stage/Infact.app"
codesign --verify --strict "$stage/Infact.app"

# Replace only the generated bundle; the sandboxed library is untouched.
rm -rf "$project_dir/.build/Infact.app"
mv "$stage/Infact.app" "$project_dir/.build/Infact.app"
printf 'Built %s\n' "$project_dir/.build/Infact.app"
