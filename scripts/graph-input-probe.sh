#!/usr/bin/env bash
set -euo pipefail

# Build the release test bundle first with swift test -c release.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift_bin="$(xcrun -f swift)"
sdk="${SDKROOT:-$(xcrun --sdk macosx26.5 --show-sdk-path 2>/dev/null || xcrun --sdk macosx --show-sdk-path)}"
bundle="${1:?Pass the release GleanaryTests.xctest directory}"

# Invoke Swift directly: a protected xcrun process can strip DYLD settings.
export DYLD_FRAMEWORK_PATH="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks:$developer/Library/Frameworks"
export DYLD_LIBRARY_PATH="$developer/Platforms/MacOSX.platform/Developer/usr/lib:$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
exec "$swift_bin" -sdk "$sdk" "$project_dir/scripts/graph-input-probe.swift" "$bundle"
