#!/bin/bash
# Cập nhật KaraokeMaker.app tại dist/ (chỗ này cố định — icon trên Desktop trỏ vào đây).
# Dùng sau mỗi lần sửa code:  ./Scripts/pack-local.sh
#   ./Scripts/pack-local.sh --arm64   → build NATIVE Apple Silicon (cho máy M‑series),
#                                        đồng thời tạo dist/CapNhat-KaraokeMaker.zip + dist/KaraokeMaker-M4.zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/KaraokeMaker.app"

ARCH_TAG=""
BUILD_DIR=".build/release"
SWIFT_ARCH_ARGS=()
if [ "${1:-}" = "--arm64" ]; then
    ARCH_TAG=" arm64"
    BUILD_DIR=".build/arm64-apple-macosx/release"
    SWIFT_ARCH_ARGS=(--arch arm64)
    echo "▶︎ Build release (NATIVE arm64)…"
else
    echo "▶︎ Build release…"
fi
# SwiftPM không tự xoá resource đã gỡ khỏi bundle → xoá bundle cũ để build sạch.
rm -rf .build/*/release/KaraokeMaker_KaraokeMaker.bundle .build/release/KaraokeMaker_KaraokeMaker.bundle 2>/dev/null || true
# Bản CỤC BỘ (máy dev): bật -DKM_DEV_RUNTIME để "Tự động tạo Karaoke" tìm runtime dựng thử ở ~/qwen3_asr_* / KM_AUTOLYRICS_*.
# Bản PHÁT HÀNH (Scripts/package-release.sh) KHÔNG có cờ này — dùng runtime nằm TRONG app.
if [ "${#SWIFT_ARCH_ARGS[@]}" -gt 0 ]; then swift build -c release "${SWIFT_ARCH_ARGS[@]}" -Xswiftc -DKM_DEV_RUNTIME; else swift build -c release -Xswiftc -DKM_DEV_RUNTIME; fi

BIN="$BUILD_DIR/KaraokeMaker"
RESBUNDLE="$BUILD_DIR/KaraokeMaker_KaraokeMaker.bundle"
DYLIB="$BUILD_DIR/libonnxruntime.dylib"

echo "▶︎ Cập nhật .app (giữ nguyên vị trí)…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN"   "$APP/Contents/MacOS/KaraokeMaker"
cp -f "$DYLIB" "$APP/Contents/MacOS/libonnxruntime.dylib"
# whisper.cpp đã bỏ — dọn framework cũ nếu còn sót trong .app.
rm -rf "$APP/Contents/MacOS/whisper.framework"
# Gói tài nguyên (model .onnx, icon người hát) đặt ở Contents/Resources — chỗ CHUẨN,
# `Bundle.module` tìm ở đây trước tiên nên chạy đúng cả khi máy khác "cách ly" app
# (App Translocation) hoặc chạy qua Rosetta trên máy Apple Silicon.
rm -rf "$APP/Contents/MacOS/KaraokeMaker_KaraokeMaker.bundle" \
       "$APP/Contents/Resources/KaraokeMaker_KaraokeMaker.bundle"
cp -R "$RESBUNDLE" "$APP/Contents/Resources/"
install_name_tool -add_rpath @executable_path "$APP/Contents/MacOS/KaraokeMaker" 2>/dev/null || true

# --- Icon: xử ảnh thô → squircle + gradient, rồi dựng AppIcon.icns ---
ICON_LINE=""
RAW_ICON=""
for cand in Branding/AppIcon-source.png Branding/AppIcon.PNG Branding/AppIcon.png Branding/appicon.png; do
    [ -f "$cand" ] && { RAW_ICON="$cand"; break; }
done
if [ -n "$RAW_ICON" ]; then
    SRC_ICON="dist/appicon-processed.png"
    swift Scripts/make-icon.swift "$RAW_ICON" "$SRC_ICON" || SRC_ICON="$RAW_ICON"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 64 128 256 512; do
        sips -z $s $s     "$SRC_ICON" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null 2>&1
        sips -z $((s*2)) $((s*2)) "$SRC_ICON" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    mkdir -p "$APP/Contents/Resources"
    if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        ICON_LINE='  <key>CFBundleIconFile</key><string>AppIcon</string>'
        echo "▶︎ Đã gắn icon (squircle + gradient) từ $RAW_ICON"
    fi
fi

BUILD_STAMP="$(date '+%Y%m%d.%H%M')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KaraokeMaker</string>
  <key>CFBundleDisplayName</key><string>KaraokeMaker</string>
  <key>CFBundleIdentifier</key><string>com.khoile.karaokemaker</string>
  <key>CFBundleVersion</key><string>$BUILD_STAMP</string>
  <key>CFBundleShortVersionString</key><string>1.0 ($BUILD_STAMP$ARCH_TAG)</string>
  <key>CFBundleExecutable</key><string>KaraokeMaker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>KaraokeMaker dùng nhận dạng giọng nói trong máy để tự tạo lời karaoke từ giọng hát.</string>
$ICON_LINE
</dict></plist>
PLIST

# Xoá hết thuộc tính mở rộng (quarantine, FinderInfo…) — nếu còn thì codesign báo
# "resource fork / Finder information … not allowed".
xattr -cr "$APP" || true
# Ký ad-hoc: ký từng phần bên trong trước rồi ký cả .app (máy Apple Silicon bắt buộc
# mọi mã phải có chữ ký, kể cả ad-hoc). Xoá xattr lại ngay trước mỗi lần ký.
xattr -cr "$APP" || true
codesign --force --sign - "$APP/Contents/MacOS/libonnxruntime.dylib" || true
[ -d "$APP/Contents/MacOS/whisper.framework" ] && \
  codesign --force --sign - "$APP/Contents/MacOS/whisper.framework" || true
codesign --force --sign - "$APP/Contents/MacOS/KaraokeMaker" || true
xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP" || true
if codesign --verify --deep --strict "$APP" 2>/dev/null; then
  echo "▶︎ Đã ký ad-hoc OK ($(codesign -dv "$APP" 2>&1 | awk -F= '/^Signature/{print $2}'))"
else
  echo "⚠︎ Ký chưa đạt — thử: xattr -cr \"$APP\" && codesign --force --deep -s - \"$APP\""
fi

# Ép Finder/Dock nạp lại icon (đổi .icns tại chỗ không tự cập nhật).
touch "$APP"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")" >/dev/null 2>&1 || true
# xoá cache icon của .app này rồi khởi động lại Dock (an toàn, chỉ vẽ lại)
rm -rf "$APP/Icon"$'\r' 2>/dev/null || true

echo "✅ Đã cập nhật $APP  (nếu icon chưa đổi: đăng xuất/đăng nhập lại, hoặc chạy: killall Dock Finder)"

# --arm64: build NATIVE arm64. Thư mục dist/ để CHIA SẺ QUA MẠNG (Cách 2):
#   MacBook mount smb://<iMac>.local, thấy dist/KaraokeMaker.app luôn mới nhất.
#   Nhấp đúp "CÀI vào Applications.command" ngay trong thư mục mount là xong.
if [ "${1:-}" = "--arm64" ]; then
    rm -f dist/KaraokeMaker-M4.zip dist/appicon-processed.png 2>/dev/null || true
    cat > "dist/CÀI vào Applications.command" <<'EOF'
#!/bin/bash
# Chép KaraokeMaker.app (cùng thư mục) vào /Applications, ký lại, mở.
# Chạy trên MacBook — kể cả khi thư mục này là ổ mạng của iMac.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/KaraokeMaker.app"
[ -d "$SRC" ] || { echo "Không thấy KaraokeMaker.app cạnh file này."; read -n1 -r -p "Nhấn phím để đóng."; exit 1; }
DEST="/Applications/KaraokeMaker.app"
echo "▶︎ Đang chép vào $DEST … (có thể mất ~1 phút nếu qua mạng)"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
xattr -cr "$DEST"
codesign --force --sign - "$DEST/Contents/MacOS/libonnxruntime.dylib" 2>/dev/null || true
[ -d "$DEST/Contents/MacOS/whisper.framework" ] && codesign --force --sign - "$DEST/Contents/MacOS/whisper.framework" 2>/dev/null || true
codesign --force --sign - "$DEST/Contents/MacOS/KaraokeMaker" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" 2>/dev/null || true
open "$DEST"
echo "✅ Xong — KaraokeMaker đã cài trong Applications và đang mở."
EOF
    chmod +x "dist/CÀI vào Applications.command"
    echo "✅ Thư mục dist/ sẵn sàng chia sẻ. Trên MacBook: mở ổ mạng → nhấp đúp 'CÀI vào Applications.command'."
fi
