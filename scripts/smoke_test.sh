#!/bin/bash
# Smoke test of the packaged files, as a user would meet them.
#
# Usage: scripts/smoke_test.sh [DIR]     (DIR defaults to build; run scripts/package.sh first)
#
# Checks, in this order:
#   1. SHA256SUMS matches the zip and the DMG
#   2. DMG: hdiutil verify, mounts read only, has TapKeys.app, the Applications link, the background
#   3. the app inside the DMG: Info.plist, ad hoc signature (codesign --verify --deep --strict),
#      both architectures (lipo), minimum macOS 13.0 in each slice (vtool), --selftest runs
#   4. zip: one top level TapKeys.app, no __MACOSX, same signature checks, binary identical to the DMG one
# Nothing is installed: images are mounted and archives unpacked into a temporary folder.
set -euo pipefail

DIST="${1:-build}"
DIST="$(cd "$DIST" && pwd)"

log() { echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

TMP="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/tapkeys-smoke.XXXXXX")"
DEVICE=""
MOUNT=""
cleanup() {
    if [[ -n "$DEVICE" ]]; then hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true; fi
    rm -rf "$TMP"
}
trap cleanup EXIT

one_file() { # one_file GLOB: prints the single match or fails
    local matches=()
    local f
    for f in $1; do [[ -e "$f" ]] && matches+=("$f"); done
    [[ ${#matches[@]} -eq 1 ]] || fail "expected exactly one file matching $1, found ${#matches[@]}"
    echo "${matches[0]}"
}
DMG="$(one_file "$DIST/TapKeys-*.dmg")"
ZIP="$(one_file "$DIST/TapKeys-v*.zip")"
[[ -f "$DIST/SHA256SUMS" ]] || fail "$DIST/SHA256SUMS not found"

# check_app APP LABEL: signature, architectures, deployment target, selftest
check_app() {
    local app=$1 label=$2 bin="$1/Contents/MacOS/TapKeys" arch out
    [[ -x "$bin" ]] || fail "$label: $bin is missing or not executable"
    codesign --verify --deep --strict --verbose=2 "$app" || fail "$label: codesign verification failed"
    local archs
    archs="$(lipo -archs "$bin")"
    log "$label: architectures: $archs"
    # Exactly the two slices, in any order.
    [[ "$(tr ' ' '\n' <<< "$archs" | sort | tr '\n' ' ')" == "arm64 x86_64 " ]] \
        || fail "$label: expected the architectures arm64 and x86_64, lipo -archs says: $archs"
    for arch in x86_64 arm64; do
        # vtool prints "minos 13.0" for the slice: the app must still start on macOS 13.
        vtool -arch "$arch" -show-build "$bin" | grep -Eq '^ *minos 13\.0$' \
            || fail "$label: $arch slice does not target macOS 13.0"
    done
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" == "13.0" ]] \
        || fail "$label: LSMinimumSystemVersion is not 13.0"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "io.github.scharfff.tapkeys" ]] \
        || fail "$label: unexpected CFBundleIdentifier"
    # The selftest runs the binary of the running machine's architecture, without creating event taps.
    # perl alarm is the timeout: macOS has no timeout(1) and a hung start must not hang the job.
    out="$TMP/selftest.out"
    perl -e 'alarm 60; exec @ARGV' "$bin" --selftest >"$out" 2>&1 || { cat "$out" >&2; fail "$label: --selftest failed or timed out"; }
    cat "$out"
    grep -q '^trackpads found:' "$out" || fail "$label: --selftest printed no trackpad line"
    grep -q '^bindings:' "$out" || fail "$label: --selftest printed no bindings line"
}

log "checksums"
(cd "$DIST" && shasum -a 256 -c SHA256SUMS) || fail "SHA256SUMS does not match the files"
for name in "$(basename "$ZIP")" "$(basename "$DMG")"; do
    grep -q "$name" "$DIST/SHA256SUMS" || fail "SHA256SUMS does not list $name"
done

log "DMG: hdiutil verify"
hdiutil verify "$DMG" >/dev/null || fail "hdiutil verify failed for $DMG"

log "DMG: mount read only"
MOUNT="$TMP/mnt"
mkdir -p "$MOUNT"
DEVICE="$(hdiutil attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" | awk '/^\/dev\/disk/ {print $1; exit}')"
[[ -n "$DEVICE" ]] || fail "hdiutil attach returned no device"
for item in TapKeys.app Applications .background/background.tiff .DS_Store; do
    [[ -e "$MOUNT/$item" || -L "$MOUNT/$item" ]] || fail "$item is missing in the DMG"
done
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "the Applications link does not point to /Applications"
check_app "$MOUNT/TapKeys.app" "dmg"
cp "$MOUNT/TapKeys.app/Contents/MacOS/TapKeys" "$TMP/dmg-binary"
"$(dirname "$0")/detach_image.sh" "$DEVICE" "$MOUNT" || fail "cannot detach $DEVICE"
DEVICE=""

log "zip: unpack"
UNZIP="$TMP/unzip"
mkdir -p "$UNZIP"
top="$(zipinfo -1 "$ZIP" | cut -d/ -f1 | sort -u)"
[[ "$top" == "TapKeys.app" ]] || fail "the zip must contain only TapKeys.app at the top level, found: $top"
ditto -x -k "$ZIP" "$UNZIP"
check_app "$UNZIP/TapKeys.app" "zip"
cmp -s "$UNZIP/TapKeys.app/Contents/MacOS/TapKeys" "$TMP/dmg-binary" || fail "the zip and the DMG contain different binaries"

log "smoke test passed: $(basename "$DMG"), $(basename "$ZIP")"
