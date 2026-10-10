#!/bin/bash
#
# build-shaders.sh — precompile cam cam's Core Image Metal kernels.
#
# Why: Xcode 26+/27 ships the Metal compiler as a separate, ephemeral
# "MetalToolchain" component that can unmount mid-session, which broke every
# build that compiled a .metal file. Instead, the shader SOURCE lives in
# shaders/ (outside the app's synchronized folder, so Xcode never compiles
# it) and the compiled .metallib files are checked in under "cam cam/" as
# plain bundle resources. Normal builds need no Metal toolchain at all.
#
# Re-run this ONLY after editing a file in shaders/:
#     scripts/build-shaders.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="shaders/Ripple.ci.metal"
OUT_DIR="cam cam"
MIN_IOS="26.2"   # keep in sync with IPHONEOS_DEPLOYMENT_TARGET
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Make sure the compiler is present (no-op when already installed+mounted).
bash scripts/ensure-metal-toolchain.sh >/dev/null 2>&1 || true

build() {  # $1 = sdk, $2 = air target, $3 = output name
    xcrun -sdk "$1" metal -fcikernel -target "$2" -c "$SRC" -o "$TMP/$3.air"
    xcrun -sdk "$1" metallib -cikernel "$TMP/$3.air" -o "$OUT_DIR/$3.metallib"
    echo "built $OUT_DIR/$3.metallib"
}

build iphoneos          "air64-apple-ios${MIN_IOS}"           "Ripple-ios"
build iphonesimulator   "air64-apple-ios${MIN_IOS}-simulator" "Ripple-sim"
