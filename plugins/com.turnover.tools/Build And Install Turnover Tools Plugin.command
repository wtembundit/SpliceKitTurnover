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

if [ -d "$MOTION_TEMPLATES_SOURCE" ]; then
  mkdir -p "$MOTION_TEMPLATES_DEST"
  rsync -a "$MOTION_TEMPLATES_SOURCE/" "$MOTION_TEMPLATES_DEST/"
fi

echo "Installed Turnover plugin:"
echo "  $INSTALL_DIR"
echo "Installed Motion templates:"
echo "  $MOTION_TEMPLATES_DEST"
echo
echo "Restart patched Final Cut Pro, then call com.turnover.tools.show or open plugin.list to verify loading."
