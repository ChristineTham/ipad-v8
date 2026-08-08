#!/bin/bash
# Build DmdCore.xcframework from dmd_core's own staticlib (the crate ships
# a C FFI; we add two BREAK exports via patch) for iOS device arm64 + iOS
# simulator arm64, plus a macOS arm64 build and smoke test. Clones the
# canonical dmd_core (git.loomcom.com — GitHub mirror is stale) pinned to
# the A0-verified rev and applies the spike + A2 patches when missing.
set -euo pipefail
cd "$(dirname "$0")"

DMD_DIR="../work/dmd_core_loomcom"
DMD_REPO="https://git.loomcom.com/seth/dmd_core.git"
DMD_REV="ee222b68db8a7adc4d29a9d23c12e2ecb893f88e"   # canonical 0.7.1: reset(1) = 8;7;3
PATCH_DIR="$(cd ../tools/dmdbridge/patches && pwd)"

if [ ! -d "$DMD_DIR" ]; then
  git clone "$DMD_REPO" "$DMD_DIR"
  git -C "$DMD_DIR" checkout "$DMD_REV"
  for p in dmd_core-spike-patches.diff dmd_core-a2-ffi-break.diff; do
    git -C "$DMD_DIR" apply "$PATCH_DIR/$p" \
      || { echo "error: $p failed to apply" >&2; exit 1; }
  done
  echo "cloned + patched dmd_core at $DMD_REV"
fi

for target in aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin; do
  echo "== cargo build --release --target $target"
  cargo build --manifest-path "$DMD_DIR/Cargo.toml" --release --target "$target" \
    > "build-$target.log" 2>&1 || { tail -5 "build-$target.log" >&2; exit 1; }
done

LIBS="$DMD_DIR/target"
mkdir -p dist
rm -rf dist/DmdCore.xcframework
xcodebuild -create-xcframework \
  -library "$LIBS/aarch64-apple-ios/release/libdmd_core.a" -headers include \
  -library "$LIBS/aarch64-apple-ios-sim/release/libdmd_core.a" -headers include \
  -library "$LIBS/aarch64-apple-darwin/release/libdmd_core.a" -headers include \
  -output dist/DmdCore.xcframework

# macOS smoke test: firmware 8;7;3 must draw its screen under paced stepping.
clang -O2 -o build-smoke test/smoke.c "$LIBS/aarch64-apple-darwin/release/libdmd_core.a" -Iinclude
./build-smoke

echo "OK: dist/DmdCore.xcframework"
