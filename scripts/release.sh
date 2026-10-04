#!/bin/bash
# Builds Glea and produces a Developer ID signed release in dist/:
# Glea.app (hardened runtime, timestamped), Glea-<version>.zip and .dmg, then
# publishes it as an update: the DMG, the zip and the appcast on a GitHub
# release of daformat/glea, whose latest appcast glea.app/appcast.xml
# serves (Updater.swift). GLEA_PUBLISH=0 stops before publishing.
#
# Release notes are the body of the "Glea <version>" commit (its "- " items).
# The appcast is signed with the Sparkle key in the login keychain (account
# "glea", made by third_party/sparkle/bin/generate_keys - -account glea).
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
PUBLISH=${GLEA_PUBLISH:-1}
REPO=daformat/glea
FEED_URL=https://glea.app/appcast.xml
SPARKLE_BIN=$ROOT/third_party/sparkle/bin

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
# Sparkle's two executables that run outside the app, then the framework.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
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
echo "Built: $APP"
echo "       $ZIP"
echo "       $DMG"

[ "$PUBLISH" = 1 ] || { echo "GLEA_PUBLISH=0: not published."; exit 0; }
[ -n "$NOTARY_PROFILE" ] || { echo "Not notarized: not published." >&2; exit 1; }

# The appcast: generate_appcast signs the zip with the keychain key and adds
# an entry for it to the previous release's appcast (brought down first, so
# older entries stay). The notes, embedded, are what "Check for Updates…"
# shows.
TAG="v$VERSION"
FEED=$DIST/feed
rm -rf "$FEED"; mkdir -p "$FEED"
cp "$ZIP" "$FEED/"
NOTES_COMMIT=$(git log -1 --format=%H --grep="^Glea $VERSION\$")
[ -n "$NOTES_COMMIT" ] || { echo "No \"Glea $VERSION\" commit for the release notes." >&2; exit 1; }
git log -1 --format=%b "$NOTES_COMMIT" | python3 -c '
import html, re, sys
version = sys.argv[1]
items, current = [], None
for line in sys.stdin.read().splitlines():
    if line.startswith("Co-Authored-By:"):
        break
    if line.startswith("- "):
        current = [line[2:].strip()]
        items.append(current)
    elif current is not None and line.strip():
        current.append(line.strip())
def render(text):
    text = html.escape(text, quote=False)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
print("<h2>Glea %s</h2>" % version)
print("<ul>" + "".join("<li>%s</li>" % render(" ".join(i)) for i in items) + "</ul>")
' "$VERSION" > "$FEED/Glea-$VERSION.html"
if gh release download -R "$REPO" -p appcast.xml -D "$FEED" 2>/dev/null; then
  echo "Previous appcast: $(grep -c '<item>' "$FEED/appcast.xml") entries"
else
  echo "No previous release: a new appcast"
fi
"$SPARKLE_BIN/generate_appcast" --account glea \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link https://glea.app --embed-release-notes "$FEED"
grep -q "sparkle:version>$VERSION<" "$FEED/appcast.xml" || { echo "The appcast has no entry for $VERSION." >&2; exit 1; }

# The release: a draft with every asset, published once they're all up (a
# check landing in between would be offered a zip that isn't there yet). The
# DMG also goes up as Glea.dmg, for a download link that never changes.
STABLE_DMG=$DIST/Glea.dmg
cp "$DMG" "$STABLE_DMG"
# The tag first, on the release commit and pushed with it: the appcast points
# at a URL with the tag's name in it.
git push origin "$NOTES_COMMIT:refs/heads/main" 2>/dev/null || git push origin HEAD:main
git tag -a "$TAG" -m "Glea $VERSION" "$NOTES_COMMIT" 2>/dev/null || echo "Tag $TAG already exists."
git push origin "$TAG"
NOTES_MD=$DIST/notes.md
git log -1 --format=%b "$NOTES_COMMIT" | sed '/^Co-Authored-By:/,$d' > "$NOTES_MD"
gh release create "$TAG" -R "$REPO" --draft --verify-tag --title "Glea $VERSION" --notes-file "$NOTES_MD" \
  "$STABLE_DMG" "$DMG" "$ZIP" "$FEED/appcast.xml"
ASSETS=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')
for want in Glea.dmg "Glea-$VERSION.dmg" "Glea-$VERSION.zip" appcast.xml; do
  grep -qx "$want" <<<"$ASSETS" || { echo "Missing from the draft: $want" >&2; exit 1; }
done
gh release edit "$TAG" -R "$REPO" --draft=false --latest

# What every installed copy sees (GitHub takes a moment to move "latest").
for attempt in $(seq 1 12); do
  if curl -fsSL "$FEED_URL" | grep -q "sparkle:version>$VERSION<"; then
    echo "$FEED_URL offers $VERSION"
    break
  fi
  [ "$attempt" = 12 ] && { echo "$FEED_URL doesn't offer $VERSION yet: check glea.app's /appcast.xml rule." >&2; exit 1; }
  sleep 5
done
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
