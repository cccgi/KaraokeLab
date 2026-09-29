# COLOR_ENGINE — thiết kế đích (bản C0, sẽ cập nhật theo từng phase)

> Trạng thái: **C1–C7 (Basic) ĐÃ IMPLEMENT** (2026-09-06, `Rendering/ColorPipeline.swift`). Kernel dùng
> Core Image Kernel Language (legacy string, verify compile OK). Hằng số tông đang là GIÁ TRỊ KHỞI ĐẦU,
> tune bằng test ảnh khi review. C8–C11 chưa làm.

## 0. Nguyên tắc
- ENGINE trước, UI sau. 10 control ĐÚNG > 30 control giả.
- 1 transform toán học duy nhất cho **preview + export + still + thumbnail** (preview có thể hạ độ phân giải, KHÔNG đổi công thức).
- Neutral state = identity trong dung sai nhìn không thấy.
- Không clamp 0…1 sau mỗi bước; chỉ clamp/tone-map ở output.
- `ColorAdjust` = DATA thuần (Codable, Equatable), không chứa View / CIContext.

## 1. Quản lý màu (SDR-first)

```
SOURCE (ảnh sRGB/P3 · video Rec.709/P3)
   ↓ input transform  → EXTENDED LINEAR (working space)
WORKING SPACE = CGColorSpace(name: extendedLinearSRGB) hoặc extendedLinearDisplayP3
   ↓ COLOR PIPELINE (mục 3)  — làm ở linear light
   ↓ output transform
OUTPUT = sRGB (preview/màn hình) hoặc Rec.709 (video xuất)
```
- `CIContext(options: [.workingColorSpace: extendedLinearSRGB, .outputColorSpace: sRGB, .workingFormat: RGBAh])`.
- `CIImage(cgImage:)` giữ colorspace nguồn; nếu nil → giả định sRGB (ảnh) / Rec.709 (video), ghi log DEBUG.
- **HDR policy (C1)**: nếu source là PQ/HLG → HIỆN TẠI = tone-map xuống SDR Rec.709 + cảnh báo 1 lần
  ("Video HDR — đã hạ về SDR"). KHÔNG xử lý ngầm như SDR. HDR đầy đủ = ngoài phạm vi.
- `CURRENT COLOR PIPELINE TARGET = SDR`.

## 2. State model (mở rộng `ColorAdjust`, không viết lại)

```
struct ColorAdjust {           // UI range trong ngoặc; internal ở mục 4
    var exposure: Double = 0        // −100…100  → EV
    var contrast: Double = 0        // −100…100  (đổi 1→0 làm neutral: 0 = identity)
    var highlights: Double = 0      // −100…100
    var shadows: Double = 0         // −100…100
    var whites: Double = 0          // −100…100
    var blacks: Double = 0          // −100…100
    var temperature: Double = 0     // −100…100
    var tint: Double = 0            // −100…100   (MỚI)
    var vibrance: Double = 0        // −100…100   (MỚI)
    var saturation: Double = 0      // −100…100  (đổi 1→0 làm neutral)
    var fade: Double = 0            // 0…100      (C-sau)
    var vignette: Double = 0        // −100…100
    // C8+: var curve: ToneCurve; var hsl: HSLAdjust; var lut: LUTRef?
}
```
- **Di trú**: field cũ `contrast`/`saturation` mặc định 1, neutral mới = 0. `Codable init` map:
  `contrast(cũ ~1) → 0`, `saturation(cũ ~1) → 0`, `exposure` giữ (đổi thang −2…2 EV → −100…100),
  `warmth(−1…1) → temperature(−100…100)`, `vignette(0…1) → 0…100`. Project cũ không vỡ.

## 3. Thứ tự pipeline (linear light trừ chỗ ghi rõ)

```
1  Input transform → extended linear
2  White balance      (temperature + tint)   — CITemperatureAndTint (x,y)
3  Exposure           EV, nhân linear
4  Tonal regions      Blacks → Shadows → Highlights → Whites   (luminance mask mềm, custom kernel)
5  Contrast / Tone curve   (spline có toe/shoulder quanh pivot ~0.18 linear / 0.5 perceptual)
6  Vibrance           (boost theo 1 − chroma; bảo vệ hue da ở phase sau)
7  Saturation         (scale chroma)
8  HSL / selective    (C9)
9  Creative: Fade, LUT (C-sau)
10 Effects: Vignette, Grain
11 Output transform → sRGB / Rec.709   + clamp/tone-map DUY NHẤT ở đây
```

## 4. Thuật toán từng control (đích)

- **Exposure**: `lin *= pow(2, ev)`, `ev = map(exposure) ∈ [−4, +4]`. `CIExposureAdjust` (đã đúng) hoặc kernel.
- **Contrast**: spline luma quanh pivot, toe + shoulder → KHÔNG kẹp sớm. `strength = map(contrast) ∈ [−1, +1]`.
- **Highlights/Shadows** (dải rộng), **Whites/Blacks** (endpoint): tính `Y = 0.2126R+0.7152G+0.0722B`
  (linear), tạo mask `smoothstep` chồng mềm (không threshold cứng), áp lệch tonal + **giữ hue**
  (`scale = Ynew/Yold`, robust ở near-zero / out-of-gamut). Cần **custom `CIColorKernel`/Metal** —
  built-in `CIHighlightShadowAdjust` không đủ tách Whites/Blacks.
- **Temperature/Tint**: `CITemperatureAndTint`, `inputNeutral (6500,0)`, `inputTargetNeutral (6500 + f(temp), g(tint))`.
  Tune `f`,`g` bằng visual test trên gray ramp.
- **Vibrance**: `chroma = f(pixel)`; `boost = amount · (1 − chroma)^k`; áp lên chroma. KHÁC saturation.
- **Saturation**: scale chroma tuyến tính, `s = 1 + map(saturation) ∈ [0, 2]`.
- **Vignette**: `CIVignette` + radius/midpoint mở ra UI ở phase sau.

## 5. Slider mapping
- UI −100…100 (hoặc 0…100), hiển thị số nguyên.
- Nội bộ: `t = value/100`; `shaped = sign(t)·pow(|t|, γ)` (γ≈1.6–2.0, tune) → mịn quanh 0, mạnh ở cực.
- Mỗi control 1 hàm map riêng → internal range (mục 4). Không map thẳng slider vào tham số filter.

## 6. Kiến trúc

```
struct ColorAdjust { … }                 // DATA
enum ColorPipeline {                      // ENGINE (thuần, testable)
    static func makeContext() -> CIContext            // reuse
    static func process(_ img: CIImage, _ adj: ColorAdjust,
                        source: CGColorSpace?, output: CGColorSpace) -> CIImage
}
```
- `ImageFX.apply` → gọi `ColorPipeline.process` (giữ tên/điểm gọi cũ để không phá `OverlayImageStore` / `BackgroundImageStore`).
- Video: thêm `ColorPipeline.process` vào đường overlay-video (`OverlayVideoFrameStore`) + nền video
  (preview: `CIImage` layer thay `AVPlayerLayer` thô, hoặc `AVVideoComposition` với CI; export: `BackgroundVideoReader` → `process`).

## 7. Preview vs Export
- Cùng `ColorPipeline.process`. Preview: có thể `CIImage` downscale trước bước 1. Export: full-res.
- Test parity: cùng frame → 2 đường → so pixel, tolerance nhỏ.

## 8. Hạn chế đã biết (sẽ cập nhật)
- HDR: chỉ tone-map xuống SDR, không grade trong HDR.
- Highlight recovery không phục hồi được pixel đã clip hoàn toàn (sẽ nói rõ trong UI/nếu hỏi).
- Skin-tone protection cho Vibrance: phase sau.
- LUT: chỉ `.cube`, giả định input theo LUT metadata nếu có, else Rec.709.

## 9. Phase (chi tiết ở `ROADMAP.md` §Color C0–C11)
C0 audit → C1 color management → C2 exposure+contrast → C3 HL/SH/WH/BL → C4 temp/tint →
C5 vibrance/saturation → C6 preview/export parity + VIDEO path → C7 UI → C8 curves → C9 HSL →
C10 LUT → C11 histogram/scopes.
