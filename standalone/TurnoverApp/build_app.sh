#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_DIR="$SCRIPT_DIR/build/Turnover.app"
CONTENTS="$APP_DIR/Contents"
CACHE_DIR="$SCRIPT_DIR/.build/cache"
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
BUILD_NUMBER="${VERSION//./}"
ICON_MASTER="$SCRIPT_DIR/Resources/AppIcon.png"
ICONSET_DIR="$SCRIPT_DIR/.build/Turnover.iconset"
NODE_VERSION="24.18.0"
NODE_ARCHIVE="node-v${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_ARCHIVE}"
NODE_CACHE="$SCRIPT_DIR/.build/runtime/node-v${NODE_VERSION}-darwin-arm64"

cd "$SCRIPT_DIR"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE_DIR/clang"
export XDG_CACHE_HOME="$CACHE_DIR"
swift build -c release

if [ ! -x "$NODE_CACHE/bin/node" ]; then
  runtime_tmp="$SCRIPT_DIR/.build/runtime-download"
  rm -rf "$runtime_tmp"
  mkdir -p "$runtime_tmp" "${NODE_CACHE:h}"
  curl -fL "$NODE_URL" -o "$runtime_tmp/$NODE_ARCHIVE"
  curl -fL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$runtime_tmp/SHASUMS256.txt"
  expected="$(awk -v archive="$NODE_ARCHIVE" '$2 == archive { print $1 }' "$runtime_tmp/SHASUMS256.txt")"
  actual="$(shasum -a 256 "$runtime_tmp/$NODE_ARCHIVE" | awk '{ print $1 }')"
  if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
    echo "Node.js runtime checksum verification failed." >&2
    exit 1
  fi
  tar -xzf "$runtime_tmp/$NODE_ARCHIVE" -C "${NODE_CACHE:h}"
  rm -rf "$runtime_tmp"
fi

if [ ! -d "$REPO_ROOT/lua/scripts/node_modules/exceljs" ]; then
  echo "Installing standalone spreadsheet dependencies..."
  (
    cd "$REPO_ROOT/lua/scripts"
    "$NODE_CACHE/bin/node" "$NODE_CACHE/lib/node_modules/npm/bin/npm-cli.js" \
      ci --omit=dev --ignore-scripts --no-audit --no-fund --loglevel=error
  )
fi

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/scripts"
cp "$BUILD_DIR/Turnover" "$CONTENTS/MacOS/Turnover"
cp "$REPO_ROOT/lua/scripts/build_conform_prep_fcpxml.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/build_vfx_auto_marker_fcpxml.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/build_vfx_pull_edl.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/build_vfx_naming_fcpxml.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/build_vfx_deliveries_fcpxml.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/build_vfx_shot_list_manifest.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/generate_vfx_shot_list_excel.mjs" "$CONTENTS/Resources/scripts/"
cp "$REPO_ROOT/lua/scripts/prepare_turnover_import_fcpxml.mjs" "$CONTENTS/Resources/scripts/"
cp -R "$REPO_ROOT/lua/scripts/node_modules" "$CONTENTS/Resources/scripts/"
rm -rf "$CONTENTS/Resources/scripts/node_modules/exceljs/dist" "$CONTENTS/Resources/scripts/node_modules/@types"
mkdir -p "$CONTENTS/Resources/runtime"
cp "$NODE_CACHE/bin/node" "$CONTENTS/Resources/runtime/node"
cp "$NODE_CACHE/LICENSE" "$CONTENTS/Resources/runtime/Node.js-LICENSE.txt"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for spec in "16 icon_16x16.png" "32 icon_16x16@2x.png" "32 icon_32x32.png" "64 icon_32x32@2x.png" "128 icon_128x128.png" "256 icon_128x128@2x.png" "256 icon_256x256.png" "512 icon_256x256@2x.png" "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ICON_MASTER" --out "$ICONSET_DIR/$name" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS/Resources/Turnover.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Turnover</string>
  <key>CFBundleIdentifier</key><string>com.turnover.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Turnover</string>
  <key>CFBundleDisplayName</key><string>Turnover</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>__TURNOVER_VERSION__</string>
  <key>CFBundleVersion</key><string>__TURNOVER_BUILD__</string>
  <key>CFBundleIconFile</key><string>Turnover</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Final Cut Pro XML</string>
      <key>CFBundleTypeExtensions</key><array><string>fcpxml</string><string>fcpxmld</string></array>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSTypeIsPackage</key><true/>
    </dict>
  </array>
</dict>
</plist>
PLIST
sed -i '' "s/__TURNOVER_VERSION__/$VERSION/g" "$CONTENTS/Info.plist"
sed -i '' "s/__TURNOVER_BUILD__/$BUILD_NUMBER/g" "$CONTENTS/Info.plist"

codesign --force --sign - "$APP_DIR"
echo "$APP_DIR"
du -sh "$APP_DIR"
