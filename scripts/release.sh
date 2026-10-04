#!/bin/bash
# Builds Glea and produces a Developer ID signed release in dist/:
# Glea.app (hardened runtime, timestamped), Glea-<version>.zip and .dmg.
#
#   scripts/release.sh                      sign with the first Developer ID
#   GLEA_SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh
#   Notarizes and staples with the "subtitles-notary" keychain profile (shared
#   with Layland and Subtitles); GLEA_NOTARY_PROFILE=<name> picks another,
#   GLEA_NOTARY_PROFILE= (empty) skips notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
NOTARY_PROFILE=${GLEA_NOTARY_PROFILE-subtitles-notary}

# Submits a file to Apple's notary service; prints the log if it's rejected.
notarize() {
  local result status id
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("status",""))' "$result")
  id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$result")
  echo "Notarization of $(basename "$1"): $status ($id)"
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
  fi
}
ENT=$ROOT/src/mac/entitlements

IDENTITY=${GLEA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}
[ -n "$IDENTITY" ] || { echo "No Developer ID Application identity found." >&2; exit 1; }
echo "Signing as: $IDENTITY"

cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
ninja -C build

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Glea.app/Contents/Info.plist)
DIST=$ROOT/dist
APP=$DIST/Glea.app
# (Finder may recreate .DS_Store while the folder is being deleted.)
rm -rf "$DIST" 2>/dev/null || rm -rf "$DIST"; mkdir -p "$DIST"
ditto build/Glea.app "$APP"
# Nothing but the bundle: drop stray build artefacts and extended attributes.
find "$APP" -name "*.d" -delete
xattr -cr "$APP"

sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }

# Inside out: framework libraries, the framework, helpers, then the app.
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
for lib in "$FW"/Libraries/*.dylib; do sign "$lib"; done
sign "$FW"
for helper in "$APP"/Contents/Frameworks/*Helper*.app; do
  case "$helper" in
    *"(Plugin)"*) sign --entitlements "$ENT/helper-plugin.plist" "$helper" ;;
    *) sign --entitlements "$ENT/helper.plist" "$helper" ;;
  esac
done
sign --entitlements "$ENT/app.plist" "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

ZIP=$DIST/Glea-$VERSION.zip
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing the app…"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
fi

# The disk image, laid out like Subtitles': a background with the drag-to-
# install arrow (scripts/makedmgbg.swift), the app and Applications on it.
DMG=$DIST/Glea-$VERSION.dmg
RWDMG=$DIST/Glea-rw.dmg
STAGE=$(mktemp -d)
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Glea.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/makedmgbg.swift "$STAGE/.background/background.tiff"

# A volume of this name already mounted (a run that died before detaching)
# makes hdiutil name the new one "Glea 1", and the layout would go to the
# stale one.
while read -r stale; do
  [ -n "$stale" ] || continue
  echo "Detaching stale volume: $stale"
  hdiutil detach "$stale" -quiet -force 2>/dev/null || true
done < <(mount | awk -F' on | \\(' '/\/Volumes\/Glea/ {print $2}')

# Read-write first: the window layout lives in the volume's .DS_Store, which
# only Finder writes, on a mounted writable image. The compressed image is
# converted from it at the end.
hdiutil create -volname "Glea" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RWDMG" >/dev/null
rm -rf "$STAGE"
MOUNT=$(hdiutil attach "$RWDMG" -readwrite -noverify -noautoopen | tail -1 | awk -F'\t' '{print $NF}')
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true' EXIT
VOLNAME=$(basename "$MOUNT")

# Coordinates match scripts/makedmgbg.swift (points, from the window's top
# left). Unquoted heredoc: no dollar sign, backslash or backtick below.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- The bounds include the title bar: 428 tall for a 400 point image.
    set the bounds of container window to {240, 130, 880, 558}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 12
    set background picture of opts to file ".background:background.tiff"
    set position of item "Glea.app" of container window to {170, 180}
    set position of item "Applications" of container window to {470, 180}
    -- Again after the contents change, or Finder falls back to its default width.
    set the bounds of container window to {240, 130, 880, 558}
    update without registering applications
    delay 1
    -- Closing is what commits .DS_Store.
    close
  end tell
end tell
APPLESCRIPT
then
  echo "Finder refused the layout script: allow your terminal to control Finder in" >&2
  echo "System Settings > Privacy & Security > Automation, then run this again." >&2
  exit 1
fi

# Finder writes .DS_Store lazily: detaching before it lands loses the layout.
sync
sleep 2
hdiutil detach "$MOUNT" -quiet
trap - EXIT
hdiutil convert "$RWDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" -ov >/dev/null
rm -f "$RWDMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ -n "$NOTARY_PROFILE" ]; then
  echo "Notarizing the disk image…"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

echo
spctl --assess --type execute --verbose=2 "$APP" 2>&1 || true
echo "Done: $APP"
echo "      $ZIP"
echo "      $DMG"
