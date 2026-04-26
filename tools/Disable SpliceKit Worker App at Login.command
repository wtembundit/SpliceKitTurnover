#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/workers/SpliceKit Worker.app"
OLD_APP_PATH="$ROOT_DIR/workers/VFX Shot List Worker.app"

/usr/bin/osascript <<EOF
tell application "System Events"
  delete every login item whose path is "$OLD_APP_PATH"
  delete every login item whose path is "$APP_PATH"
end tell
EOF

echo
echo "Disabled at login:"
echo "  $APP_PATH"
echo
read -r "?Press Enter to close..."
