#!/bin/zsh
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN_DIR/../.." && pwd)"
INSTALL_ROOT="$HOME/Library/Application Support/SpliceKit/plugins"
INSTALL_DIR="$INSTALL_ROOT/com.turnover.tools"
OUT="$PLUGIN_DIR/TurnoverToolsPlugin.dylib"
CONFORM_PLANNER_SOURCE="$REPO_ROOT/lua/scripts/build_conform_prep_fcpxml.mjs"
DELIVERIES_PLANNER_SOURCE="$REPO_ROOT/lua/scripts/build_vfx_deliveries_fcpxml.mjs"
MOTION_TEMPLATES_SOURCE="$REPO_ROOT/motion-templates/Titles.localized"
MOTION_TEMPLATES_DEST="$HOME/Movies/Motion Templates.localized/Titles.localized"

resolve_node() {
  local candidate

  if [ -n "${TURNOVER_NODE_PATH:-}" ] && [ -x "$TURNOVER_NODE_PATH" ]; then
    echo "$TURNOVER_NODE_PATH"
    return 0
  fi

  candidate="$(command -v node 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    echo "$candidate"
    return 0
  fi

  for candidate in \
    "$HOME/.volta/bin/node" \
    "$HOME/.asdf/shims/node" \
    /opt/homebrew/bin/node \
    /usr/local/bin/node \
    /opt/local/bin/node \
    /usr/local/opt/node/bin/node
  do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  for candidate in "$HOME"/.nvm/versions/node/*/bin/node(N.om); do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done

  echo ""
  return 1
}

NODE_PATH_FOUND="$(resolve_node || true)"
if [ -z "$NODE_PATH_FOUND" ] && command -v brew >/dev/null 2>&1; then
  echo "Node.js was not found."
  echo "Turnover can install Node.js with Homebrew automatically."
  printf "Install Node.js now? [y/N] "
  read -r REPLY
  case "$REPLY" in
    y|Y|yes|YES)
      brew install node
      NODE_PATH_FOUND="$(resolve_node || true)"
      ;;
  esac
fi

mkdir -p "$PLUGIN_DIR/data"

clang -dynamiclib -fobjc-arc -fblocks \
  -mmacosx-version-min=13.0 \
  -framework AppKit \
  -framework Foundation \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$PLUGIN_DIR/native/TurnoverToolsPlugin.m" \
  -o "$OUT"

mkdir -p "$INSTALL_ROOT"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

rsync -a \
  --exclude '.DS_Store' \
  --exclude 'native' \
  --exclude 'data' \
  "$PLUGIN_DIR/" "$INSTALL_DIR/"

mkdir -p "$INSTALL_DIR/native"
cp "$PLUGIN_DIR/native/SpliceKitPluginAPI.h" "$INSTALL_DIR/native/SpliceKitPluginAPI.h"

mkdir -p "$INSTALL_DIR/scripts"
cp "$CONFORM_PLANNER_SOURCE" "$INSTALL_DIR/scripts/build_conform_prep_fcpxml.mjs"
cp "$DELIVERIES_PLANNER_SOURCE" "$INSTALL_DIR/scripts/build_vfx_deliveries_fcpxml.mjs"

mkdir -p "$INSTALL_DIR/lua/scripts"
cp "$REPO_ROOT/lua/VFX Auto Naming.lua" "$INSTALL_DIR/lua/"
cp "$REPO_ROOT/lua/VFX Reset Naming.lua" "$INSTALL_DIR/lua/"
cp "$REPO_ROOT/lua/VFX Pull EDL.lua" "$INSTALL_DIR/lua/"
cp "$REPO_ROOT/lua/VFX Shot List.lua" "$INSTALL_DIR/lua/"
cp "$REPO_ROOT/lua/scripts/VFX Auto Marker - Standard.lua" "$INSTALL_DIR/lua/scripts/"
cp "$REPO_ROOT/lua/scripts/VFX Auto Marker - To Do.lua" "$INSTALL_DIR/lua/scripts/"
cp "$REPO_ROOT/lua/scripts/VFX Auto Marker - Chapter.lua" "$INSTALL_DIR/lua/scripts/"
cp "$REPO_ROOT/lua/scripts/generate_vfx_shot_list_excel.mjs" "$INSTALL_DIR/lua/scripts/"

mkdir -p "$INSTALL_DIR/data"
if [ -n "$NODE_PATH_FOUND" ]; then
  printf "%s\n" "$NODE_PATH_FOUND" > "$INSTALL_DIR/data/node_path.txt"
fi

if [ -d "$MOTION_TEMPLATES_SOURCE" ]; then
  mkdir -p "$MOTION_TEMPLATES_DEST"
  rsync -a "$MOTION_TEMPLATES_SOURCE/" "$MOTION_TEMPLATES_DEST/"
fi

echo "Installed Turnover plugin:"
echo "  $INSTALL_DIR"
echo "Installed Motion templates:"
echo "  $MOTION_TEMPLATES_DEST"
if [ -n "$NODE_PATH_FOUND" ]; then
  echo "Detected Node.js:"
  echo "  $NODE_PATH_FOUND"
else
  echo "Node.js was not found."
  echo "Install Node.js, then rerun this installer. You can also set TURNOVER_NODE_PATH=/path/to/node before running it."
fi
echo
echo "Restart patched Final Cut Pro, then call com.turnover.tools.show or open plugin.list to verify loading."
