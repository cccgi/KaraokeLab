# FEATURE MATRIX — audit 2026-09-06

Status: NOT_STARTED · PARTIAL · FUNCTIONAL · VERIFIED · BROKEN · NEEDS_REFACTOR
("VERIFIED" = user đã xác nhận chạy đúng trên M4. Phần lớn phần mới đang chờ test → FUNCTIONAL.)

| # | Feature | Status | Ghi chú |
|--|--|--|--|
| 1 | Application shell (Home + thư viện + đa tab) | VERIFIED | `RootView`/`HomeView`/`ProjectTabs`/`ProjectLibrary`. |
| 2 | Media import (nhạc, ảnh, video vào kho) | FUNCTIONAL | `mediaPool`, `handleMediaPoolFileDrop`, `FilePanels`. |
| 3 | Audio playback (play/pause/seek/scrub) | VERIFIED | `PlaybackController` (AVAudioPlayer). Clock chuẩn. |
| 3b | Transport ẢO khi CHƯA có nhạc | FUNCTIONAL | seek/play trên timeline không cần audio (2026-09-06). |
| 4 | Waveform | VERIFIED | `WaveformLoader` → `playback.waveform`, NSImage cache trong canvas. Chưa gắn sourceIn/Out (chưa có audio-clip model). |
| 5 | Timeline hiển thị + scroll ngang + zoom | VERIFIED | `TimelineCanvasView`. Zoom qua `EditorCommand` (toolbar + menu ⌘=/⌘−/⌘0 + ⌘scroll + pinch). |
| 6 | Playhead + seek + scrub | VERIFIED | CALayer + CoreAnimation khi phát. Click thước/vùng trống = tua. |
| 7 | Track headers (cột trái) | FUNCTIONAL | Nhạc (🔇 tắt tiếng) / Lời (👁 ẩn lớp chữ) / Lớp đè 1–3 (👁 ẩn + 🔒 khoá theo làn). |
| 8 | Chọn clip / dòng lời | FUNCTIONAL | M-A: `EditorSelection` = nguồn ĐỌC duy nhất (computed từ `currentLineIndex`+`selectedOverlayID`); `select(_:)` = 1 mutator. Canvas vẫn giữ bản sao đồng bộ 1 chiều (ok). |
| 9 | Dời clip lớp đè (timeline) | FUNCTIONAL | Kéo thân = đổi start; kéo dọc = đổi lane. Snap mép/playhead/0. |
| 10 | Trim clip lớp đè | FUNCTIONAL | Kéo mép = start+duration; VIDEO (M-E): mép trái dời `trimStart` (điểm vào nguồn), kẹp theo `sourceDuration`. Preview + export + split đều theo. |
| 11 | Split clip lớp đè | FUNCTIONAL | ✂️ / ⌘K tại vạch đỏ. Model tách đúng (2 clip, id mới, start/duration đúng). Undo qua `store.perform`. |
| 12 | Delete / Duplicate / Copy-Paste clip lớp đè | FUNCTIONAL | Phím Delete + ⌘C/⌘V (ngoài timeline) + toolbar + context menu + menu bar. |
| 13 | Snapping | FUNCTIONAL | Mép clip khác / vạch đỏ / t=0 / **biên dòng lời** (M-F). Ngưỡng 7px. Output = time. |
| 14 | Kéo file kho → thả đúng làn + mốc | FUNCTIONAL | NSDraggingDestination + tô sáng làn. Thả trúng làn = ripple-insert (đẩy clip sau). |
| 15 | Undo / Redo | FUNCTIONAL | `UndoManager` qua `store.perform`. Drag = 1 undo. Icon trên toolbar + ⌘Z/⌘⇧Z. Chưa audit undo cho mọi path mới. |
| 16 | Keyboard shortcuts | FUNCTIONAL | `handleKeyDown`→`runCommand` (né TextField). Space · [ ] · ←→ tua · , . dời mục chọn · Delete. Canvas giữ word-ops + arrow-nudge khi focus. |
| 38 | Fade in/out clip lớp đè | FUNCTIONAL | `OverlayClip.fadeIn/fadeOut` → `Compositor` opacity ramp (preview + export). Inspector + **kéo tay nắm trên clip** + vẽ dốc. |
| 39 | Dán thuộc tính clip (chỉ look) | FUNCTIONAL | `EditorCommand.pasteClipStyle` — màu/biến hình/blend/fade từ clip đã ⌘C, giữ timing. Menu + context menu. |
| 40 | Đổi tên clip | FUNCTIONAL | Context menu + ✏️ inspector (`TextPrompt`). |
| 41 | Chuyển cảnh (cross-dissolve) | FUNCTIONAL | Context menu clip "Chuyển cảnh mờ với clip trước" → chồng + fadeIn. Compositor vẽ 2 clip = dissolve. |
| 16b | Menu bar (Phát / Timeline / Lời) | FUNCTIONAL | M-B: `KaraokeMakerApp` `CommandMenu` → `editor?.run(...)` qua `focusedSceneValue`. ⌘B = Tách. Chưa có menu View/zoom (M-C). |
| 16c | Context menu timeline (chuột phải) | FUNCTIONAL | M-B: clip → Tách tại đây/Nhân đôi/Xoá; dòng lời → Nhân đôi/Xoá dòng. |
| 17 | Lyrics editor | FUNCTIONAL | `LyricLinesList` (danh sách) + sửa text + `TimingEditor`. |
| 17b | Tab "Sửa lời" (sau khi tạo karaoke) | FUNCTIONAL | `LyricEditPanel`: danh sách CỐ ĐỊNH đánh số (chỉ trên UI), sửa chữ từng dòng, Enter/bấm ra ngoài = cập nhật karaoke, Esc huỷ, ⌘Z hoàn tác. Đi qua `LyricLineEditor` (giữ timing chữ). Tab "Tạo Karaoke" tự ẩn khi đã có dòng canh xong; KHÔNG đổi nhạc/làm lại — chỉ Dự án mới (2026-09-24, chờ test). |
| 17c | Tự động tạo Karaoke — "Không cần lời" | FUNCTIONAL (đã GUI-test Intel + M4) | 2 đường sau khi nhập nhạc: "Tôi có lời" / "Không cần lời". Đường 2: phân tích nhạc → helper Python qwen-asr (0.6B + 1.7B kiểm) → lời văn bản thuần → CÙNG `runKaraokeTiming`/`AdvancedKaraoke.run` với đường 1. Từ chưa chắc theo dõi được trong tab "Sửa lời". Lỗi/Huỷ/thử lại/đổi project đã kiểm. `Services/AutoLyrics/*`, `Views/AutoKaraokePanel.swift`, `Resources/lyric_asr/`. Độ chính xác đo 2026-09-25: ~22–25% từ sai trên bài mới (xem KNOWN_ISSUES) — chưa đạt mục tiêu. |
| 17d | Đóng gói tự chứa (Python+PyTorch+qwen-asr+2 mô hình trong app) | FUNCTIONAL (ad-hoc, chưa Developer ID) | `Scripts/package-release.sh --arch x86_64|arm64`, `Scripts/audit-release.sh`; 8,0/7,9 GB; offline; không phụ thuộc `~/qwen3_asr_*`. Chưa ký/notarize. |
| 18 | Line timing (chỉnh tay) | FUNCTIONAL | Kéo block trên timeline, set start/end, phím [ ]. |
| 19 | Word timing (chỉnh tay) | FUNCTIONAL | Kéo mép ô chữ, S tách / M gộp tại vạch đỏ. |
| 20 | **Tạo karaoke (canh lời tự động)** | ⛔ KHÓA | `LocalAligner`/`AdvancedKaraoke`/`ForcedAligner`. KHÔNG ĐỤNG. Chờ user test riêng. |
| 21 | Karaoke preview | VERIFIED | `KaraokePreviewCanvas` đọc `renderTime`, không timer riêng. |
| 22 | Karaoke highlight (progress theo timing) | VERIFIED | Seek/pause/resume đồng bộ. |
| 23 | Kéo chữ / gizmo lớp đè / sóng nhạc trên preview | VERIFIED | Kéo–giãn–xoay trực tiếp. Kéo phóng clip hít "vừa khung" (2026-09-06). |
| 24 | Inspector (context theo selection) | FUNCTIONAL | Overlay: Độ mờ/Hoà trộn/Đè-trên-chữ/Vừa khung/Phủ kín/Đổi ảnh + Màu sắc. Lời: `StylePanel`. Bỏ tab Thời gian/Biến hình (2026-09-06). |
| 25 | Style presets (dựng sẵn + user lưu + khôi phục) | FUNCTIONAL | `StylePresetStore` + `.style-presets.json`. Ẩn/hiện preset dựng sẵn, "Khôi phục mặc định". |
| 26 | Background ảnh / video (Mode C) | FUNCTIONAL | `backgroundMedia`, `VideoBackgroundView`, Ken Burns. |
| 27 | Color controls (nền + lớp đè) | FUNCTIONAL | `ColorAdjust` → `Compositor`/`ImageFX`. Ảnh hưởng preview + export. |
| 28 | Music visualizer ("sóng nhạc") | VERIFIED | `MusicVisualizer` + `VisualizerRenderer` + `SpectrumStore` (FFT vDSP). 7 kiểu. |
| 29 | Project save / load (.kbproj) | VERIFIED | `ProjectStore`, Codable khoan dung, bookmark. |
| 30 | Thumbnail thư viện = ảnh preview | FUNCTIONAL | `ThumbnailRenderer` vẽ lại full frame tại `lastPreviewTime` (2026-09-06). |
| 31 | Export SRT / ASS | VERIFIED | `SrtExporter` / `AssExporter`. |
| 32 | Export video trong suốt | FUNCTIONAL | `.mov` ProRes 4444 (mã hoá NHANH mọi máy). ~~HEVC-alpha~~ đã BỎ 2026-09-07 — user báo xuất chậm ~10× (`hevcWithAlpha` không có tăng tốc phần cứng + chạy Rosetta). Ô "Chất lượng" trong tab Xuất gỡ luôn. |
| 33 | Export video nền đục (Mode C) | FUNCTIONAL | H.264 mp4 / ProRes mov. |
| 34 | Cắt bài + âm lượng + mute + fade (1 bài chính) | FUNCTIONAL | `audioTrimStart/End/Gain/Muted/FadeIn/FadeOut`. Live playback + **XUẤT video theo vùng cắt** (`timeOffset`) + fade âm thanh (`AVMutableAudioMix`). Inspector + 🔇 track header + ⇧⌘M. |
| 34b | Audio NHIỀU clip trên timeline | ⛔ BỎ HẲN | User chốt 2026-09-06 không làm. Bài chính = 1 `AVAudioPlayer`. |
| 35 | Centralized command system | FUNCTIONAL | M-A/M-B: `EditorCommand` + `runCommand/canRun`. Phím tắt + timeline toolbar + menu bar + context menu đều đi qua. Zoom chưa (M-C). |
| 36 | Menu bar đầy đủ (Playback/Timeline/Lyrics/View) | FUNCTIONAL | Phát / Timeline / Lời / Xem (zoom ⌘=/⌘−/⌘0 · ẩn lời ⌘L · tắt tiếng ⇧⌘M). Tất cả qua `EditorCommand`. |
| 37 | Cursor states trên timeline (resize, closed-hand…) | FUNCTIONAL | M-C: `cursorFor(_:)` — mép=resize, thân=hand, kéo=closed-hand. |
| 38 | Tiếng của clip VIDEO lớp đè | FUNCTIONAL | Toggle "Bật tiếng của clip video" (mặc định TẮT). PREVIEW: `OverlayAudioMixer` — mỗi clip 1 `AVPlayer` chỉ-audio, bám `renderTime`, volume theo fade in/out, TÁCH hẳn khỏi bài hát chính. XUẤT: `AudioMux.ExtraAudio` — mỗi clip 1 track + volume ramp, trộn phẳng cùng bài hát chính qua `AppleM4A`. Tôn trọng `trimStart` + cắt bài (`timeOffset`). |
| 39 | Preview overlay video 30fps | FUNCTIONAL | `OverlayVideoFrameStore`: grid 30fps, cache `Int(t*30)`, prefetch 12 khung tới, queue `.userInitiated` concurrent. Thay cho 4fps cũ. |

## COLOR ENGINE (C0 audit 2026-09-06 — chi tiết `COLOR_ENGINE_AUDIT.md`)

| # | Feature | Status | Ghi chú |
|--|--|--|--|
| C-1 | Color management | FUNCTIONAL | `ColorPipeline`: `CIContext` working=extendedLinearSRGB (RGBAh) + output sRGB, reuse. HDR chưa tường minh. |
| C-2 | Exposure | FUNCTIONAL | Kernel `pow(2,ev)` linear, EV ±4. Slider −100…100. Neutral = identity (short-circuit). |
| C-3 | Contrast | FUNCTIONAL | S-curve luỹ thừa quanh mid-grey linear 0.18, không kẹp 0.5. Hằng số chờ tune. |
| C-4 | Highlights | FUNCTIONAL | smoothstep(0.45,1.0) luminance mask, giữ hue. Chờ tune + acceptance test. |
| C-5 | Shadows | FUNCTIONAL | smoothstep(0,0.55). Khác Blacks. |
| C-6 | Whites | FUNCTIONAL | smoothstep(0.80,1.0) — endpoint, khác Highlights. |
| C-7 | Blacks | FUNCTIONAL | smoothstep(0,0.22) — endpoint, khác Shadows. |
| C-8 | Temperature | FUNCTIONAL | `CITemperatureAndTint` x, ±3200K. Chờ tune gray-ramp. |
| C-9 | Tint | FUNCTIONAL | `CITemperatureAndTint` y, ±60. |
| C-10 | Vibrance | FUNCTIONAL | Kernel: `vib·(1−chroma)` — đẩy màu nhạt nhiều hơn. Khác saturation. |
| C-11 | Saturation | FUNCTIONAL | Kernel: mix(grey, rgb, 1+amt). |
| C-12 | Vignette | ACCEPTABLE | `CIVignette` radius cứng — là "effect", không phải tonal. |
| C-13 | Áp màu cho VIDEO | FUNCTIONAL | Overlay video → `Compositor`→`ImageFX`. Nền video: export qua `BackgroundImageStore`; preview qua `AVMutableVideoComposition` (cùng `ColorPipeline`). |
| C-14 | Preview ↔ Export parity (màu) | FUNCTIONAL | 1 `ColorPipeline` cho ảnh + video (kể cả nền video preview). |
| C-15 | Tone Curves | FUNCTIONAL | `ToneCurve` monotone-cubic → color cube. UI `ToneCurveGraph` (kéo điểm, dbl-click). Master+R/G/B. |
| C-16 | HSL / selective | FUNCTIONAL | Kernel `kmHSL` 8 dải, weight smoothstep circular. UI menu dải + 3 slider. |
| C-17 | LUT (.cube) | FUNCTIONAL | `parseCube` → `CIColorCubeWithColorSpace` + intensity blend (`kmMix`). |
| C-18 | Histogram + Scopes | FUNCTIONAL | `ColorScopes`: Biểu đồ (`CIAreaHistogram`) + RGB Parade + Vectorscope (`scopeSamples`). Ảnh/nền-ảnh. |
| C-19 | Trước/Sau + Copy/Paste + Preset màu | FUNCTIONAL | `ColorPipeline.bypass` + `copiedColor` + `ColorPresetStore` (.color-presets.json). |
| UI-1 | Hệ thiết kế (token màu/chữ/khoảng cách/bo góc/chiều cao, nút 3 cấp, PanelHeader, ChoiceCard) | FUNCTIONAL | `Views/Theme.swift`, quy chuẩn `docs/DESIGN_SYSTEM.md`, đánh giá `docs/UI_REVIEW_FINAL.md`. Chờ chủ dự án duyệt bản thử (`Scripts/pack-test.sh`). |
| UI-2 | Thiết kế lại 9 khu (toolbar, cột trái, preview, inspector, timeline, luồng lời, màu, xuất, hộp thoại/Home) | FUNCTIONAL | 2026-09-29. Không đổi thuật toán / engine. Còn tồn: inspector Nhạc/Dự án, segmented khung hình xuất (xem UI_REVIEW_FINAL §7). |
| UI-3 | Tab "Sửa lời" đi theo vạch đỏ (dòng đang hát sáng + nằm giữa) | FUNCTIONAL | `LyricFollowTicker` cục bộ trong `LyricEditPanel` (không dựng lại `ContentView`). |
| UI-4 | Từ chưa chắc gạch chân trên timeline | FUNCTIONAL | `TimelineCanvasView.setUncertainWordKeys` — chỉ khi số ô chữ khớp số từ trong câu. |
| UI-5 | Ảnh thu nhỏ có cache (kho Media + Home) | FUNCTIONAL | `MediaThumbCache` (ImageIO) — trước giải mã nguyên ảnh mỗi lần vẽ lại. |
