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

DMG=$DIST/Glea-$VERSION.dmg
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/Glea.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Glea" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
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
