#!/bin/bash
# Bản THỬ riêng để chủ dự án duyệt thay đổi giao diện TRƯỚC khi đưa vào app chính.
# Build (giống pack-local.sh) → đóng gói vào "~/Desktop/KaraokeMaker THIẾT KẾ MỚI.app" (KHÔNG đụng dist/ = app chính)
# → đóng app đang mở → mở bản thử.   Dùng:  ./Scripts/pack-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_APP="$HOME/Desktop/KaraokeMaker THIẾT KẾ MỚI.app"
BUILD_DIR=".build/release"

echo "▶︎ Build release…"
swift build -c release -Xswiftc -DKM_DEV_RUNTIME

echo "▶︎ Đóng gói bản thử…"
killall KaraokeMaker 2>/dev/null || true
sleep 0.5
rm -rf "$TEST_APP"
cp -R dist/KaraokeMaker.app "$TEST_APP"                 # lấy vỏ (icon, Info.plist) từ app chính
cp -f "$BUILD_DIR/KaraokeMaker" "$TEST_APP/Contents/MacOS/KaraokeMaker"
cp -f "$BUILD_DIR/libonnxruntime.dylib" "$TEST_APP/Contents/MacOS/libonnxruntime.dylib"
rm -rf "$TEST_APP/Contents/MacOS/KaraokeMaker_KaraokeMaker.bundle" \
       "$TEST_APP/Contents/Resources/KaraokeMaker_KaraokeMaker.bundle" \
       "$TEST_APP/Contents/MacOS/whisper.framework"
cp -R "$BUILD_DIR/KaraokeMaker_KaraokeMaker.bundle" "$TEST_APP/Contents/Resources/"
install_name_tool -add_rpath @executable_path "$TEST_APP/Contents/MacOS/KaraokeMaker" 2>/dev/null || true
STAMP="$(date '+%Y%m%d.%H%M')"
plutil -replace CFBundleVersion -string "$STAMP" "$TEST_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "1.0 ($STAMP THIẾT KẾ MỚI)" "$TEST_APP/Contents/Info.plist"
xattr -cr "$TEST_APP" || true
codesign --force --sign - "$TEST_APP/Contents/MacOS/libonnxruntime.dylib" || true
codesign --force --sign - "$TEST_APP/Contents/MacOS/KaraokeMaker" || true
xattr -cr "$TEST_APP" || true
codesign --force --deep --sign - "$TEST_APP" || true

echo "✅ Bản thử: $TEST_APP"
open "$TEST_APP"
