#!/bin/bash
# Kiểm tra giao diện TỰ ĐỘNG: chụp màn hình editor ở 3 cỡ cửa sổ + đo CPU (đứng yên / đang phát).
# Dùng bản dựng kiểm thử riêng (-DKM_GUITEST, thư mục build .build-guitest) — KHÔNG đụng dist/ (app chính)
# và KHÔNG đụng "KaraokeMaker THIẾT KẾ MỚI.app". Không killall: app đang mở của chủ dự án vẫn chạy bình thường.
# Dự án được CHÉP ra thư mục tạm trước khi mở → file gốc không bị sửa.
#
#   ./Scripts/ui-check.sh                       # dự án mẫu = dự án mới nhất trong ~/Movies/KaraokeMaker Projects
#   ./Scripts/ui-check.sh "/đường/dẫn/bài.kbproj"
#
# Kết quả: .ui-check/<giờ>/  (ảnh PNG + report.md) — thư mục này gitignore (ảnh có lời bài hát, không đưa lên git công khai).
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${1:-$(ls -t "$HOME/Movies/KaraokeMaker Projects/"*.kbproj 2>/dev/null | head -1)}"
[ -e "$PROJECT" ] || { echo "Không tìm thấy dự án .kbproj để mở"; exit 1; }   # .kbproj có thể là file zip hoặc thư mục gói

BUILD=".build-guitest"
OUT=".ui-check/$(date '+%Y%m%d-%H%M%S')"
APP=".ui-check/KaraokeMaker UI-CHECK.app"
mkdir -p "$OUT/work"

echo "▶︎ Build bản kiểm thử (lần đầu lâu hơn vì thư mục build riêng)…"
if ! swift build -c release -Xswiftc -DKM_DEV_RUNTIME -Xswiftc -DKM_GUITEST --build-path "$BUILD" >"$OUT/build.log" 2>&1; then
    grep -E "error" "$OUT/build.log" | head -20
    echo "❌ Build lỗi — dừng (không chụp bằng bản cũ). Chi tiết: $OUT/build.log"; exit 1
fi
grep -E "Build complete" "$OUT/build.log" || true
BIN="$BUILD/release/KaraokeMaker"

echo "▶︎ Đóng gói…"
rm -rf "$APP"
cp -R dist/KaraokeMaker.app "$APP"
cp -f "$BIN" "$APP/Contents/MacOS/KaraokeMaker"
cp -f "$BUILD/release/libonnxruntime.dylib" "$APP/Contents/MacOS/libonnxruntime.dylib"
rm -rf "$APP/Contents/MacOS/KaraokeMaker_KaraokeMaker.bundle" "$APP/Contents/Resources/KaraokeMaker_KaraokeMaker.bundle" \
       "$APP/Contents/MacOS/whisper.framework"
cp -R "$BUILD/release/KaraokeMaker_KaraokeMaker.bundle" "$APP/Contents/Resources/"
install_name_tool -add_rpath @executable_path "$APP/Contents/MacOS/KaraokeMaker" 2>/dev/null || true
xattr -cr "$APP" || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

cp -R "$PROJECT" "$OUT/work/"
PROJ_COPY="$(cd "$OUT/work" && pwd)/$(basename "$PROJECT")"
DRV="$(cd "$OUT" && pwd)/driver"
mkdir -p "$DRV"

echo "▶︎ Chạy + chụp + đo…"
KM_GUITEST_DIR="$DRV" "$APP/Contents/MacOS/KaraokeMaker" >"$OUT/app.log" 2>&1 &
APP_PID=$!
trap 'kill $APP_PID 2>/dev/null || true' EXIT

python3 - "$DRV" "$OUT" "$PROJ_COPY" "$APP_PID" <<'PY'
import json, os, subprocess, sys, time
drv, out, proj, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
seq = [0]

def cmd(op, **kw):
    seq[0] += 1
    kw.update(op=op, id=seq[0])
    resp = os.path.join(drv, "resp.json")
    if os.path.exists(resp): os.remove(resp)
    with open(os.path.join(drv, "cmd.json.tmp"), "w") as f: json.dump(kw, f)
    os.replace(os.path.join(drv, "cmd.json.tmp"), os.path.join(drv, "cmd.json"))
    t0 = time.time()
    while time.time() - t0 < 30:
        try:
            r = json.load(open(resp))
            if r.get("id") == seq[0]: return r
        except Exception: pass
        time.sleep(0.1)
    return {"ok": False, "error": "timeout " + op}

def cpu_seconds():
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not t: return None
    parts = [float(x) for x in t.replace("-", ":").split(":")]
    s = 0.0
    for p in parts: s = s * 60 + p
    return s

def rss_mb():
    t = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return round(int(t) / 1024) if t else None

def measure(secs):
    a = cpu_seconds(); time.sleep(secs); b = cpu_seconds()
    return round((b - a) / secs * 100, 1) if a is not None and b is not None else None

# Chờ app sẵn sàng
t0 = time.time()
while not os.path.exists(os.path.join(drv, "hello.json")):
    if time.time() - t0 > 90: sys.exit("App không khởi động được (xem app.log)")
    time.sleep(0.3)
time.sleep(2)
report = {"project": os.path.basename(proj), "shots": [], "cpu": {}, "notes": []}

def shot(name, window=None, size=(1440, 900)):
    # Ép lại cỡ cửa sổ trước MỖI ảnh: app tự "bung full màn hình" lần đầu cửa sổ được chọn (có thể xảy ra giữa chừng).
    if size and not window:
        cmd("resize", w=size[0], h=size[1]); time.sleep(0.8)
    kw = {"name": name}
    if window: kw["window"] = window
    r = cmd("shot", **kw); report["shots"].append(r); return r

cmd("activate"); time.sleep(1)
shot("01-home-1440x900")
report["cpu"]["home_idle"] = measure(10)

cmd("openproject", path=proj); time.sleep(6)
st = cmd("state"); report["state"] = st.get("project", {})
for name, w, h in [("02-editor-1440x900", 1440, 900), ("03-editor-1180x720-min", 1180, 720), ("04-editor-1920x1080", 1920, 1080)]:
    shot(name, size=(w, h)); time.sleep(0.5)

cmd("resize", w=1440, h=900); time.sleep(2)
report["cpu"]["editor_idle"] = measure(20)
report["rss_mb_idle"] = rss_mb()

# Phát / dừng bằng lệnh riêng của bộ kiểm thử (= bấm nút Play) — không dùng phím Space.
cmd("toggleplay"); time.sleep(3)
report["cpu"]["editor_playing"] = measure(20)
report["rss_mb_playing"] = rss_mb()
shot("05-editor-playing")
cmd("toggleplay"); time.sleep(5)
report["cpu"]["editor_after_stop"] = measure(10)
cmd("resize", w=1440, h=900); time.sleep(1)

# Từng tab cột trái + bảng Xuất — qua lệnh kiểm thử "ui" (không cần chuột / cửa sổ đang được chọn).
for name, what in [("10-tab-tao-karaoke", "steps"), ("11-tab-nen-video", "background"), ("12-tab-sua-loi", "lyrics"),
                   ("13-tab-them-text", "text"), ("14-tab-song-nhac", "visualizer"), ("15-tab-media", "files")]:
    cmd("ui", what=what); time.sleep(1.2); shot(name)
cmd("ui", what="export"); time.sleep(1.5)
if not shot("20-export-sheet", window="sheet").get("ok"): report["notes"].append("không mở được bảng Xuất")
cmd("ui", what="closeexport"); time.sleep(1)

cmd("quit"); time.sleep(3)
json.dump(report, open(os.path.join(out, "report.json"), "w"), ensure_ascii=False, indent=2)

c = report["cpu"]
lines = [f"# UI check — {time.strftime('%Y-%m-%d %H:%M')}", "",
         f"Dự án: `{report['project']}` · dòng lời {report['state'].get('lines', '?')} (đã canh {report['state'].get('timedLines', '?')})", "",
         "| Đo (CPU của app, % 1 nhân) | Kết quả |", "|---|---|",
         f"| Home đứng yên (10 s) | {c.get('home_idle')} % |",
         f"| Editor đứng yên (20 s) | {c.get('editor_idle')} % |",
         f"| Editor đang phát (20 s) | {c.get('editor_playing')} % |",
         f"| Dừng phát, chờ 5 s rồi đo (10 s) | {c.get('editor_after_stop')} % |",
         f"| Bộ nhớ (đứng yên / đang phát) | {report.get('rss_mb_idle')} / {report.get('rss_mb_playing')} MB |", "",
         "## Ảnh"]
for s in report["shots"]:
    if s.get("ok"): lines.append(f"- `{os.path.basename(s['path'])}` — {int(s['size'][0])} × {int(s['size'][1])}")
if report["notes"]:
    lines += ["", "## Ghi chú"] + ["- " + n for n in report["notes"]]
open(os.path.join(out, "report.md"), "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
PY

rm -rf "$OUT/work" "$DRV/cmd.json" 2>/dev/null || true
mv "$DRV"/*.png "$OUT/" 2>/dev/null || true
echo "✅ Kết quả: $OUT"
