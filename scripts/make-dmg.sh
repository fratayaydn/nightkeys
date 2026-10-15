#!/bin/zsh
# Builds the NightKeys disk image with the usual drag-to-install window: the app on the left, an arrow, and a
# link to /Applications on the right.
# Usage: scripts/make-dmg.sh <NightKeys.app> <output.dmg> [signing identity]
# Finder lays out the window, so macOS may ask once to allow controlling Finder.
set -euo pipefail

APP=$1
OUT=$2
IDENTITY=${3:-}
VOL=NightKeys
WORK=$(dirname "$OUT")/dmg-work

rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/src/.background"

cp -R "$APP" "$WORK/src/"
ln -s /Applications "$WORK/src/Applications"
swift scripts/make-dmg-background.swift "$WORK"
swift scripts/make-volume-icon.swift "$WORK"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/src/.background/background.tiff"

# A volume with the same name would make Finder lay out the wrong window.
if [ -d "/Volumes/$VOL" ]; then hdiutil detach "/Volumes/$VOL" -quiet; fi

hdiutil create -quiet -volname "$VOL" -srcfolder "$WORK/src" -fs HFS+ -format UDRW -size 16m "$WORK/rw.dmg"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" | awk '/Apple_HFS/ {print $1}')
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "NightKeys.app" of container window to {160, 190}
        set position of item "Applications" of container window to {480, 190}
        close
        open
        -- Finder can drop the size set before the window is reopened, so set it again.
        set the bounds of container window to {200, 120, 840, 520}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Volume icon: added after the Finder layout, because Finder removes a .VolumeIcon.icns that is already there.
cp "$WORK/VolumeIcon.icns" "/Volumes/$VOL/.VolumeIcon.icns"
SetFile -a C "/Volumes/$VOL"

sync
rm -rf "/Volumes/$VOL/.fseventsd"
hdiutil detach "$DEV" -quiet
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$WORK"

if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$OUT"
fi
echo "Built $OUT"
