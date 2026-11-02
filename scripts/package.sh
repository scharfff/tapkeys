#!/bin/bash
# Packages build/TapKeys.app into the release files, the same way for CI and for a release:
#   build/TapKeys-v<version>.zip   what the Homebrew cask downloads
#   build/TapKeys-<version>.dmg    drag to Applications installer (scripts/make_dmg.sh)
#   build/SHA256SUMS               checksums of both files
# <version> is CFBundleShortVersionString from the app's Info.plist.
# RELEASE_TAG (optional, set by release.yml) names the zip after the tag instead, because the cask
# and the release page use the tag: for a pre-release the tag v0.2.0-rc1 gives TapKeys-v0.2.0-rc1.zip
# while the DMG stays TapKeys-0.2.0.dmg. The tag must be v<version> or v<version>-<suffix>.
#
# Usage: scripts/package.sh        (run ./build.sh first)
# DMG_LAYOUT is passed on to make_dmg.sh: CI and releases set DMG_LAYOUT=template.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/TapKeys.app
[[ -d "$APP" ]] || { echo "error: $APP not found, run ./build.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ -n "$VERSION" ]] || { echo "error: CFBundleShortVersionString is empty" >&2; exit 1; }

TAG="${RELEASE_TAG:-v${VERSION}}"
if [[ "$TAG" != "v${VERSION}" && "$TAG" != "v${VERSION}-"* ]]; then
    echo "error: RELEASE_TAG '$TAG' does not match Info.plist version '$VERSION' (expected v${VERSION} or v${VERSION}-suffix)" >&2
    exit 1
fi
ZIP="TapKeys-${TAG}.zip"
DMG="TapKeys-${VERSION}.dmg"
rm -f build/TapKeys-v*.zip build/TapKeys-*.dmg build/SHA256SUMS

echo "==> zip $ZIP"
ditto -c -k --keepParent "$APP" "build/$ZIP"

echo "==> dmg $DMG"
./scripts/make_dmg.sh

[[ -f "build/$DMG" ]] || { echo "error: build/$DMG was not produced" >&2; exit 1; }

echo "==> SHA256SUMS"
# Relative file names, so that `shasum -a 256 -c` and `sha256sum -c` work from the same folder.
(cd build && shasum -a 256 "$ZIP" "$DMG" > SHA256SUMS && cat SHA256SUMS)
