#!/bin/bash
# Builds CEF 154 (branch 8037, the commit Glea ships) with H.264 and AAC
# support where macOS does the decoding:
#   - H.264 video: VideoToolbox (Chromium's GPU-process decoder). FFmpeg's
#     video decoders are compiled out, and so are OpenH264 (encoding uses
#     VideoToolbox) and WebRTC's FFmpeg-based H.264 decoder.
#   - AAC audio (LC, HE-AAC v1/v2, xHE-AAC): AudioToolbox, in the GPU process.
#     0001-aac-audiotoolbox.patch widens Chromium's AudioToolbox decoder to all
#     AAC, derives each stream's output rate and channels from its
#     AudioSpecificConfig (FFmpeg's decoder used to report them), and lets Web
#     Audio's file reader use AudioToolbox too.
#   - 0002-ffmpeg-no-h264-aac-decoders.patch removes FFmpeg's H.264 and AAC
#     decoders from its "Chrome" configuration, and makes its ADTS (.aac)
#     reader fill in the rate, channels and frame size from the first header.
# FFmpeg still demuxes MP4/ADTS and decodes MP3, Vorbis, FLAC and PCM.
#   - 0003-renderer-sandbox-audiotoolbox.patch lets the renderer reach
#     AudioToolbox's AAC codec (the same two rules the GPU process has), for
#     Web Audio's decodeAudioData(). It slightly widens the renderer sandbox.
#
# usage: scripts/cef/build-cef.sh [checkout|patch|build|install]   (default: all)
# The work tree lives in $CEF_BUILD_DIR (default ~/dev/cef-build, ~100 GB).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GLEA=$(cd "$HERE/../.." && pwd)
WORK=${CEF_BUILD_DIR:-$HOME/dev/cef-build}
BRANCH=8037
COMMIT=564dd6c4aafff558154bd3176eb5d13551db6734
SRC=$WORK/chromium_git/chromium/src

export PATH=$WORK/depot_tools:$PATH
export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome \
enable_ffmpeg_video_decoders=false media_use_openh264=false rtc_use_h264=false"
export CEF_ARCHIVE_FORMAT=tar.bz2

automate() {
  python3 "$WORK/automate-git.py" --download-dir="$WORK/chromium_git" \
    --depot-tools-dir="$WORK/depot_tools" --branch=$BRANCH --checkout=$COMMIT \
    --arm64-build --no-chromium-history --with-pgo-profiles "$@"
}

checkout() {
  # Some Chromium dependencies (e.g. third_party/litert) are stored in Git LFS.
  command -v git-lfs >/dev/null || { echo "git-lfs is required: brew install git-lfs && git lfs install" >&2; exit 1; }
  mkdir -p "$WORK"
  [ -d "$WORK/depot_tools" ] || git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$WORK/depot_tools"
  curl -sfL "https://raw.githubusercontent.com/chromiumembedded/cef/$BRANCH/tools/automate/automate-git.py" -o "$WORK/automate-git.py"
  automate --no-build --no-distrib
}

patch_src() {
  for p in "$HERE"/*.patch; do
    case $(basename "$p") in 0002-*) dir=$SRC/third_party/ffmpeg ;; *) dir=$SRC ;; esac
    if git -C "$dir" apply --reverse --check "$p" 2>/dev/null; then
      echo "already applied: $(basename "$p")"
    else
      git -C "$dir" apply "$p" && echo "applied: $(basename "$p")"
    fi
  done
}

build() {
  # Xcode 26 ships the Metal compiler separately; ANGLE needs it.
  xcrun -f metal >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
  cd "$SRC/cef"
  GN_OUT_CONFIGS=Release_GN_arm64 ./cef_create_projects.sh
  autoninja -C "$SRC/out/Release_GN_arm64" cefsimple
  python3 tools/make_distrib.py --output-dir="$SRC/cef/binary_distrib" --arm64-build --ninja-build \
    --minimal --no-docs --no-symbols --no-archive
}

install() {
  local dist
  dist=$(ls -d "$WORK"/chromium_git/chromium/src/cef/binary_distrib/cef_binary_*_macosarm64_minimal | tail -1)
  rm -rf "$GLEA/third_party/cef"
  cp -R "$dist" "$GLEA/third_party/cef"
  echo "Installed $(basename "$dist") into third_party/cef. Rebuild Glea from a clean build directory."
}

case ${1:-all} in
  checkout) checkout ;;
  patch) patch_src ;;
  build) build ;;
  install) install ;;
  all) checkout; patch_src; build; install ;;
  *) echo "usage: $0 [checkout|patch|build|install]" >&2; exit 1 ;;
esac
