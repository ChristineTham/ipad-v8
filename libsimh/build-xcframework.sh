#!/bin/bash
# Build SimhVAX.xcframework (open-simh vax780 as a static library) for
# iOS device arm64 + iOS simulator arm64, plus a macOS arm64 build of the
# vax780cli smoke-test harness. Clones open-simh if missing, pinned to the
# rev the A1 re-verification proved (V8 boots clean with noasync).
set -euo pipefail
cd "$(dirname "$0")"

SIMH_DIR="../work/opensimh"
SIMH_REPO="https://github.com/open-simh/simh.git"
SIMH_REV="a1f57fa3738ed31148d31126ba1a7278ff845c6d"   # verified 2026-08-09

if [ ! -d "$SIMH_DIR" ]; then
  git clone "$SIMH_REPO" "$SIMH_DIR"
  git -C "$SIMH_DIR" checkout "$SIMH_REV" || echo "warning: pinned rev checkout failed (shallow clone?); building HEAD" >&2
fi
ACTUAL=$(git -C "$SIMH_DIR" rev-parse HEAD)
[ "$ACTUAL" = "$SIMH_REV" ] || echo "warning: open-simh at $ACTUAL, not pinned $SIMH_REV" >&2

slice() {  # <slug> [extra cmake args...]
  local slug=$1; shift
  cmake -S . -B "build/$slug" -DCMAKE_BUILD_TYPE=Release "$@" > "build/cmake-$slug.log" 2>&1
  cmake --build "build/$slug" -j > "build/build-$slug.log" 2>&1
}

mkdir -p build
slice macos -DCMAKE_OSX_ARCHITECTURES=arm64
slice ios   -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
slice sim   -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
            -DCMAKE_OSX_SYSROOT=iphonesimulator \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY

mkdir -p dist
rm -rf dist/SimhVAX.xcframework
xcodebuild -create-xcframework \
  -library build/ios/libsimhvax.a -headers include \
  -library build/sim/libsimhvax.a -headers include \
  -output dist/SimhVAX.xcframework

echo "OK: dist/SimhVAX.xcframework (+ build/macos/vax780cli for desktop tests)"
