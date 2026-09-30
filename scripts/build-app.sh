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
swift build "${build_args[@]}" --product Sink
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"

stage="$(mktemp -d "$project_dir/.build/sink-app.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
contents="$stage/Sink.app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/Sink" "$contents/MacOS/Sink"
for resource in "$bin_dir"/*.bundle; do
    [[ -d "$resource" ]] || continue
    ditto "$resource" "$contents/Resources/$(basename "$resource")"
done

plist="$contents/Info.plist"
cp Sink/Info.plist "$plist"
plutil -replace CFBundleIdentifier -string dev.sink.app "$plist"
plutil -replace CFBundleExecutable -string Sink "$plist"
plutil -replace CFBundleName -string Sink "$plist"
plutil -replace CFBundlePackageType -string APPL "$plist"
plutil -replace CFBundleVersion -string 1 "$plist"
plutil -replace CFBundleShortVersionString -string 0.1 "$plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$plist"
plutil -replace NSHighResolutionCapable -bool YES "$plist"

codesign --force --sign - --entitlements Sink/Sink.entitlements "$stage/Sink.app"
codesign --verify --strict "$stage/Sink.app"

# Replace only the generated bundle; the sandboxed library is untouched.
rm -rf "$project_dir/.build/Sink.app"
mv "$stage/Sink.app" "$project_dir/.build/Sink.app"
printf 'Built %s\n' "$project_dir/.build/Sink.app"
