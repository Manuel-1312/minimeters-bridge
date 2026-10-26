#!/bin/bash
# Removes what install-macos.sh created: the LaunchAgent and ~/Library/Application Support/MiniMetersBridge.
set -uo pipefail

LABEL="io.github.manuel-1312.minimeters-bridge"
APP="$HOME/Library/Application Support/MiniMetersBridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$APP"
tccutil reset Microphone "$LABEL" >/dev/null 2>&1 || true
echo "MiniMeters bridge removed. (BlackHole and the Multi-Output Device are left as they are.)"
