#!/bin/bash
# Detaches a mounted disk image reliably. Used by make_dmg.sh and smoke_test.sh.
#
# Usage: scripts/detach_image.sh DEVICE [MOUNTPOINT]      (DEVICE is /dev/diskN from hdiutil attach)
#
# On busy runners Spotlight (mds), Finder or a lagging process can keep the volume open for a
# few seconds, and a plain `hdiutil detach` then fails with "Resource busy". So: up to 8 plain
# attempts 3 s apart, then one with -force. A volume that is already gone counts as detached.
# On final failure, prints who still holds the volume (lsof) and exits 1.
set -uo pipefail

DEVICE="${1:?usage: detach_image.sh DEVICE [MOUNTPOINT]}"
MOUNTPOINT="${2:-}"

gone() { ! diskutil info "$DEVICE" >/dev/null 2>&1; }

sync
for attempt in 1 2 3 4 5 6 7 8; do
    if gone; then exit 0; fi
    if out="$(hdiutil detach "$DEVICE" 2>&1)"; then exit 0; fi
    echo "detach $DEVICE: attempt $attempt of 8 failed ($(tr '\n' ' ' <<< "$out")), retrying in 3 s" >&2
    sleep 3
done

if gone; then exit 0; fi
echo "detach $DEVICE: plain attempts failed, trying hdiutil detach -force" >&2
if out="$(hdiutil detach -force "$DEVICE" 2>&1)"; then exit 0; fi
sleep 2
if gone; then exit 0; fi

echo "error: cannot detach $DEVICE even with -force: $(tr '\n' ' ' <<< "$out")" >&2
if [[ -n "$MOUNTPOINT" ]]; then
    echo "processes that hold $MOUNTPOINT:" >&2
    lsof +D "$MOUNTPOINT" 2>&1 | head -20 >&2 || true
fi
exit 1
