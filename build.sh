#!/bin/bash
# Builds "dist/TensorFold Home.app" with swiftc (no Xcode project) and dist/TensorFoldHome.zip for a release.
#   ./build.sh             release build in dist/
#   ./build.sh dev         build in dist/dev/, so a running copy is never in the way
#   ./build.sh --install   release build, then copy it to ~/Applications (quit the running app first)
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(tr -d ' \n' <VERSION)
OUT=dist
[[ ${1:-} == dev ]] && OUT=dist/dev
APP="$OUT/TensorFold Home.app"
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fonts" "$APP/Contents/Resources/backend/bin"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  -o "$APP/Contents/MacOS/TensorFoldHome" src/*.swift

# icon: assets/icon-1024.png (tools/make_icon.swift) -> AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp assets/fonts/*.ttf assets/fonts/OFL.txt "$APP/Contents/Resources/fonts/"
cp backend/bin/* "$APP/Contents/Resources/backend/bin/"
cp backend/install.sh backend/models.conf backend/config.env.default "$APP/Contents/Resources/backend/"
# the app reinstalls its backend scripts when this stamp differs from the installed one
echo "$VERSION+$(cat backend/bin/* | shasum -a 256 | cut -c1-12)" >"$APP/Contents/Resources/backend/VERSION"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TensorFold Home</string>
  <key>CFBundleDisplayName</key><string>TensorFold Home</string>
  <key>CFBundleIdentifier</key><string>io.github.majieddd.tensorfoldhome</string>
  <key>CFBundleExecutable</key><string>TensorFoldHome</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Unofficial; not affiliated with TensorFold.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
(cd "$OUT" && rm -f TensorFoldHome.zip && ditto -c -k --keepParent "TensorFold Home.app" TensorFoldHome.zip)
echo "built $APP ($VERSION, build $BUILD)"
echo "zip   $OUT/TensorFoldHome.zip  sha256 $(shasum -a 256 "$OUT/TensorFoldHome.zip" | cut -d' ' -f1)"

if [[ ${1:-} == --install ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/TensorFold Home.app"
  ditto "$APP" "$HOME/Applications/TensorFold Home.app"
  echo "installed ~/Applications/TensorFold Home.app"
fi
