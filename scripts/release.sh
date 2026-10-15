#!/bin/zsh
# Notarizes and staples a Developer ID signed NightKeys.app, packs it into the disk image, then notarizes and
# staples the disk image. The app gets its own ticket first, so it also opens offline after it is copied out of
# the disk image.
# Usage: scripts/release.sh <NightKeys.app> <output.dmg> <signing identity> <notarytool keychain profile>
set -euo pipefail

APP=$1
OUT=$2
IDENTITY=$3
PROFILE=$4

notarize() {
    local result id
    result=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1) || true
    print -r -- "$result"
    if ! print -r -- "$result" | grep -q "status: Accepted"; then
        id=$(print -r -- "$result" | awk '/^  id:/ {print $2; exit}')
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE"
        echo "Notarization of $1 failed." >&2
        exit 1
    fi
}

codesign --verify --strict --deep "$APP"

ZIP=$(dirname "$OUT")/NightKeys-notarize.zip
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarizing the app…"
notarize "$ZIP"
rm "$ZIP"
xcrun stapler staple "$APP"

./scripts/make-dmg.sh "$APP" "$OUT" "$IDENTITY"
echo "Notarizing the disk image…"
notarize "$OUT"
xcrun stapler staple "$OUT"

spctl --assess --type exec -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$OUT"
echo
echo "Release ready: $OUT"
echo "sha256: $(shasum -a 256 "$OUT" | awk '{print $1}')"
