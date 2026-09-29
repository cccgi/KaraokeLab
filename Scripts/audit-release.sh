#!/bin/bash
# Kiểm tra gói phát hành: kiến trúc, phụ thuộc động, đường dẫn dev, móc kiểm thử.
#   ./Scripts/audit-release.sh <KaraokeMaker.app> <x86_64|arm64> <release|guitest>
set -uo pipefail
APP="$1"; ARCH="$2"; KIND="${3:-release}"
RT="$APP/Contents/Resources/AutoLyricsRuntime"
FAIL=0
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=1; }

echo "== $APP ($ARCH, $KIND)"
# 1) binary chính đúng kiến trúc
A="$(lipo -archs "$APP/Contents/MacOS/KaraokeMaker" 2>/dev/null)"
[ "$A" = "$ARCH" ] && ok "binary chính: $A" || bad "binary chính là '$A', cần $ARCH"

# 2) mọi Mach-O trong app chứa kiến trúc cần dùng + không phụ thuộc thư viện ngoài (chỉ /usr/lib, /System, @rpath, @loader_path, @executable_path).
#    (id của chính dylib — vd /DLC/numpy/.dylibs/… — không phải phụ thuộc, bỏ qua.)
TMP="$(mktemp)"
find "$APP" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 2>/dev/null | xargs -0 file 2>/dev/null | grep "Mach-O" \
  | sed -E -e 's/:[[:space:]]*Mach-O.*$//' -e 's/ \(for architecture [^)]*\)$//' | sort -u > "$TMP"
N=$(wc -l < "$TMP" | tr -d ' ')
WRONG=0
: > "$TMP.ext"
while IFS= read -r f; do
  ar="$(lipo -archs "$f" 2>/dev/null)"
  case " $ar " in *" $ARCH "*) ;; *) WRONG=$((WRONG+1)); echo "     kiến trúc lạ ($ar): ${f#$APP/}";; esac
  selfid="$(otool -D "$f" 2>/dev/null | tail -n +2 | head -1)"
  otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
    [ "$dep" = "$selfid" ] && continue
    case "$dep" in
      /usr/lib/*|/System/Library/*|@rpath/*|@loader_path/*|@executable_path/*) ;;
      *) echo "     phụ thuộc ngoài: ${f#$APP/} -> $dep" >> "$TMP.ext";;
    esac
  done
done < "$TMP"
EXT=$(wc -l < "$TMP.ext" | tr -d ' ')
[ "$WRONG" = 0 ] && ok "$N file Mach-O, tất cả chứa kiến trúc $ARCH" || bad "$WRONG file Mach-O sai kiến trúc"
[ "$EXT" = 0 ] && ok "không có phụ thuộc động ra ngoài app/hệ thống" || { bad "$EXT phụ thuộc động ra ngoài:"; head -15 "$TMP.ext"; }
rm -f "$TMP" "$TMP.ext"

# 3) đường dẫn tuyệt đối tới thư mục dev / máy này bên trong runtime (script, .pth, pyvenv…)
if grep -rIl --exclude='*.pyc' -e "qwen3_asr_" -e "/Users/khoile" "$RT/python/bin" "$RT/site-packages"/*.pth "$RT/site-packages"/*.py 2>/dev/null | head -3 | grep -q .; then
  bad "runtime còn tham chiếu thư mục dev:"; grep -rIl --exclude='*.pyc' -e "qwen3_asr_" -e "/Users/khoile" "$RT/python/bin" "$RT/site-packages"/*.pth "$RT/site-packages"/*.py 2>/dev/null | head -5
else ok "runtime không tham chiếu ~/qwen3_asr_* hay /Users/khoile"; fi
[ -e "$RT/hf_cache/hub" ] && ! find "$RT/hf_cache" -type l | grep -q . && ok "mô hình là file thật (không symlink)" || bad "hf_cache có symlink hoặc thiếu"
find "$RT" -type l | head -3 | grep -q . && echo "  [i]    có symlink trong runtime: $(find "$RT" -type l | wc -l | tr -d ' ') (kiểm tra thêm khi ký)"

# 4) binary chính KHÔNG chứa đường dẫn dev / móc kiểm thử (bản phát hành)
BIN="$APP/Contents/MacOS/KaraokeMaker"
if strings -a "$BIN" | grep -q "qwen3_asr_intel_test\|qwen3_asr_m4_test\|qwen3_asr_correction_test"; then bad "binary còn chứa đường dẫn ~/qwen3_asr_*"; else ok "binary không chứa đường dẫn ~/qwen3_asr_*"; fi
if [ "$KIND" = release ]; then
  strings -a "$BIN" | grep -q "KM_GUITEST_DIR" && bad "binary phát hành còn móc KM_GUITEST_DIR" || ok "không có bộ điều khiển GUI (KM_GUITEST_DIR) trong bản phát hành"
  strings -a "$BIN" | grep -q "KM_AUTOLYRICS_PYTHON\|KM_AUTOLYRICS_HELPER" && bad "binary phát hành còn biến môi trường dev KM_AUTOLYRICS_*" || ok "không còn biến môi trường dev KM_AUTOLYRICS_*"
fi

# 5) thư mục cần có
for p in python/bin/python3 site-packages/torch site-packages/qwen_asr site-packages/transformers hf_cache/hub/models--Qwen--Qwen3-ASR-0.6B hf_cache/hub/models--Qwen--Qwen3-ASR-1.7B; do
  [ -e "$RT/$p" ] && ok "có $p" || bad "thiếu $p"
done
[ -f "$APP/Contents/Resources/KaraokeMaker_KaraokeMaker.bundle/lyric_asr/lyric_asr_helper.py" ] && ok "có helper lyric_asr_helper.py + lyric_correct/" || bad "thiếu helper"

[ "$FAIL" = 0 ] && echo "AUDIT: PASS" || echo "AUDIT: FAIL"
exit $FAIL
