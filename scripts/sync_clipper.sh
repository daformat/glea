#!/usr/bin/env bash
# Copies Glea Clipper's Safari files from a glea-extensions checkout beside this
# one into src/clipper/Resources, where the build bundles them into
# Glea.app/Contents/PlugIns/Glea Clipper.appex. The point-and-shoot script
# isn't copied: the build puts Glea's own src/resources/content-script.js in.
#
#   scripts/sync_clipper.sh [path/to/glea-extensions]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="${1:-$ROOT/../glea-extensions}"
[ -x "$EXT/scripts/build.sh" ] || { echo "No glea-extensions checkout at $EXT" >&2; exit 1; }
"$EXT/scripts/build.sh" safari-files >/dev/null
DEST="$ROOT/src/clipper/Resources"
rm -rf "$DEST"
mkdir -p "$DEST"
rsync -a --exclude vendor --exclude '.*' "$EXT/dist/safari/" "$DEST/"
echo "Glea Clipper $(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$DEST/manifest.json") synced from $EXT ($(git -C "$EXT" rev-parse --short HEAD))"
