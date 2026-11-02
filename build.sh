#!/bin/bash
# Builds build/TapKeys.app as a universal binary (Apple Silicon and Intel)
# with the Command Line Tools; no Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/TapKeys.app
SOURCES=(Sources/*.swift)
rm -rf "$APP" build/arm64 build/x86_64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O \
        -target "$arch-apple-macos13.0" \
        -import-objc-header Sources/MultitouchSupport.h \
        "${SOURCES[@]}" \
        -framework Cocoa -framework ServiceManagement -framework SwiftUI \
        -o "build/$arch"
done
lipo -create build/arm64 build/x86_64 -output "$APP/Contents/MacOS/TapKeys"
rm build/arm64 build/x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/TapKeys"))"
