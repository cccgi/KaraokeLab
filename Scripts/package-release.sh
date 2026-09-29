#!/bin/bash
# Đóng gói KaraokeMaker.app TỰ CHỨA (Python + PyTorch + qwen-asr + 2 mô hình nằm TRONG app) cho MỘT kiến trúc.
#
#   ./Scripts/package-release.sh --arch x86_64            # máy Intel
#   ./Scripts/package-release.sh --arch arm64             # máy Apple Silicon (chạy NATIVE, không Rosetta)
#   thêm  --guitest   : biến thể có bộ điều khiển GUI để kiểm thử (KHÔNG phát hành)
#   thêm  --runtime D : thư mục runtime đã dựng (mặc định dist-release/runtime-<arch>)
#   thêm  --no-sign   : bỏ ký ad-hoc
#
# Kết quả: dist-release/<arch>/KaraokeMaker.app  (+ SIZE.txt, AUDIT.txt).  KHÔNG đụng dist/ (app của người dùng).
# Chưa làm: Developer ID / notarization / license / Sparkle (giai đoạn sau, cần người dùng đồng ý).
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH=""; GUITEST=0; RUNTIME=""; SIGN=1
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2;;
    --guitest) GUITEST=1; shift;;
    --runtime) RUNTIME="$2"; shift 2;;
    --no-sign) SIGN=0; shift;;
    *) echo "đối số lạ: $1"; exit 2;;
  esac
done
[ "$ARCH" = "x86_64" ] || [ "$ARCH" = "arm64" ] || { echo "cần --arch x86_64|arm64"; exit 2; }
RUNTIME="${RUNTIME:-dist-release/runtime-$ARCH}"
[ -x "$RUNTIME/python/bin/python3" ] && [ -d "$RUNTIME/site-packages" ] && [ -d "$RUNTIME/hf_cache/hub" ] || { echo "runtime chưa đủ ở $RUNTIME (cần python/, site-packages/, hf_cache/)"; exit 2; }

TAG="$ARCH"; BUILD_PATH=".build-release-$ARCH"; SWIFT_EXTRA=(); ARCH_ARGS=()
[ "$ARCH" = "arm64" ] && ARCH_ARGS=(--arch arm64)
BUNDLE_ID="com.khoile.karaokemaker"
APP_NAME="KaraokeMaker.app"
if [ "$GUITEST" = 1 ]; then
  TAG="$ARCH-guitest"; BUILD_PATH=".build-release-$ARCH-guitest"; SWIFT_EXTRA=(-Xswiftc -DKM_GUITEST)
  BUNDLE_ID="com.khoile.karaokemaker.guitest"; APP_NAME="KaraokeMaker-GUITEST.app"
fi
OUT="dist-release/$TAG"; APP="$OUT/$APP_NAME"

echo "▶︎ Build release ($ARCH$([ "$GUITEST" = 1 ] && echo ', GUITEST')) → $BUILD_PATH"
swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --build-path "$BUILD_PATH" ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} 2>&1 | grep -E "error:|Build complete|Compiling.*warning: unre" || true
BIN_DIR="$(swift build -c release ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --build-path "$BUILD_PATH" ${SWIFT_EXTRA[@]+"${SWIFT_EXTRA[@]}"} --show-bin-path)"
[ -x "$BIN_DIR/KaraokeMaker" ] || { echo "không thấy binary ở $BIN_DIR"; exit 1; }
lipo -archs "$BIN_DIR/KaraokeMaker" | grep -qx "$ARCH" || { echo "binary sai kiến trúc: $(lipo -archs "$BIN_DIR/KaraokeMaker")"; exit 1; }

echo "▶︎ Dựng $APP"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN_DIR/KaraokeMaker" "$APP/Contents/MacOS/KaraokeMaker"
cp -f "$BIN_DIR/libonnxruntime.dylib" "$APP/Contents/MacOS/libonnxruntime.dylib"
cp -R "$BIN_DIR/KaraokeMaker_KaraokeMaker.bundle" "$APP/Contents/Resources/"
install_name_tool -add_rpath @executable_path "$APP/Contents/MacOS/KaraokeMaker" 2>/dev/null || true
[ -f dist/KaraokeMaker.app/Contents/Resources/AppIcon.icns ] && cp -f dist/KaraokeMaker.app/Contents/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▶︎ Nhét runtime nhận dạng lời (clonefile nếu cùng ổ APFS)…"
cp -Rc "$RUNTIME" "$APP/Contents/Resources/AutoLyricsRuntime"
rm -f "$APP/Contents/Resources/AutoLyricsRuntime/MANIFEST.json"
cp -f "$RUNTIME/MANIFEST.json" "$OUT/RUNTIME_MANIFEST.json" 2>/dev/null || true

STAMP="$(date '+%Y%m%d.%H%M')"
ICON_LINE=""; [ -f "$APP/Contents/Resources/AppIcon.icns" ] && ICON_LINE='  <key>CFBundleIconFile</key><string>AppIcon</string>'
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KaraokeMaker</string>
  <key>CFBundleDisplayName</key><string>KaraokeMaker</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$STAMP</string>
  <key>CFBundleShortVersionString</key><string>1.0 ($STAMP $ARCH)</string>
  <key>CFBundleExecutable</key><string>KaraokeMaker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSArchitecturePriority</key><array><string>$ARCH</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$ICON_LINE
</dict></plist>
PLIST

if [ "$SIGN" = 1 ]; then
  echo "▶︎ Ký ad-hoc (chưa phải Developer ID)…"
  xattr -cr "$APP" || true
  codesign --force --sign - "$APP/Contents/MacOS/libonnxruntime.dylib"
  codesign --force --sign - "$APP/Contents/MacOS/KaraokeMaker"
  codesign --force --sign - "$APP"
  codesign --verify --strict "$APP" && echo "   chữ ký ad-hoc hợp lệ"
fi

echo "▶︎ Kích thước…"
{
  echo "KaraokeMaker $TAG — $(date)"
  du -sk "$APP" | awk '{printf "TỔNG app:                 %8.0f MB\n",$1/1024}'
  du -sk "$APP/Contents/MacOS" | awk '{printf "  binary + onnxruntime:   %8.0f MB\n",$1/1024}'
  du -sk "$APP/Contents/Resources/KaraokeMaker_KaraokeMaker.bundle" | awk '{printf "  mô hình tách nhạc/canh: %8.0f MB   (MDX, MDX23C, MMS aligner…)\n",$1/1024}'
  du -sk "$APP/Contents/Resources/AutoLyricsRuntime/python" | awk '{printf "  Python:                 %8.0f MB\n",$1/1024}'
  du -sk "$APP/Contents/Resources/AutoLyricsRuntime/site-packages" | awk '{printf "  PyTorch+qwen-asr+libs:  %8.0f MB\n",$1/1024}'
  du -sk "$APP/Contents/Resources/AutoLyricsRuntime/hf_cache/hub/models--Qwen--Qwen3-ASR-0.6B" | awk '{printf "  Qwen3-ASR 0.6B:         %8.0f MB\n",$1/1024}'
  du -sk "$APP/Contents/Resources/AutoLyricsRuntime/hf_cache/hub/models--Qwen--Qwen3-ASR-1.7B" | awk '{printf "  Qwen3-ASR 1.7B (kiểm): %8.0f MB\n",$1/1024}'
} | tee "$OUT/SIZE.txt"

echo "▶︎ Kiểm tra (audit)…"
bash Scripts/audit-release.sh "$APP" "$ARCH" $([ "$GUITEST" = 1 ] && echo guitest || echo release) | tee "$OUT/AUDIT.txt"
echo "✅ Xong: $APP"
