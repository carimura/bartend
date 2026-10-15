#!/bin/bash
# Build Bartend.app and install it to /Applications (MenuBarAgent only honors
# allowlisted apps that LaunchServices resolves there).
set -euo pipefail
cd "$(dirname "$0")/.."

app="$(pwd)/build/Bartend.app"
mkdir -p "$app/Contents/MacOS" build/ModuleCache
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path build/ModuleCache \
    Sources/*.swift -o "$app/Contents/MacOS/Bartend" \
    -framework AppKit -framework ServiceManagement
cp Resources/Info.plist "$app/Contents/Info.plist"

# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc loses it.
identity="$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')"
codesign --force --sign "${identity:--}" "$app"

pkill -x Bartend || true
rm -rf /Applications/Bartend.app
cp -R "$app" /Applications/
printf 'Installed /Applications/Bartend.app (signed: %s)\n' "${identity:-ad-hoc}"
