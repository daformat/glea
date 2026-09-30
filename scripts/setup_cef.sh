#!/usr/bin/env bash
# Downloads the CEF binary distribution into third_party/cef and verifies its checksum.
set -euo pipefail
CEF_VERSION="${CEF_VERSION:-154.0.28+g564dd6c+chromium-154.0.8037.58}"
PLATFORM="${PLATFORM:-macosarm64}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/cef"

if [[ -f "$DEST/cmake/FindCEF.cmake" ]]; then
  echo "CEF already present in $DEST"
  exit 0
fi

NAME="cef_binary_${CEF_VERSION}_${PLATFORM}_minimal.tar.bz2"
URL="https://cef-builds.spotifycdn.com/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$NAME")"
EXPECTED=$(curl -sf https://cef-builds.spotifycdn.com/index.json | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next(f['sha1'] for v in d['$PLATFORM']['versions'] for f in v['files'] if f['name']=='$NAME'))")

mkdir -p "$ROOT/third_party"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading $NAME"
curl -fL --progress-bar -o "$TMP/cef.tar.bz2" "$URL"
ACTUAL=$(shasum "$TMP/cef.tar.bz2" | cut -d' ' -f1)
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "Checksum mismatch: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi
tar xjf "$TMP/cef.tar.bz2" -C "$TMP"
mv "$TMP"/cef_binary_*/ "$DEST"
echo "CEF installed in $DEST"
