#!/bin/bash
# Builds build/TapKeys-<version>.dmg from build/TapKeys.app with system tools only:
# hdiutil, osascript (Finder) and tiffutil. No create-dmg or dmgbuild.
#
# The window shows TapKeys on the left, an "Applications" shortcut on the right and
# an arrow between them, drawn on the background from Resources/dmg-background*.png.
# The background is light: Finder draws labels over a picture in black in any theme.
#
# Usage: scripts/make_dmg.sh [--update-template]
#
# Window layout has two sources:
#   finder    Finder is asked over osascript to arrange the window. Needs a logged in
#             GUI session and, on first run, the Automation permission for Finder
#             (System Settings -> Privacy & Security -> Automation). Retried 3 times.
#   template  scripts/dmg_layout.DS_Store, a Finder layout recorded once and kept in git.
#             No Finder involved, so it is deterministic and works in CI.
#
# DMG_LAYOUT picks the source: auto (default), finder or template.
#   auto      template in CI (the CI variable is set) when the template exists,
#             otherwise finder; if finder fails, falls back to the template.
# --update-template records a fresh template from the Finder layout. Run it after
# changing the window size, positions or background.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/TapKeys.app
VOLNAME=TapKeys
TEMPLATE=scripts/dmg_layout.DS_Store
# A folder of its own for every run (also holds the mount points), so that two runs never share a mount.
mkdir -p build
WORK="$(mktemp -d build/dmg-work.XXXXXX)"

# Layout in window points, measured from the top left corner of the window content.
# Keep in sync with scripts/make_dmg_background.swift.
WIN_W=600
WIN_H=400
TITLEBAR=28            # Finder bounds include the title bar; the toolbar is hidden
WIN_X=200
WIN_Y=120
ICON_SIZE=128
TEXT_SIZE=13
APP_POS_X=150
APP_POS_Y=185
APPS_POS_X=450
APPS_POS_Y=185

UPDATE_TEMPLATE=0
for arg in "$@"; do
    case "$arg" in
        --update-template) UPDATE_TEMPLATE=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done
LAYOUT="${DMG_LAYOUT:-auto}"
case "$LAYOUT" in auto|finder|template) ;; *) echo "DMG_LAYOUT must be auto, finder or template" >&2; exit 2 ;; esac
if [[ "$UPDATE_TEMPLATE" == 1 ]]; then LAYOUT=finder; fi

log() { echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

DEVICE=""
MOUNT=""
cleanup() {
    if [[ -n "$DEVICE" ]]; then
        hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# run_timeout SECONDS COMMAND...: macOS has no timeout(1); Finder can hang on a permission prompt.
run_timeout() {
    local secs=$1; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watcher=$!
    local rc=0
    wait "$pid" || rc=$?
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    return "$rc"
}

# Retries, then -force, and says who holds the volume when it still fails: see scripts/detach_image.sh
detach() {
    ./scripts/detach_image.sh "$DEVICE" "$MOUNT" || fail "cannot detach $DEVICE"
    DEVICE=""
}

# 1. The app: rebuild only when sources are newer than the binary.
BIN="$APP/Contents/MacOS/TapKeys"
if [[ ! -x "$BIN" ]] || [[ -n "$(find Sources Info.plist build.sh Resources/AppIcon.icns -type f -newer "$BIN" -print -quit)" ]]; then
    log "build/TapKeys.app is missing or older than the sources, running ./build.sh (about 4 minutes)"
    ./build.sh
else
    log "build/TapKeys.app is up to date, not rebuilding"
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ -n "$VERSION" ]] || fail "CFBundleShortVersionString is empty"
OUT="build/TapKeys-${VERSION}.dmg"
log "version $VERSION, output $OUT"

# 2. Background: PNGs from Resources, packed into one multi-resolution TIFF.
if [[ ! -f Resources/dmg-background.png || ! -f Resources/dmg-background@2x.png ]]; then
    log "rendering the background"
    swift scripts/make_dmg_background.swift
fi
mkdir -p "$WORK/staging/.background" "$WORK/tiff"
sips -s format tiff Resources/dmg-background.png    --out "$WORK/tiff/1x.tiff" >/dev/null
sips -s format tiff Resources/dmg-background@2x.png --out "$WORK/tiff/2x.tiff" >/dev/null
# -cathidpicheck joins 72 dpi and 144 dpi images into one TIFF and fails if the sizes do not match.
tiffutil -cathidpicheck "$WORK/tiff/1x.tiff" "$WORK/tiff/2x.tiff" -out "$WORK/staging/.background/background.tiff" >/dev/null 2>&1 \
    || fail "tiffutil could not join the background images"

# 3. Staging folder: app, Applications shortcut, volume icon.
ditto "$APP" "$WORK/staging/TapKeys.app"
ln -s /Applications "$WORK/staging/Applications"
# Tells Spotlight not to index the volume, from the first second it is mounted: mds holding the
# volume is the usual reason for "Resource busy" on detach. A hidden file, the window is unchanged.
touch "$WORK/staging/.metadata_never_index"

use_template=0
if [[ "$LAYOUT" == template ]]; then use_template=1; fi
if [[ "$LAYOUT" == auto && -n "${CI:-}" && -f "$TEMPLATE" ]]; then use_template=1; fi
if [[ "$use_template" == 1 ]]; then
    [[ -f "$TEMPLATE" ]] || fail "$TEMPLATE not found; run scripts/make_dmg.sh --update-template on a Mac with a GUI session"
    cp "$TEMPLATE" "$WORK/staging/.DS_Store"
    log "layout from the template $TEMPLATE"
fi

# 4. Read write image, sized from the staging folder plus room for .DS_Store and the filesystem.
# Finder arranges the window by the volume name, so only that mode needs /Volumes/TapKeys.
if [[ "$use_template" == 0 && -e "/Volumes/$VOLNAME" ]]; then
    fail "/Volumes/$VOLNAME is already mounted; eject it first"
fi
size_mb=$(( $(du -sk "$WORK/staging" | awk '{print $1}') * 2 / 1024 + 10 ))
# hdiutil create sometimes fails on busy CI runners ("Resource busy"), so it is retried.
created=0
for attempt in 1 2 3; do
    if hdiutil create -srcfolder "$WORK/staging" -volname "$VOLNAME" -fs HFS+ -format UDRW \
        -size "${size_mb}m" -ov "$WORK/rw.dmg" >/dev/null; then
        created=1
        break
    fi
    echo "attempt $attempt: hdiutil create failed, retrying" >&2
    rm -f "$WORK/rw.dmg"
    sleep 5
done
[[ "$created" == 1 ]] || fail "hdiutil create failed 3 times"
if [[ "$use_template" == 1 ]]; then
    # No Finder involved: a private mount point inside $WORK, hidden from Finder (-nobrowse).
    MOUNT="$WORK/mnt"
    mkdir -p "$MOUNT"
    DEVICE="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" | awk '/^\/dev\/disk/ {print $1; exit}')"
else
    MOUNT="/Volumes/$VOLNAME"
    DEVICE="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk '/^\/dev\/disk/ {print $1; exit}')"
fi
[[ -n "$DEVICE" ]] || fail "hdiutil attach returned no device"
[[ -d "$MOUNT" ]] || fail "$MOUNT did not appear after attach"
# Best effort, may need more rights than a user has: errors are ignored, .metadata_never_index is the main guard.
mdutil -i off "$MOUNT" >/dev/null 2>&1 || true

# 5. Layout through Finder.
finder_layout() {
    local right=$(( WIN_X + WIN_W ))
    local bottom=$(( WIN_Y + WIN_H + TITLEBAR ))
    cat > "$WORK/layout.applescript" <<EOF
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 1
        set theWindow to container window
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        set pathbar visible of theWindow to false
        set the bounds of theWindow to {$WIN_X, $WIN_Y, $right, $bottom}
        set viewOptions to the icon view options of theWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to $TEXT_SIZE
        set label position of viewOptions to bottom
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "TapKeys.app" of theWindow to {$APP_POS_X, $APP_POS_Y}
        set position of item "Applications" of theWindow to {$APPS_POS_X, $APPS_POS_Y}
        delay 1
        (* Setting the bounds a second time makes Finder store WindowBounds in .DS_Store;
           with a single early assignment the window opened at its default 920 x 472. *)
        set the bounds of theWindow to {$WIN_X, $WIN_Y, $right, $bottom}
        update without registering applications
        delay 3
        close
    end tell
end tell
EOF
    local attempt rc
    for attempt in 1 2 3; do
        rc=0
        run_timeout 60 osascript "$WORK/layout.applescript" >"$WORK/osa.out" 2>"$WORK/osa.err" || rc=$?
        if [[ "$rc" == 0 ]]; then
            # Finder writes .DS_Store a moment later.
            for _ in $(seq 1 20); do
                # WindowBounds is the sign that the window size was stored, not only the icon positions.
                if [[ -s "$MOUNT/.DS_Store" ]] && grep -aq WindowBounds "$MOUNT/.DS_Store"; then
                    sync; sleep 1; return 0
                fi
                sleep 1
            done
            echo "attempt $attempt: Finder finished but .DS_Store has no window bounds" >&2
        else
            echo "attempt $attempt: osascript failed (exit $rc): $(tr '\n' ' ' < "$WORK/osa.err")" >&2
            if grep -qE -- '-1743|not authorized|Not authorized' "$WORK/osa.err"; then
                echo "Finder has no Automation permission for this terminal. Open System Settings -> Privacy & Security -> Automation, enable Finder for your terminal app, and run again." >&2
            elif [[ "$rc" == 143 ]]; then
                echo "osascript did not answer in 60 s: a permission dialog may be waiting, or there is no GUI session." >&2
            fi
        fi
        osascript -e 'tell application "Finder" to close every window' >/dev/null 2>&1 || true
        sleep 3
    done
    return 1
}

if [[ "$use_template" == 0 ]]; then
    log "arranging the window through Finder"
    if finder_layout; then
        if [[ "$UPDATE_TEMPLATE" == 1 ]]; then
            cp "$MOUNT/.DS_Store" "$TEMPLATE"
            log "template saved to $TEMPLATE, commit it"
        fi
    elif [[ "$LAYOUT" == auto && -f "$TEMPLATE" ]]; then
        log "warning: Finder layout failed, using the template instead"
        cp "$TEMPLATE" "$MOUNT/.DS_Store"
    else
        fail "Finder layout failed (see messages above). Use DMG_LAYOUT=template if scripts/dmg_layout.DS_Store exists."
    fi
fi

# 6. Volume icon, compress and finish.
# Volume icon: the C flag on the volume root makes Finder use .VolumeIcon.icns.
# Done after the Finder layout: when it ran earlier, the file and the flag were gone from the finished image.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$MOUNT" || log "warning: SetFile failed, the volume keeps the default icon"
else
    log "warning: SetFile not found (Xcode Command Line Tools), the volume keeps the default icon"
fi

sync
detach
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null

# 7. Check the result: mounts, has the expected items.
hdiutil verify "$OUT" >/dev/null
CHECK="$WORK/check"
mkdir -p "$CHECK"
MOUNT="$CHECK"
DEVICE="$(hdiutil attach "$OUT" -readonly -nobrowse -noautoopen -mountpoint "$CHECK" | awk '/^\/dev\/disk/ {print $1; exit}')"
[[ -n "$DEVICE" ]] || fail "hdiutil attach of the finished DMG returned no device"
for item in TapKeys.app Applications .background/background.tiff .DS_Store; do
    [[ -e "$CHECK/$item" || -L "$CHECK/$item" ]] || { detach; fail "$item is missing in the finished DMG"; }
done
detach

log "done: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
