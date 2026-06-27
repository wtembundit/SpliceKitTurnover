#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$ROOT_DIR/plugins/com.turnover.tools/Build And Install Turnover Tools Plugin.command"

pause_before_exit() {
  local status="$1"
  echo
  if [ "$status" -eq 0 ]; then
    echo "Turnover install completed."
    echo "Restart patched Final Cut Pro, then open the Turnover menu."
  else
    echo "Turnover install failed."
    echo "Please copy the error above when reporting the issue."
  fi
  echo
  printf "Press Return to close this window..."
  read -r _ || true
}

on_error() {
  local status="$?"
  pause_before_exit "$status"
  exit "$status"
}

trap on_error ERR

clear
echo "Turnover Plugin Installer"
echo "========================="
echo
echo "This installer will build and install the Turnover SpliceKit plugin."
echo

if [ ! -f "$INSTALLER" ]; then
  echo "Missing installer:"
  echo "  $INSTALLER"
  exit 1
fi

PREBUILT="$ROOT_DIR/plugins/com.turnover.tools/TurnoverToolsPlugin.dylib"
if ! xcrun --find clang >/dev/null 2>&1 && [ ! -f "$PREBUILT" ]; then
    echo "Xcode Command Line Tools are required to build the native plugin."
    echo "The GitHub release bundle includes a prebuilt plugin and does not require Xcode."
  echo
  echo "Install them with:"
  echo "  xcode-select --install"
  echo
  exit 1
fi

chmod +x "$INSTALLER"
"$INSTALLER"

pause_before_exit 0
