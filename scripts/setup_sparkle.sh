#!/usr/bin/env bash
# Downloads Sparkle (the updater, https://sparkle-project.org) into
# third_party/sparkle and verifies its checksum: Sparkle.framework, linked into
# the app, and bin/ (generate_keys, generate_appcast), used by release.sh.
set -euo pipefail
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/third_party/sparkle"

if [[ -f "$DEST/VERSION" && "$(cat "$DEST/VERSION")" == "$SPARKLE_VERSION" ]]; then
  echo "Sparkle $SPARKLE_VERSION already present in $DEST"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Sparkle $SPARKLE_VERSION"
curl -fL --progress-bar -o "$TMP/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
ACTUAL=$(shasum -a 256 "$TMP/sparkle.tar.xz" | cut -d' ' -f1)
if [[ "$ACTUAL" != "$SPARKLE_SHA256" ]]; then
  echo "Checksum mismatch: expected $SPARKLE_SHA256, got $ACTUAL" >&2
  exit 1
fi
mkdir -p "$TMP/x"
tar xf "$TMP/sparkle.tar.xz" -C "$TMP/x"
rm -rf "$DEST"
mkdir -p "$DEST"
mv "$TMP/x/Sparkle.framework" "$TMP/x/bin" "$TMP/x/LICENSE" "$DEST/"
echo "$SPARKLE_VERSION" > "$DEST/VERSION"
echo "Sparkle installed in $DEST"
