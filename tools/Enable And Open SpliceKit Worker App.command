#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/workers/SpliceKit Worker.app"
OLD_APP_PATH="$ROOT_DIR/workers/VFX Shot List Worker.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Worker app not found:"
  echo "  $APP_PATH"
  echo
  read -r "?Press Enter to close..."
  exit 1
fi

/usr/bin/osascript <<EOF
tell application "System Events"
  delete every login item whose path is "$OLD_APP_PATH"
  delete every login item whose path is "$APP_PATH"
  make login item at end with properties {path:"$APP_PATH", hidden:true}
end tell
EOF

open "$APP_PATH"

echo
echo "Enabled at login and opened now:"
echo "  $APP_PATH"
echo
read -r "?Press Enter to close..."
