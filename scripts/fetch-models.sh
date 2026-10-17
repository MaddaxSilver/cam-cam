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


#   MediaPipe Tasks Vision for iOS (Apache-2.0) + the BlazePose landmarker
#   (33 body points incl. hands and feet), used by the Pose guide.
MP="Vendor/MediaPipe"
if [ ! -d "$MP/frameworks/MediaPipeTasksVision.xcframework" ]; then
    mkdir -p "$MP"
    curl -fL --retry 3 https://dl.google.com/cpdc/20260727-225047/MediaPipeTasksCommon-1.0.0.tar.gz | tar -xz -C "$MP"
    curl -fL --retry 3 https://dl.google.com/cpdc/20260727-225049/MediaPipeTasksVision-1.0.0.tar.gz | tar -xz -C "$MP"
fi
[ -s "$DEST/pose_landmarker_full.task" ] || curl -fL --retry 3 -o "$DEST/pose_landmarker_full.task" \
    https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task
echo "MediaPipe in $MP"
