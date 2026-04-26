#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/workers/SpliceKit Worker.app"
MENU_DIR="$HOME/Library/Application Support/SpliceKit/lua/menu"
STATE_DIR="$HOME/Library/Application Support/SpliceKit/VFXShotList"
MOTION_DIR="$HOME/Movies/Motion Templates.localized/Titles.localized/VFX/VFX Naming"

osascript -e 'tell application id "com.splicekit.worker-app" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "com.splicekit.vfx-shot-list-worker-app" to quit' >/dev/null 2>&1 || true

/usr/bin/osascript <<EOF || true
tell application "System Events"
  delete every login item whose path is "$APP_PATH"
end tell
EOF

rm -f "$MENU_DIR/VFX Auto Marker.lua"
rm -f "$MENU_DIR/VFX Auto Naming.lua"
rm -f "$MENU_DIR/VFX Reset Naming.lua"
rm -f "$MENU_DIR/VFX Shot List.lua"
rm -f "$MENU_DIR/VFX Timeline.lua"
rm -rf "$MENU_DIR/scripts"

rm -rf "$STATE_DIR"
rm -rf "$MOTION_DIR"

echo
echo "Removed installed SpliceKit Worker setup files:"
echo "  $MENU_DIR"
echo "  $STATE_DIR"
echo "  $MOTION_DIR"
echo
echo "The source package at:"
echo "  $ROOT_DIR"
echo "was not deleted."
echo
read -r "?Press Enter to close..."
