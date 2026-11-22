#!/bin/zsh
# สร้าง "NTP Checker.app" (SwiftUI, arm64) จากซอร์สใน NTPTester/
# ต้องการเพียง Xcode Command Line Tools (swiftc, iconutil, sips, codesign) — ไม่ต้องติดตั้งอะไรเพิ่ม
set -euo pipefail

ROOT="${0:A:h}"
SRC="$ROOT/NTPTester"
APP_NAME="NTP Checker"
APP="$ROOT/$APP_NAME.app"
BUILD="$ROOT/.build"
EXE="NTPChecker"
VERSION="2.0"

rm -rf "$BUILD" "$APP"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ คอมไพล์ (arm64, macOS 27)…"
swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macos27.0 \
  "$SRC/Sources/"*.swift \
  -o "$APP/Contents/MacOS/$EXE"

echo "▶ สร้างไอคอน…"
swift "$SRC/make_icon.swift" "$BUILD/icon_1024.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIdentifier</key><string>local.ntpchecker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>th</string>
  <key>CFBundleLocalizations</key><array><string>th</string></array>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>ใช้เพื่อส่งคำขอ NTP (UDP/123) ไปยังเซิร์ฟเวอร์เวลาในเครือข่ายภายใน</string>
</dict>
</plist>
PLIST

echo "▶ เซ็นแบบ ad-hoc…"
codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

rm -rf "$BUILD"
echo "✅ เสร็จแล้ว: $APP"
