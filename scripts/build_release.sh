#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
RELEASE_DIR="$ROOT/release"
STAGE_ROOT="$ROOT/.build/release-v$VERSION"
PLUGIN_STAGE="$STAGE_ROOT/Turnover-SpliceKit-v$VERSION"
APP_STAGE="$STAGE_ROOT/Turnover-Standalone-v$VERSION"
PLUGIN_DIR="$ROOT/plugins/com.turnover.tools"

if [ "$(plutil -extract version raw "$PLUGIN_DIR/plugin.json")" != "$VERSION" ]; then
  echo "plugin.json does not match VERSION ($VERSION)." >&2
  exit 1
fi
if ! rg -q "TTTurnoverVersion = @\"$VERSION\"" "$PLUGIN_DIR/native/TurnoverToolsPlugin.m"; then
  echo "Native plugin version does not match VERSION ($VERSION)." >&2
  exit 1
fi

"$ROOT/standalone/TurnoverApp/build_app.sh"

clang -dynamiclib -fobjc-arc -fblocks \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=13.0 \
  -framework AppKit -framework Foundation \
  -framework ApplicationServices -framework CoreGraphics \
  -framework UniformTypeIdentifiers \
  "$PLUGIN_DIR/native/TurnoverToolsPlugin.m" \
  -o "$PLUGIN_DIR/TurnoverToolsPlugin.dylib"

rm -rf "$STAGE_ROOT"
mkdir -p "$PLUGIN_STAGE" "$APP_STAGE" "$RELEASE_DIR"

cp "$ROOT/Install Turnover.command" "$PLUGIN_STAGE/"
rsync -a --exclude '.DS_Store' --exclude 'data' "$PLUGIN_DIR" "$PLUGIN_STAGE/plugins/"
rsync -a --exclude '.DS_Store' --exclude 'scripts/node_modules' "$ROOT/lua" "$PLUGIN_STAGE/"
rsync -a --exclude '.DS_Store' "$ROOT/motion-templates" "$PLUGIN_STAGE/"
rsync -a --exclude '.DS_Store' "$ROOT/docs" "$PLUGIN_STAGE/"
cp "$ROOT/README.md" "$PLUGIN_STAGE/"

cp -R "$ROOT/standalone/TurnoverApp/build/Turnover.app" "$APP_STAGE/"
cp "$ROOT/standalone/TurnoverApp/README.md" "$APP_STAGE/README.md"
cp "$ROOT/docs/release-notes-v$VERSION.md" "$APP_STAGE/Release Notes.md"

rm -f "$RELEASE_DIR/Turnover-SpliceKit-v$VERSION.zip" "$RELEASE_DIR/Turnover-Standalone-v$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$PLUGIN_STAGE" "$RELEASE_DIR/Turnover-SpliceKit-v$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_STAGE" "$RELEASE_DIR/Turnover-Standalone-v$VERSION.zip"

shasum -a 256 "$RELEASE_DIR/Turnover-SpliceKit-v$VERSION.zip" "$RELEASE_DIR/Turnover-Standalone-v$VERSION.zip" > "$RELEASE_DIR/SHA256SUMS-v$VERSION.txt"
ls -lh "$RELEASE_DIR/Turnover-"*"v$VERSION.zip" "$RELEASE_DIR/SHA256SUMS-v$VERSION.txt"
