# ROADMAP — điều chỉnh theo trạng thái THỰC TẾ

App KHÔNG bắt đầu từ 0. Đa số nền móng (shell, playback clock, timeline coord cơ bản,
waveform, preview, undo, persistence, export) đã **FUNCTIONAL/VERIFIED**. Roadmap dưới đây
chỉ gồm phần CÒN THIẾU hoặc CẦN REFACTOR, xếp theo dependency.

## Nguyên tắc
- Mỗi milestone = vài vertical slice (UI + logic + model + playback + undo + build).
- Không đụng "tạo karaoke" (xem `CLAUDE.md`).
- Xong slice: build → đưa lệnh test M4 → cập nhật `PROGRESS.md` + `FEATURE_MATRIX.md`.

## M-A · Selection & Command foundation  ← LÀM TRƯỚC (nhiều thứ phụ thuộc)
Lý do: split/trim/delete/inspector/menu/shortcut hiện gọi code khác nhau; selection rải 3 nơi.
- [ ] `EditorSelection` tập trung (enum: `.none` / `.lyricLine(id)` / `.lyricWord(line,word)` / `.overlay(id)`).
      ContentView + canvas + inspector đọc từ 1 nguồn.
- [ ] `EditorCommand` + `run(_:)` — split / delete / duplicate / nudge / "set start/end tại playhead".
      Toolbar + context menu + phím + menu bar gọi CÙNG hàm. `isEnabled(_:)` theo selection.
- [ ] Chuyển `handleKeyDown` + `keyDown` canvas về gọi `EditorCommand`. Giữ context-aware
      (TextField focus → không nuốt phím).

## M-B · Menu bar macOS
- [ ] `CommandMenu` Playback (Space, ←/→, ⇧←/→), Timeline (Split ⌘B, Zoom ⌘= / ⌘-, Fit),
      Lyrics (dòng trước/sau, set start/end), View. Tất cả gọi `EditorCommand`.
- [ ] Đồng bộ enable/disable với selection + trạng thái.

## M-C · Timeline coord abstraction + cursors
- [ ] 1 struct `TimelineMetrics { pps, scrollX, trackHeaderW }` với `timeToX/xToTime/durationToWidth`.
      Xoá công thức `t*pps` rải rác trong canvas.
- [ ] Cursor: thân clip = open/closed hand, mép = resize-LR, thước = arrow. Hit area mép ≥ 8px.

## M-D · Cắt / âm lượng / fade cho BÀI HÁT CHÍNH — XONG (slice 1 + 1b)
- [x] `audioTrimStart/End/Gain/Muted/FadeIn/FadeOut` — live playback + XUẤT + fade âm thanh.
- ⛔ **Nhạc NHIỀU clip trên timeline (AudioClip + mixer): BỎ HẲN** (user chốt 2026-09-06).
      Không làm. Bài hát chính vẫn là 1 `AVAudioPlayer` duy nhất.
- (còn có thể làm nếu user muốn: hiện vùng cắt trên track "Nhạc" + kéo mép ngay trên sóng.)

## M-E · Overlay video hoàn chỉnh — XONG (2026-09-06 → 2026-09-07)
- [x] Trim-in cho clip video (`OverlayClip.trimStart`) — `Compositor.overlayLayers` + exporter + kéo mép trái.
- [x] Preview overlay video mượt hơn — `OverlayVideoFrameStore` grid 30fps + prefetch 12 khung + queue concurrent.
- [x] Tiếng của clip video overlay — `OverlayClip.videoAudioOn` (mặc định TẮT).
      PREVIEW `Services/OverlayAudioMixer.swift` (AVPlayer chỉ-audio/clip, ticker 12Hz bám `renderTime`,
      TÁCH khỏi bài chính). XUẤT `AudioMux.ExtraAudio` (track/clip + volume ramp, trộn AppleM4A).

## M-F · UX polish
- [ ] Track "Lời": nút ẩn/hiện trong preview (cần cờ ở project + `Compositor`/`KaraokeRenderer`).
- [ ] Snap thêm: biên dòng lời, đầu/cuối bài.
- [ ] Kéo file kho: chèn giữa 2 clip đẩy clip sau (ripple) — tuỳ chọn.
- [ ] Trạng thái rỗng / onboarding gọn.

## M-G (để CUỐI) · "Tạo karaoke" thành công cụ trên timeline
- [ ] Kết quả canh lời hiện thành 1 track lời có thể kéo/tắt — CHỈ đọc kết quả, KHÔNG sửa thuật toán.

---

# COLOR ENGINE — C0…C11  (chi tiết: `docs/COLOR_ENGINE.md`, `docs/COLOR_ENGINE_AUDIT.md`)

Yêu cầu user 2026-09-06: xây lại COLOR PROCESSING SUBSYSTEM cho nghiêm túc (Camera Raw / Lightroom /
CapCut / FCP / Resolve về UX). ENGINE trước, UI sau. Không thêm slider giả. KHÔNG đụng karaoke.

- **C0 · Audit** — XONG. `COLOR_ENGINE_AUDIT.md`. Root cause: ROOT-C1 thiếu tonal-region family;
  ROOT-C2 contrast naïve; ROOT-C3 KHÔNG áp cho video; ROOT-C4 không quản lý màu; ROOT-C5 slider map tuyến tính.
- **C1–C7 · Basic Color Engine — CODE XONG (2026-09-06), chờ user test M4 + tune.**
  - `Rendering/ColorPipeline.swift` (MỚI): `CIContext` reuse, working = extendedLinearSRGB (16-bit float),
    output = sRGB. 1 `CIColorKernel` (đã verify compile) làm exposure(EV) · HL/SH/WH/BL (smoothstep
    luminance mask chồng mềm, giữ hue) · contrast (S-curve luỹ thừa quanh mid-grey 0.18, không kẹp 0.5) ·
    vibrance (`(1−chroma)` weighted, KHÁC saturation) · saturation. `CITemperatureAndTint` (x+y) TRƯỚC kernel.
    `CIVignette` sau. Không clamp giữa pipeline.
  - `ColorAdjust` (ImageFX.swift): 11 field thang nội bộ −1…1 (vignette 0…1), neutral = 0. Codable `v:2`
    + di trú tự động từ định dạng cũ (project cũ không vỡ). `ImageFX.apply` → `ColorPipeline`.
  - VIDEO: overlay video → `Compositor.overlayLayers` gọi `ImageFX.apply`. Nền video EXPORT → qua
    `BackgroundImageStore` sẵn có. Nền video PREVIEW → `VideoBackgroundView` `AVMutableVideoComposition`
    (applyingCIFiltersWithHandler) = cùng `ColorPipeline` → parity.
  - UI `ContentView.colorBasicPanel` (dùng cho lớp đè + nền): ÁNH SÁNG (Phơi sáng/Tương phản/Sáng nổi/
    Vùng tối/Điểm trắng/Điểm đen) · MÀU SẮC (Nhiệt độ/Sắc/Độ rực/Bão hoà) · HIỆU ỨNG (Tối góc) ·
    "Về gốc". Slider −100…100, double-click số = về 0.
  - **CÒN**: hằng số kernel (0.9/1.1/0.7/pivot 0.18/mix 0.85, map temp ±3200K, tint ±60) là GIÁ TRỊ
    KHỞI ĐẦU — cần tune bằng test ảnh (gray ramp, patch màu) khi user review. Chưa có unit/image test tự động.
    HDR: chưa xử lý tường minh (source SDR nên tạm ổn).
- **C8 · Tone Curves — CODE XONG** — `ToneCurve` (Fritsch–Carlson monotone cubic) master+R/G/B →
  bake `CIColorCubeWithColorSpace` (dim 32, sRGB). UI `ToneCurveGraph` (kéo điểm, double-click thêm/bớt).
- **C9 · HSL — CODE XONG** — kernel `kmHSL`: rgb→HSL, 8 dải tâm hue cố định, weight `smoothstep`
  circular (overlap mềm), áp hue-shift/sat/lum. UI: menu chọn dải + 3 slider.
- **C10 · LUT — CODE XONG** — parser `.cube` (`parseCube`) → `CIColorCubeWithColorSpace` + hoà theo
  `intensity` (kernel `kmMix`). UI: chọn file + slider độ mạnh + Bỏ.
- **C11 · Histogram — CODE XONG** (scopes waveform/parade/vectorscope = C11b, chưa) — `ColorPipeline.histogram`
  (`CIAreaHistogram` 128 bin) + `ClipHistogram` view (RGB), tính lại theo `adj.key`. Chỉ cho clip ẢNH / nền ảnh.
- Thứ tự pipeline: WB → kernel(exp/tonal/contrast/vib/sat) → curves cube → HSL kernel → LUT → vignette.
- CÒN: tune hằng số; test ảnh tự động; scopes; histogram cho video.
