# COLOR ENGINE AUDIT — C0 (2026-09-06)

Audit hệ thống chỉnh màu HIỆN TẠI của KaraokeMaker. Grounded in code, không suy đoán.

## Bản đồ code

| Vai trò | File / symbol |
|--|--|
| Model | `Rendering/ImageFX.swift` → `struct ColorAdjust` (5 field) |
| Engine | `Rendering/ImageFX.swift` → `enum ImageFX.apply(CGImage, ColorAdjust) -> CGImage` |
| CIContext | `ImageFX.ciContext` = `CIContext(options: [.useSoftwareRenderer: false])` (static, reuse ✓) |
| Áp cho lớp đè ẢNH | `Compositor.swift` → `OverlayImageStore.image(for:)` dòng 313 → `ImageFX.apply` |
| Áp cho nền ẢNH | `Compositor.swift` dòng 119 → `BackgroundImageStore.processed` → `ImageFX.apply` |
| Áp cho VIDEO (lớp đè hoặc nền) | ❌ KHÔNG CÓ (xem ROOT-C3) |
| UI | `ContentView.overlayInspectorInline` mục "MÀU SẮC" + `backgroundMediaBlock` `bgSlider(...)` |
| Persistence | `ColorAdjust: Codable` khoan dung; nằm trong `OverlayClip.colorAdjust` + `BackgroundMedia.colorAdjust` |
| Preview vs Export | **CÙNG 1 đường** — export (`VideoFrameWriter`) cũng gọi `Compositor.overlayLayers` → `OverlayImageStore` → `ImageFX.apply`. ✓ |

`ColorAdjust` field: `exposure` (EV, −2…2), `contrast` (0…2), `saturation` (0…2),
`warmth` (−1…1), `vignette` (0…1). UI range == internal range == filter value (linear map).

## Đánh giá từng control

### Exposure — CORRECT
- Impl: `img.applyingFilter("CIExposureAdjust", [kCIInputEVKey: exposure])`.
- `CIExposureAdjust` = nhân sáng tuyến tính theo stop (`pow(2, EV)` trong linear light). Đúng nghĩa photographic.
- Slider: −2…2 EV map thẳng. Gần 0 hơi thô (bước slider ≈ 0.01 EV nếu kéo mịn, ok) nhưng range hẹp — thiếu ±3…4 EV.
- Neutral (0): identity ✓.

### Contrast — OVERSIMPLIFIED
- Impl: `CIColorControls` `inputContrast`. Đây là `(x − 0.5) · c + 0.5` quanh pivot 0.5, KHÔNG có toe/shoulder.
- Kẹp highlight / crush black sớm; pivot cứng; đổi luma trung bình khi lệch xa 1.
- Neutral (1): identity ✓. Range 0…2 tuyến tính = thô.

### Saturation — ACCEPTABLE
- Impl: `CIColorControls` `inputSaturation` (scale chroma quanh luma). Chấp nhận được.
- Neutral (1): identity ✓. Không bảo vệ hue/gamut ở cực đại.

### Temperature / "Ấm-Lạnh" (warmth) — APPROXIMATE
- Impl: `CITemperatureAndTint`, `inputNeutral (6500,0)` → `inputTargetNeutral (6500 − warmth·2600, 0)`.
- ĐÚNG hướng: dùng chromatic adaptation filter thật, KHÔNG phải cộng R / trừ B. Tốt hơn kỳ vọng.
- NHƯNG: chỉ trục x (temperature). **KHÔNG có Tint (trục y)**. Range map bằng hằng số 2600 chưa tune bằng visual test.
- Neutral (0): identity ✓.

### Vignette — ACCEPTABLE (nhưng là "effect", không phải tonal control)
- Impl: `CIVignette` `intensity = vignette·2`, `radius = 1.7` (cố định).
- Là vignette thật. Radius cứng; không có "midpoint/feather/roundness".

### Highlights / Shadows / Whites / Blacks — ❌ NOT_IMPLEMENTED
### Tint — ❌ NOT_IMPLEMENTED
### Vibrance — ❌ NOT_IMPLEMENTED (khác hẳn saturation, chưa có)
### Tone Curve / HSL / LUT / Fade / Grain — ❌ NOT_IMPLEMENTED
### Histogram / Scopes — ❌ NOT_IMPLEMENTED

## COLOR MANAGEMENT — INCORRECT / UNMANAGED

| Hạng mục | Trạng thái |
|--|--|
| Working color space | KHÔNG set (`CIContext` không có `workingColorSpace`) → CI mặc định linear-sRGB-ish |
| Output color space | KHÔNG set (`createCGImage(img, from:)` không truyền colorspace) → device RGB / sRGB |
| Source color space (ảnh) | Lấy ngầm từ CGImage của file (thường sRGB). Không transform tường minh. |
| Source color space (VIDEO) | Không đọc metadata. Không có Rec.709 / Display P3 / Rec.2020 / HLG / PQ handling |
| HDR policy | KHÔNG CÓ. Nếu gặp PQ/HLG sẽ bị xử như SDR (silently sai) |
| Bit depth | Chain CIImage→CIImage (1 lần), rồi `createCGImage` ra 8-bit, cache. Với VIDEO là 8-bit/khung. |
| Clamping | Không tự clamp giữa filter (tốt), nhưng `CIColorControls` contrast tự kẹp trong filter. |

Kết luận: pipeline **ngầm định sRGB, chỉ đúng tình cờ cho ảnh sRGB**. Không có quản lý màu tường minh, không có chính sách HDR, chưa chạm tới video.

## ROOT CAUSES (vì sao "chỉnh màu yếu / không chính xác")

- **ROOT-C1 · Thiếu cả họ tonal-region.** Không có Highlights/Shadows/Whites/Blacks + Vibrance + Tint.
  Đây là nhóm làm color panel "có lực". Chỉ 5 slider → cảm giác yếu.
- **ROOT-C2 · Contrast naïve.** `CIColorControls` pivot cứng 0.5, không toe/shoulder → kẹp sớm, đổi luma.
- **ROOT-C3 · KHÔNG áp cho VIDEO.** `OverlayImageStore.image(for:)` trả `nil` khi `clip.kind == .video`;
  nền video (`BackgroundVideoReader` / `VideoBackgroundView`) không qua `ImageFX`. → Với video (trường hợp phổ biến
  nhất) "chỉnh màu" **không làm gì cả**.
- **ROOT-C4 · Không có quản lý màu.** Không working space / output space / source transform / HDR policy.
- **ROOT-C5 · Slider map tuyến tính, UI-range = internal-range.** Không có mapping riêng, không mịn quanh 0,
  range chưa tune.
- (Điểm MẠNH giữ lại: preview ↔ export DÙNG CHUNG 1 đường; `CIContext` reuse; `CIExposureAdjust` + `CITemperatureAndTint` là filter đúng.)

## Cái GIỮ LẠI
- `ImageFX.apply` là điểm áp màu DUY NHẤT cho ảnh → giữ mô hình "1 transform, preview = export".
- `CIExposureAdjust` (exposure), `CITemperatureAndTint` (white balance) — filter hợp lệ, tái dùng.
- `ColorAdjust` per-clip + Codable khoan dung — mô hình state tốt, chỉ cần MỞ RỘNG field, không viết lại.
- Cache theo `adj.key` (`OverlayImageStore` / `BackgroundImageStore`).

## Cái PHẢI THAY
- Thêm `CIContext.workingColorSpace` (extended linear) + `outputColorSpace` tường minh.
- Contrast → tone-curve có toe/shoulder (custom `CIColorKernel` hoặc `CIToneCurve`/spline).
- Thêm Highlights/Shadows/Whites/Blacks bằng luminance mask mềm (`smoothstep`) — cần custom kernel.
- Thêm Vibrance (boost theo `1 − chroma`), Tint (trục y của `CITemperatureAndTint`).
- Đường màu cho VIDEO: overlay video + nền video phải đi qua cùng engine.
- Slider mapping riêng cho từng control (`sign(v)·pow(|v|, γ)` + range nội bộ hợp lý).
