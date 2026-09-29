#!/bin/bash
#
# ensure-metal-toolchain.sh
#
# Xcode 27 (beta) ships the Metal compiler as a separately-downloadable
# "component" that mounts via an ephemeral cryptex. After a reboot it can
# come back as uninstalled/unmounted, which breaks any build that compiles
# a .ci.metal / .metal file (e.g. cam cam's Ripple.ci.metal) with:
#
#   error: cannot execute tool 'metal' due to missing Metal Toolchain
#
# This script (run on login via a LaunchAgent) checks the component and
# re-installs/mounts it if needed. When already installed+mounted it is a
# fast no-op. Logs to ~/Library/Logs/cam-cam-metal-toolchain.log.
#

LOG="$HOME/Library/Logs/cam-cam-metal-toolchain.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG"; }

log "checking Metal toolchain…"

status=$(/usr/bin/xcrun xcodebuild -showComponent MetalToolchain 2>/dev/null \
          | grep -i "Status:" | awk '{print $2}')
mounted=$(ls /var/run/com.apple.security.cryptexd/mnt/ 2>/dev/null | grep -ic metal)

log "status=${status:-unknown} mounted=${mounted}"

if [ "$status" != "installed" ] || [ "$mounted" -eq 0 ]; then
    log "re-installing / re-mounting Metal toolchain…"
    /usr/bin/xcrun xcodebuild -downloadComponent MetalToolchain >> "$LOG" 2>&1
    log "done (status now: $(/usr/bin/xcrun xcodebuild -showComponent MetalToolchain 2>/dev/null | grep -i Status:))"
else
    log "already installed and mounted — nothing to do"
fi
