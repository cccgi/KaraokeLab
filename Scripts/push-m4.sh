#!/bin/bash
# Build NATIVE arm64 rồi đẩy thẳng KaraokeMaker.app sang MacBook (M-series) qua mạng LAN,
# ký lại + mở luôn trên đó. Không cần AirDrop / giải nén / kéo thả.
#
# CHUẨN BỊ 1 LẦN trên MacBook:
#   System Settings › General › Sharing › bật "Remote Login".
#   (Muốn khỏi gõ mật khẩu mỗi lần: trên iMac chạy  ssh-copy-id khoi@<macbook>.local )
#
# DÙNG:
#   ./Scripts/push-m4.sh khoi@Macbook-cua-Khoi.local
#   hoặc đặt sẵn:  export KM_M4_HOST=khoi@Macbook-cua-Khoi.local   rồi chỉ cần  ./Scripts/push-m4.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# MẶC ĐỊNH x86_64 (Rosetta) — bản arm64 cross-compile từ iMac Intel tách nhạc MDX ra
# kết quả xấu → canh giờ loạn. Dùng --arm64 để thử lại native (khi đã sửa được).
PACK_ARGS=()
ARCH_NOTE="x86_64 (Rosetta)"
if [ "${1:-}" = "--arm64" ]; then
    PACK_ARGS=(--arm64)
    ARCH_NOTE="arm64 native (⚠︎ CẢNH BÁO: từng tách nhạc sai)"
    shift
elif [ "${1:-}" = "--x86" ]; then
    shift
fi

# MacBook M4 của user (đã cài SSH key). Ghi đè bằng đối số hoặc biến KM_M4_HOST.
HOST="${1:-${KM_M4_HOST:-khoile@Khois-MacBook-Air.local}}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8)

DEST="/Applications/KaraokeMaker.app"

echo "▶︎ Đóng gói ($ARCH_NOTE)…"
if [ "${#PACK_ARGS[@]}" -gt 0 ]; then ./Scripts/pack-local.sh "${PACK_ARGS[@]}"; else ./Scripts/pack-local.sh; fi

echo "▶︎ Kiểm tra kết nối tới $HOST …"
ssh "${SSH_OPTS[@]}" "$HOST" "true" || {
    echo "❌ Không SSH được vào $HOST."
    echo "   • Bật Remote Login trên MacBook (System Settings › General › Sharing)."
    echo "   • Cài key 1 lần:  ssh-copy-id $HOST"
    exit 1
}

echo "▶︎ Đóng bản đang chạy trên MacBook (nếu có) — không thì \"open\" chỉ đưa cửa sổ CŨ lên,
   không nạp bản mới vừa đẩy…"
ssh "${SSH_OPTS[@]}" "$HOST" "killall KaraokeMaker 2>/dev/null; sleep 0.3; killall -9 KaraokeMaker 2>/dev/null; true"

echo "▶︎ Đẩy app sang MacBook (chỉ phần thay đổi)…"
ssh "${SSH_OPTS[@]}" "$HOST" "mkdir -p '$DEST'"
rsync -az --delete --exclude '.DS_Store' -e "ssh ${SSH_OPTS[*]}" "dist/KaraokeMaker.app/" "$HOST:$DEST/"

echo "▶︎ Gỡ nhãn cách ly + ký lại + XOÁ ĐỆM TÁCH NHẠC CŨ (KHÔNG tự mở app)…"
ssh "${SSH_OPTS[@]}" "$HOST" "
  xattr -cr '$DEST' 2>/dev/null
  codesign --force --sign - '$DEST/Contents/MacOS/libonnxruntime.dylib' 2>/dev/null || true
  [ -d '$DEST/Contents/MacOS/whisper.framework' ] && codesign --force --sign - '$DEST/Contents/MacOS/whisper.framework' 2>/dev/null || true
  codesign --force --sign - '$DEST/Contents/MacOS/KaraokeMaker' 2>/dev/null || true
  codesign --force --deep --sign - '$DEST' 2>/dev/null || true
  rm -rf ~/Library/Caches/KaraokeMaker/stems
  MDIR=\"\$HOME/Library/Application Support/KaraokeMaker/models\"
  [ -d \"\$MDIR\" ] && find \"\$MDIR\" \\( -name '*.part' -o -name '*turbo*' \\) -delete 2>/dev/null || true
"
echo "✅ Đã cập nhật trên MacBook. Mở bằng lệnh:"
echo "   ssh $HOST \"open -a /Applications/KaraokeMaker.app\""
