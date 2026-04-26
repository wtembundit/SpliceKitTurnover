#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpliceKit Worker.app"
OLD_APP_NAME="VFX Shot List Worker.app"
APP_DIR="$ROOT_DIR/workers/$APP_NAME"
OLD_APP_DIR="$ROOT_DIR/workers/$OLD_APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_DIR="$ROOT_DIR/.build/vfx-shot-list-worker-app"
SWIFT_SOURCE="$ROOT_DIR/app-src/VFXShotListWorker/main.swift"
ICON_SOURCE="$ROOT_DIR/assets/SpliceKitWorkerIconPreview.png"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
ICON_ICNS="$RESOURCES_DIR/SpliceKitWorker.icns"
ICON_PREVIEW_DEST="$RESOURCES_DIR/SpliceKitWorkerIconPreview.png"

mkdir -p "$BUILD_DIR" "$MACOS_DIR" "$RESOURCES_DIR"
rm -rf "$APP_DIR"
rm -rf "$OLD_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SpliceKitWorker</string>
  <key>CFBundleIdentifier</key>
  <string>com.splicekit.worker-app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>SpliceKit Worker</string>
  <key>CFBundleIconFile</key>
  <string>SpliceKitWorker</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

swiftc \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  "$SWIFT_SOURCE" \
  -o "$MACOS_DIR/SpliceKitWorker"

chmod +x "$MACOS_DIR/SpliceKitWorker"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$ICON_PREVIEW_DEST"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  cp "$ICON_SOURCE" "$ICONSET_DIR/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"
fi

echo
echo "Built app:"
echo "  $APP_DIR"
echo
if [[ -t 0 ]]; then
  read -r "?Press Enter to close..."
fi
