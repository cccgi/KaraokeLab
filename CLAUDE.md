# KaraokeMaker — Project Law

Native **macOS karaoke / audio editor**. Mục tiêu: một pro editor kiểu CapCut/Final Cut
(bố cục, timeline UX, trim/split/zoom, inspector, phím tắt). Tạo karaoke chỉ là **một**
chức năng trong app.

## ⛔ TUYỆT ĐỐI KHÔNG ĐỤNG — "chức năng tạo karaoke"
Không sửa / refactor / "cải thiện" các file sau (thuật toán canh lời — đã ổn, nhiều lần
sửa hỏng, user cấm):

- `Sources/KaraokeMaker/Services/LocalAligner.swift` (nhánh `fullPaste` "lời đủ", `alignBySearch`)
- `Sources/KaraokeMaker/Services/AdvancedKaraoke.swift` (`parseBlocks`, `capRunaway`, `smoothWordGaps`, `borrowRepeatRhythm`, `tidyOverlaps`, `run()`)
- `Sources/KaraokeMaker/Services/ForcedAligner.swift` (MMS ONNX CTC, `buildLines`)
- `Sources/KaraokeMaker/Services/WordTiming.swift`, `AudioOnsetDetector.swift`
- `Sources/KaraokeMaker/Services/MDXSeparator.swift`, `LocalSeparator.swift`, `BeatSeparation.swift` (tách nhạc — nuôi aligner + beat)
- `Sources/KaraokeMaker/App/AlignTestCLI.swift`

Được phép: đọc / hiển thị / cho user **chỉnh tay** `LyricLine.words[].start/end` qua timeline
& inspector. KHÔNG được đổi cách các file trên **tính ra** timing. Nếu có ý tưởng dính tới
đó → ghi vào `docs/KNOWN_ISSUES.md`, KHÔNG code.

## Build / Run
- **Swift Package** (không phải .xcodeproj). `swift-tools 5.9`, macOS 13, build **x86_64**.
- Build: `swift build -c release` (trên iMac Intel, ~60–110s).
- Chạy thử (2026-09-29, luật của chủ dự án): làm xong MỖI việc → kết bằng ĐÚNG 1 khối mở BẢN THỬ riêng
  (không đụng app chính `dist/`):
  ```
  cd ~/ClaudeProjects/KaraokeApp && ./Scripts/pack-test.sh
  ```
  (build + đóng gói "~/Desktop/KaraokeMaker THIẾT KẾ MỚI.app" + mở). Không tự chạy khối đó. Chỉ khi chủ dự án
  thử xong và nói OK / "update" mới cập nhật app chính (`./Scripts/pack-local.sh` → `~/Desktop/KaraokeMaker`)
  và đưa lên git. Không gửi file `.app` qua chat. (`push-m4.sh` qua MacBook — chỉ khi user yêu cầu lại.)
- `swift build` có thể "database is locked" nếu lần build trước chưa xong — chờ
  `pgrep -f "swift-build -c release"` hết rồi build lại.

## Quy tắc làm việc
1. Đọc file này + `docs/PROGRESS.md` + `docs/ROADMAP.md` trước khi sửa.
2. Sửa timeline → đọc `docs/ARCHITECTURE.md` §Timeline. Sửa audio/clock → §Playback.
   Sửa MÀU (`ImageFX` / `ColorAdjust` / `Compositor` color) → đọc `docs/COLOR_ENGINE.md` +
   `docs/COLOR_ENGINE_AUDIT.md`. Đang có dự án rebuild Color Engine theo phase C0–C11 —
   ENGINE trước, UI sau, không thêm slider giả, mỗi control phải qua acceptance test.
3. Không rewrite mù. Không migrate SwiftUI↔AppKit vì "thích". Giữ hybrid hiện tại.
4. Feature "xong" = data model + logic + state + UI + interaction + playback + undo (nếu hợp) + build OK.
   Không làm nút/slider giả.
5. Mọi mutation project đi qua `store.perform("tên") { … }` hoặc `store.edit(...)` → 1 undo / thao tác.
   Kéo/thả: begin → preview (không đụng store) → commit 1 lần ở mouseUp.
6. TIME là nguồn sự thật, không phải pixel. Clip lưu bằng giây, view chỉ là projection.
7. Clock chuẩn duy nhất = `PlaybackController` (`renderTime` / `currentTime` / `clock.seconds`).
   Không tạo Timer riêng làm nguồn thời gian.
8. User: non-programmer, đọc **tiếng Việt**, giải thích NGẮN trước khi đổi lớn, làm theo lô,
   xong lô nào build + đưa lệnh test + liệt kê "phần tiếp theo". Không "làm 1 bước hỏi 1 bước".
9. Xong việc: cập nhật `docs/PROGRESS.md` + `docs/FEATURE_MATRIX.md` (+ `KNOWN_ISSUES.md` nếu cần).

## Git — đồng bộ 2 máy (từ 2026-09-29, user đã đồng ý)
- Repo app: https://github.com/cccgi/KaraokeLab — **CÔNG KHAI**. Lab `~/viet_lyrics_lab` có repo **RIÊNG TƯ** riêng
  (khoilephoto/viet-lyrics-lab) — KHÔNG bao giờ đưa lab, lời bài hát, audio, model, `.build*` lên repo app.
- Mở phiên: hook `.claude/settings.json` tự `git pull --ff-only`. Nếu hook báo "KHÔNG thành công" → trước khi làm việc:
  `git status`; có thay đổi dở → commit; lệch nhánh → `git pull --rebase`, gỡ xung đột (giữ thay đổi của CẢ HAI người), báo user.
- **KHÔNG tự commit / push** (luật mới 2026-09-29): làm xong → đưa khối mở bản thử; CHỈ khi chủ dự án thử xong và yêu cầu
  "update lên git" mới `git add -A && git commit -m "<mô tả ngắn>" && git pull --rebase && git push`. Trước commit xem
  `git status`: không file > 50 MB.
- Push bị chặn (thiếu đăng nhập / hệ thống an toàn) → đưa user ĐÚNG 1 lệnh để bấm Run.
- Hai người tránh sửa cùng 1 file cùng lúc; ai làm phần nào thì ghi vào `docs/PROGRESS.md`.

## Bản đồ nhanh
- Vỏ app: `Views/RootView.swift` (Home ⇄ editor theo tab), `HomeView`, `Services/ProjectTabs.swift`, `ProjectLibrary`.
- Editor: `Views/ContentView.swift` (~2900 dòng — 3 cột + syncBar + timeline + toolbar; nhiều `timeline*`/`overlay*` handler ở đây).
- Timeline: `Views/TimelineEditor.swift` (SwiftUI wrapper + `TimelineCanvasView` AppKit).
- Preview: `Views/KaraokePreview.swift` (+ `KaraokePreviewCanvas` AppKit).
- Playback: `Services/PlaybackController.swift` (AVAudioPlayer + `PlaybackClock` + transport ảo).
- Compositing (preview + export dùng chung): `Rendering/Compositor.swift`.
- Persistence: `Services/ProjectStore.swift` → `.kbproj` JSON (Codable "khoan dung").
- Style presets: `Services/StylePresetStore.swift` + `Views/StylePanel.swift`.
- **Tạo Karaoke 2 đường** (bước 2 của tab "Tạo Karaoke"): "Tôi có lời" (đường cũ) / "Không cần lời — Tự động tạo Karaoke" (`Services/AutoLyrics/AutoKaraokeFlow.swift` + `Views/AutoKaraokePanel.swift`; ASR = `AutoLyricsController` + helper Python `Resources/lyric_asr/`, qwen-asr chính thức, tiến trình riêng). CẢ HAI đường canh giờ bằng CÙNG hàm `ContentView.runKaraokeTiming` → `AdvancedKaraoke.run` — KHÔNG tạo bộ canh giờ thứ 2, KHÔNG sửa file cấm. Lời tự sinh = văn bản thuần; từ chưa chắc gắn lại sau khi canh giờ (`UncertaintyMapper`, chỉ bộ nhớ). Runtime (Python+PyTorch+2 mô hình) đóng gói TRONG app: `Contents/Resources/AutoLyricsRuntime`; đường dẫn dev chỉ khi DEBUG/`-DKM_DEV_RUNTIME`; bộ điều khiển GUI test chỉ khi `-DKM_GUITEST`.
- **Đóng gói phát hành** (không đụng `dist/`): `Scripts/asr-runtime/{trace_imports,build_runtime}.py` dựng runtime theo kiến trúc → `Scripts/package-release.sh --arch x86_64|arm64` → `Scripts/audit-release.sh`. Kết quả ở `dist-release/` (gitignore). Chưa ký Developer ID / notarize / license / Sparkle — CHỈ làm khi user đồng ý.
