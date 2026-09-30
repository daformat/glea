#!/bin/bash
# Runs the Chrome-style feasibility harness (src/bridge/chrome_harness.mm) in a
# throwaway profile and opens its report. Output: build/chrome-harness/.
set -euo pipefail
cd "$(dirname "$0")/.."
ninja -C build >/dev/null
OUT=$PWD/build/chrome-harness
rm -rf "$OUT"; mkdir -p "$OUT"
GLEA_CHROME_HARNESS="$OUT" GLEA_PROFILE_DIR="$OUT/profile" GLEA_DATA_DIR="$OUT/data" GLEA_SUPPORT_DIR="$OUT/support" \
  build/Glea.app/Contents/MacOS/Glea 2>&1 | grep "HARNESS" || true
echo "Report: $OUT/report.html"
