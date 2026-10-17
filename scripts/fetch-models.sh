#!/bin/bash
#
# fetch-models.sh — download the optional ML models cam cam uses.
# They're too big for git; the app works without them (falling back to
# the camera's own depth / Apple's pose) and uses them when present.
#
#   Depth Anything V2 Small (Apache-2.0), Apple's Core ML conversion:
#   https://huggingface.co/apple/coreml-depth-anything-v2-small
#
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="cam cam/Models"
BASE="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage"
PKG="$DEST/DepthAnythingV2SmallF16.mlpackage"
mkdir -p "$PKG/Data/com.apple.CoreML/weights"
for f in Manifest.json Data/com.apple.CoreML/model.mlmodel Data/com.apple.CoreML/weights/weight.bin; do
    [ -s "$PKG/$f" ] || curl -fL --retry 3 -o "$PKG/$f" "$BASE/$f"
done
echo "models in $DEST"
