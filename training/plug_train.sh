#!/bin/zsh
# Frame guide training, run by launchd every few minutes (see install.sh).
# Does nothing unless the iPhone is connected by cable. Then: pull the
# framing log from cam cam, embed new samples, retrain, and copy the new
# scorer back to the phone (Documents/FrameScorer.json). The app picks it
# up on its own — no rebuild or reinstall.
set -u
setopt nullglob
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH
PY=${CAMCAM_PYTHON:-/Library/Frameworks/Python.framework/Versions/3.14/bin/python3}
DEVICE=${CAMCAM_DEVICE:-F83E1A63-B138-56E4-8E14-2027E777D20A}
BUNDLE=idk.cam-cam
HERE=${0:A:h}
WORK=$HERE/data
mkdir -p "$WORK" "$HERE/.build"
LOG=$WORK/train.log
exec >>"$LOG" 2>&1

# Already ran in this plug-in session? (Marker cleared when it's unplugged.)
info=$(mktemp)
xcrun devicectl device info details --device "$DEVICE" --quiet --timeout 20 --json-output "$info" >/dev/null 2>&1
transport=$($PY -c "import json,sys;d=json.load(open('$info'));c=d.get('result',{}).get('connectionProperties',{});print(c.get('transportType','') if c.get('tunnelState')=='connected' else '')" 2>/dev/null)
rm -f "$info"
if [[ "$transport" != "wired" ]]; then
  rm -f "$WORK/.plugged"
  exit 0
fi
[[ -f "$WORK/.plugged" ]] && exit 0
touch "$WORK/.plugged"

echo "=== $(date '+%F %T') phone plugged in — training"
rm -rf "$WORK/pull" && mkdir -p "$WORK/pull"
if ! out=$(xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
     --domain-identifier "$BUNDLE" --source Documents/FramingLog --destination "$WORK/pull" --quiet 2>&1); then
  echo "$out"
  if [[ "$out" == *"file node"* ]]; then echo "no framing log on the phone yet"; exit 0; fi
  echo "pull failed (phone locked?) — will retry in a few minutes"; rm -f "$WORK/.plugged"; exit 0
fi
mkdir -p "$WORK/log"
# FramingLog may land as pull/ or pull/FramingLog depending on devicectl
src="$WORK/pull"; [[ -d "$WORK/pull/FramingLog" ]] && src="$WORK/pull/FramingLog"
for f in "$src"/*.json "$src"/*.jpg; do cp -n "$f" "$WORK/log/"; done
echo "$(ls "$WORK/log" | grep -c '\.json$') samples on the Mac"

if [[ ! -x "$HERE/.build/embed" || "$HERE/embed.swift" -nt "$HERE/.build/embed" ]]; then
  swiftc -O "$HERE/embed.swift" -o "$HERE/.build/embed" || exit 1
fi
"$HERE/.build/embed" "$WORK/log" "$WORK/cache" || exit 1

"$PY" "$HERE/train.py" "$WORK/cache" "$WORK/FrameScorer.json"
if [[ $? -ne 0 ]]; then echo "no new model this time"; exit 0; fi

if xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
     --domain-identifier "$BUNDLE" --source "$WORK/FrameScorer.json" --destination Documents/FrameScorer.json --quiet; then
  echo "scorer installed on the phone"
else
  echo "copy to phone failed — will retry next plug-in"; rm -f "$WORK/.plugged"
fi
