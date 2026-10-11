#!/bin/zsh
# Install (or remove with --remove) the launchd job that runs plug_train.sh
# every 3 minutes; it only does work while the phone is plugged in.
# macOS blocks background jobs from reading ~/Documents, so the scripts are
# copied to ~/Library/Application Support/camcam-trainer and run from there
# (training data and logs live there too). Re-run after editing them.
HERE=${0:A:h}
DEST="$HOME/Library/Application Support/camcam-trainer"
PLIST=~/Library/LaunchAgents/com.camcam.frametrainer.plist
launchctl bootout gui/$(id -u) "$PLIST" 2>/dev/null
if [[ "${1:-}" == "--remove" ]]; then rm -f "$PLIST"; echo "removed (data kept in $DEST)"; exit 0; fi
mkdir -p "$DEST"
cp "$HERE/plug_train.sh" "$HERE/embed.swift" "$HERE/train.py" "$DEST/"
chmod +x "$DEST/plug_train.sh"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.camcam.frametrainer</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$DEST/plug_train.sh</string></array>
  <key>StartInterval</key><integer>180</integer>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardErrorPath</key><string>$DEST/launchd.log</string>
</dict></plist>
PL
launchctl bootstrap gui/$(id -u) "$PLIST" && echo "installed: $PLIST -> $DEST"
