#!/bin/bash
# Đóng gói KaraokeMaker.app (universal: chạy NATIVE cả Apple Silicon lẫn Intel).
#
#   ./Scripts/build-app.sh          → .app đầy đủ (~207MB) — AirDrop LẦN ĐẦU
#   ./Scripts/build-app.sh --quick  → chỉ file chạy ~5MB ở dist/KaraokeMaker
#                                     (thả đè vào KaraokeMaker.app/Contents/MacOS/ trên M4)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/KaraokeMaker.app"
CONFIG=release
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

echo "▶︎ Build universal (arm64 + x86_64)…"
swift build -c "$CONFIG" --arch arm64 --arch x86_64

BIN=".build/apple/Products/Release/KaraokeMaker"
RESBUNDLE=".build/apple/Products/Release/KaraokeMaker_KaraokeMaker.bundle"
DYLIB=".build/apple/Products/Release/libonnxruntime.dylib"

if [ "$QUICK" = 1 ]; then
    mkdir -p dist
    cp "$BIN" dist/KaraokeMaker
    lipo -info dist/KaraokeMaker
    echo "✅ dist/KaraokeMaker (~$(du -h dist/KaraokeMaker | cut -f1)) — AirDrop, thả đè vào"
    echo "   KaraokeMaker.app/Contents/MacOS/KaraokeMaker  trên M4."
    exit 0
fi

echo "▶︎ Dựng .app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/KaraokeMaker"
cp "$DYLIB" "$APP/Contents/MacOS/libonnxruntime.dylib"
cp -R "$RESBUNDLE" "$APP/Contents/MacOS/"

# Bảo đảm dylib tìm thấy dù rpath là kiểu nào.
install_name_tool -add_rpath @executable_path "$APP/Contents/MacOS/KaraokeMaker" 2>/dev/null || true
install_name_tool -add_rpath @loader_path "$APP/Contents/MacOS/KaraokeMaker" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KaraokeMaker</string>
  <key>CFBundleDisplayName</key><string>KaraokeMaker</string>
  <key>CFBundleIdentifier</key><string>com.khoile.karaokemaker</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>KaraokeMaker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Gỡ cờ cách ly để máy khác mở khỏi bị Gatekeeper chặn (app chưa ký).
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# Ký ad-hoc để chạy được trên Apple Silicon.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

SIZE=$(du -sh "$APP" | cut -f1)
echo "✅ Xong: $APP  ($SIZE)"
echo "   AirDrop cả file .app sang máy kia. Lần đầu mở: chuột phải → Mở."
lipo -info "$APP/Contents/MacOS/KaraokeMaker"
