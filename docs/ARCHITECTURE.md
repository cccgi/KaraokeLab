# ARCHITECTURE — trạng thái THỰC TẾ (audit 2026-09-06)

Swift Package, SwiftUI + AppKit hybrid, macOS 13, x86_64. Không có `.xcodeproj`.
Không dùng Combine nhiều (vài `@Published` sink). Có Swift Concurrency (`Task`, `@MainActor`).

## Lifecycle / shell
- `KaraokeMakerApp` (`App/KaraokeMakerApp.swift`): 1 `WindowGroup`. `@StateObject`:
  `ProjectTabs`, `PlaybackController`, `StylePresetStore`. `.commands`: chỉ thay
  `.saveItem` và `.undoRedo` — **chưa có menu Playback/Timeline/Lyrics/View**.
- `RootView`: Home (lưới project) ⇄ editor. `editingTabIDs: Set<UUID>` quyết định tab nào
  đang mở editor. Đa project = `ProjectTabs` (tab bar tự vẽ). Mỗi tab có `ProjectStore` riêng;
  `PlaybackController` **dùng chung 1 instance** cho mọi tab.
- `ContentView`: editor thật. 3 cột (`leftPanel` / `centerColumn` preview / `inspectorColumn`)
  trong `HSplitView`, dưới là `syncBar` + `timelineArea` trong `VSplitView`. (2026-09-29) Tách khỏi
  1 file ~4700 dòng thành `ContentView.swift` (struct + `@State`/`@StateObject` + `body`/
  `mainLayout` — property lưu trữ BẮT BUỘC nằm ở đây, Swift extension không khai báo được) +
  13 file `ContentView+<Khu>.swift` theo đúng khu UI (`+Toolbar`, `+CreateKaraoke`, `+Inspector`,
  `+PreviewCenter`, `+ColorPanel`, `+Visualizer`, `+OverlaysAndMedia`, `+TimelineChrome`,
  `+ExportPanel`, `+Commands`, `+KeyboardAndTimeline`, `+AudioAndLyrics`, `+ExportActions`,
  `+Proxies`) — THUẦN di chuyển code (`extension ContentView { … }`), không đổi 1 dòng logic nào;
  `private` cross-file được nới thành mặc định `internal` (cùng module, không lộ ra ngoài app).
  Chứa hầu hết handler nghiệp vụ (`timelineOverlayMove`, `seekTo`, `exportTransparentVideo`, …).

## State / ownership
- `ProjectStore` (`@MainActor ObservableObject`): `@Published project: KaraokeProject`,
  `fileURL`, `hasUnsavedChanges`, `lastError`. `lastPreviewTime` (không @Published) cho thumbnail.
  Undo: `store.perform(name) { mutate } ` / `store.edit(name) { }` — đăng ký `UndoManager`
  (levelsOfUndo 200), 1 undo / thao tác. `store.newProject/open/save/write`.
- `KaraokeProject` (struct, `Equatable` + Codable "khoan dung" — mọi field `decodeIfPresent ?? default`).
  Chứa: `audio: AudioReference?`, `resolution: VideoResolution`, `style`/`nextLineStyle: KaraokeStyle`,
  `lines: [LyricLine]`, `overlays: [OverlayClip]`, `mediaPool: [MediaPoolItem]`,
  `backgroundMedia`, `visualizer: MusicVisualizer?`, `exportSettings`, `singerColors`, timing offsets.
- Selection: **chưa tập trung**. `currentLineIndex: Int` (ContentView @State) cho dòng lời;
  `selectedOverlayID: UUID?` (ContentView @State) cho clip lớp đè; canvas giữ bản sao
  `selIDs/selWord/selOverlayID` và đồng bộ 1 chiều qua `applyState`. Inspector `inspectorColumn`
  chọn nội dung theo `selectedOverlayID != nil` ? overlay : lời.

## Playback / editor clock  (nguồn sự thật thời gian)
`Services/PlaybackController.swift` — **clock chuẩn duy nhất**.
- Engine: `AVAudioPlayer` (đơn giản; word-level chính xác tới ~vài ms).
- `currentTime` (không @Published, đọc trực tiếp), `clock.seconds` (`PlaybackClock`, ~8Hz, chỉ
  vài ô nhỏ theo dõi để ContentView không dựng lại 30fps), `renderTime` (nội suy theo host clock
  khi đang phát — canvas đọc cái này để vẽ mượt), `seekGeneration` (@Published, bump mỗi seek/nạp).
- **Transport ẢO** (2026-09-06): chưa nạp nhạc vẫn `seek`/`play` được trên timeline —
  `virtualDuration` (do `TimelineEditor` set), `virtualTicker` 8Hz, `virtualPlaying`.
  `seekCeiling = isLoaded ? duration : virtualDuration`.
- `swapSource` đổi file giữ vị trí (bật/tắt beat karaoke).
- Canvas vẽ playhead bằng **CoreAnimation** (`CABasicAnimation` position.x) khi phát → mượt,
  không tốn main thread; main chỉ đụng lúc play/pause/seek/zoom.

## Timeline  (`Views/TimelineEditor.swift`)
- `TimelineEditor` (SwiftUI): header (toolbar: ✂️ tách / ▣ nhân đôi / 🗑 xoá / zoom ± / Vừa khung),
  `trackHeaderColumn` (cột trái cố định: Nhạc / Lời / Lớp đè 1–3, mỗi làn lớp đè có 👁 ẩn + 🔒 khoá),
  rồi `TimelineScrollRepresentable` (NSScrollView ngang) bọc `TimelineCanvasView` (NSView).
- Toạ độ: `pointsPerSecond` (zoom, 8…400) × time. `x = t * pps`. `duration` (SwiftUI computed) =
  `max(playback.duration, cuối overlay+10, cuối lời+10, 60)` → set vào `playback.virtualDuration`.
  Công thức x nằm rải trong canvas (chưa có 1 abstraction `timeToX/xToTime` tập trung — xem KNOWN_ISSUES).
- Canvas vẽ: ruler + nhãn "Nhạc"/"Lời" + waveform (NSImage cache) + dải lời (mỗi `LyricLine` timed
  1 block, câu active tách thanh DÒNG / hàng CHỮ; kéo mép block = giãn phần chờ, kéo mép ô chữ =
  chỉnh nhịp word) + track "tạm" (staging, cam) + dải "Lớp đè" (clip tím).
- Overlay clip trên timeline (2026-09-06): kéo thân = dời (ngang đổi `start`, dọc đổi `lane`),
  kéo mép = trim (`start`+`duration`), ✂️/⌘K = tách tại vạch đỏ, nhân đôi, Delete = xoá. Snap
  vào mép clip khác / vạch đỏ / t=0 (ngưỡng 7px, giữ ⌘ để tắt). Kéo file kho thả xuống → rơi
  đúng làn + mốc (`TimelineCanvasView` là NSDraggingDestination).
- Drag pattern: `pending(Hit, downPoint)` → vượt threshold 3px → `promote` sang state cụ thể →
  `updatePreview` (chỉ vẽ, không đụng store) → `mouseUp` commit 1 lần (`holdPreview` giữ preview
  tới khi `applyState` nhận model mới → không giật).

## Karaoke model + preview
- `Models/LyricLine.swift` (`id`, `text`, `start`/`end: TimeInterval?`, `words: [LyricWord]`,
  `singer: SingerRole?`, flags). `Models/LyricWord.swift` (`text`, `var start/end: TimeInterval?`).
- `Services/TimingEditor.swift` — helper thuần dữ liệu (set/clear start-end, firstUntimedIndex,
  activeIndex tại time…). Dùng cho chỉnh tay, KHÔNG phải aligner.
- Preview: `KaraokePreview` (SwiftUI) + `KaraokePreviewCanvas` (NSView, `DisplayLink` ~60Hz khi phát,
  đọc `playback.renderTime` — KHÔNG timer riêng). Kéo chữ chính / câu nhắc / sóng nhạc / gizmo lớp đè
  ngay trên preview. Vẽ qua `KaraokeRenderer.drawPreview` + `Compositor` + `VisualizerRenderer`.
- Highlight = progress theo timing model tại `renderTime` (seek/pause/resume đúng ngay).

## ⛔ Tạo karaoke (KHÔNG ĐỤNG — xem CLAUDE.md)
`AdvancedKaraoke.run()` : `parseBlocks` → tách nhạc (`MDXSeparator`) → `LocalAligner.alignBySearch`
→ `ForcedAligner.buildLines(preroll: 2.0)` → `capRunaway` → `smoothWordGaps` → `borrowRepeatRhythm`
→ `tidyOverlaps`. MMS aligner ONNX (`mms-aligner-uint8.onnx`, CTC Viterbi). CLI: `--align-test`,
`--separate`.

## Compositing / preview↔export parity
`Rendering/Compositor.swift` — layer model dùng CHUNG. `previewBackgroundLayers` / `overlayLayers`
(`zone: .belowText/.aboveText`, tham số `videoFrame` cho overlay video) / `exportBackgroundLayers`.
`Compositor.Blend` (normal/multiply/screen/overlay/soft/hard/lighten/darken/difference/exclusion).
`OverlayImageStore` (cache ảnh), `OverlayVideoFrameStore` (khung video async, cache `Int(t*4)`).

## Export
`Rendering/TransparentVideoExporter.swift` (`VideoFrameWriter.write` off-main):
- Trong suốt: `alphaCodec` = `HEVCAlpha` (mặc định, nhẹ) hoặc `ProRes4444`. `.mov`.
- Nền đục: H.264 `.mp4` (hoặc ProRes `.mov` nếu `preferProRes`).
- Nền video Mode C: `BackgroundVideoReader` đọc tuần tự. Overlay video: 1 reader / clip.
- Ghép tiếng bước 2 bằng `AudioMux.merge` (tránh deadlock 2 track).
`SrtExporter` / `AssExporter` cho phụ đề.

## Thumbnail thư viện
`Rendering/ThumbnailRenderer.generate(for:projectURL:atTime:)` — vẽ lại đúng khung preview
(nền ảnh/khung video/tối + sóng nhạc + overlay + chữ) tại `lastPreviewTime` (hoặc giữa câu
đầu có chữ). Chạy nền trong `ProjectStore.write`.

## Persistence & file access
`.kbproj` JSON. `ProjectLibrary` quét `~/Movies/KaraokeMaker Projects`. `OverlayClip`/`MediaPoolItem`/
`AudioReference` dùng **security-scoped bookmark** + fallback path. `.style-presets.json` cho preset user.

## Concurrency
`@MainActor`: `ProjectStore`, `PlaybackController`, `StylePresetStore`, `TransparentVideoExporter`.
Heavy off-main: `WaveformLoader.load`, `SpectrumStore.analyze`, `VideoFrameWriter.write`,
`ThumbnailRenderer.generate`, `MDXSeparator`. Có vài warning Swift 6 (NSLock trong async,
captured var) — không chặn build.
