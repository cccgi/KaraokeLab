# DESIGN_SYSTEM — KaraokeMaker (nguồn chuẩn cho mọi thay đổi giao diện, 2026-09-29)

Tinh thần: **phần mềm dựng phim cao cấp, tối, yên tĩnh, gọn** — kiểu Final Cut / Logic / CapCut Desktop. Chất lượng đến từ
tỉ lệ, căn hàng, tiết chế và nhất quán — KHÔNG từ trang trí. Chỉ chế độ tối (app ép `.dark`). Hiệu năng Intel > hiệu ứng.
Mọi giá trị dưới đây sống trong `Views/Theme.swift` (`Theme.*`, `Theme.NS.*`, `Theme.Typo`, `Theme.Space`, `Theme.Radius`, `Theme.ControlH`); code giao diện KHÔNG viết số / màu tay (ngoại lệ phải ghi chú lý do).

## 1. Màu (token → giá trị → dùng cho)
| Token (`Theme.`) | Giá trị | Dùng |
|---|---|---|
| `bg` | #171719 | nền cửa sổ, nền quanh preview |
| `panel` | #212125 | panel trái, inspector, thanh syncBar, timeline header |
| `panelAlt` | #2A2A2E | toolbar, thanh tiêu đề panel, hàng đang hover trong danh sách |
| `elevated` | #38383E | nền control (field, nút phụ, segmented) |
| `stroke` | trắng 7% | đường kẻ giữa panel / mục |
| `strokeStrong` | trắng 14% | viền field, viền khi hover |
| `ink` | trắng 92% | chữ chính |
| `inkDim` | trắng 60% | chữ phụ, nhãn |
| `inkFaint` (mới) | trắng 50% (≥ 4.5:1 trên panel) | chữ gợi ý, đơn vị, thước timeline |
| `inkDisabled` (mới) | trắng 25% | chữ / icon bị khoá |
| `accent` | **#2395C5** (giữ — màu thương hiệu) | hành động chính, mục đang chọn, dòng đang hát, focus |
| `accentSoft` | #2395C5 @16% | nền mục đang chọn |
| `accentHover` (mới) | #2FA6D8 | nút chính khi hover |
| `hover` (mới) | trắng 6% | nền hover cho nút phụ / hàng |
| `pressed` (mới) | trắng 10% | nền khi nhấn |
| `warning` (mới) | #D6A445 | từ chưa chắc, cảnh báo nhẹ (dùng rất ít) |
| `error` (mới) | #E5534B | lỗi, xoá |
| `success` (mới) | #45B37E | dấu "xong" (luôn đi kèm icon ✓, không chỉ chấm màu) |
| `playhead` (mới) | #E5484D | vạch đỏ — giữ đỏ vì mọi hướng dẫn gọi là "vạch đỏ" |
Cấm: gradient trang trí, neon, tím–hồng, phát sáng, nền màu cho cả panel. Màu = thông tin (chọn / hoạt động / trạng thái).
Bản `NSColor` cho AppKit: `Theme.NS.<token>` (`static let`, không tạo mới mỗi lần vẽ).

## 2. Chữ (SF Pro hệ thống, số dạng `.monospacedDigit()` cho mọi thời gian)
| Token (`Theme.Typo.`) | Cỡ / nét | Dùng |
|---|---|---|
| `title` | 13 semibold | tên dự án trên toolbar, tiêu đề workspace |
| `panelTitle` | 11 semibold, IN HOA, kerning 0.4, `inkDim` | tiêu đề panel / mục (thay `sectionHeaderStyle` 12) |
| `label` | 12 regular, `ink` | nhãn control, mục danh sách |
| `body` | 12 regular | nội dung, giá trị |
| `helper` | 11 regular, `inkFaint` | chú thích 1 dòng (tối đa 1 dòng / mục) |
| `mono` | 11–12 monospacedDigit | mã thời gian, số đo |
| `sheetTitle` | 15 semibold | tiêu đề sheet / hộp thoại |
| `homeTitle` | 20 semibold | chỉ màn Home |
| `badge` | 10 semibold | huy hiệu nhỏ, nhãn trên timeline |
Không dùng: cỡ < 10, `.title/.title2/.title3` trong editor, in đậm tràn lan, font trang trí.

## 3. Khoảng cách — thang duy nhất `Theme.Space`
`xs 4 · s 6 · m 8 · l 12 · xl 16 · xxl 24`. Trong editor chủ yếu 6–12. Padding panel = 12; khoảng giữa hàng = 8; giữa mục = 12
(+ đường kẻ); `xxl` chỉ cho Home / sheet. Không số lẻ (5, 7, 9, 14, 18, 22, 28…).

## 4. Chiều cao control — `Theme.ControlH`
`small 22` (hàng inspector, nút timeline) · `regular 26` (nút toolbar, field thường) · `large 30` (nút chính trong luồng tạo /
sheet Xuất). Toolbar 40 (từ 46). Thanh tiêu đề panel 30. Hàng danh sách 24.

## 5. Bo góc — `Theme.Radius`
`none 0` panel / thanh / preview (phẳng, ghép sát) · `xs 3` khối trên timeline · `sm 4` field, nút nhỏ · `md 6` nút, segmented,
thumbnail · `lg 8` popover, sheet, overlay nổi. Không có bo > 8 trong editor.

## 6. Viền, đường kẻ, bóng, vật liệu
- Panel ngăn nhau bằng 1 đường kẻ `stroke` (không khung bo quanh panel). Mục trong panel: tiêu đề + đường kẻ, KHÔNG thẻ.
- Bóng CHỈ cho: menu, popover, sheet, bóng khi kéo thả. Không bóng panel, không bóng preview.
- Vật liệu (blur) CHỈ cho popover / menu hệ thống và overlay tĩnh ngắn hạn. Toolbar, panel, timeline: nền đặc.

## 7. Nút — 3 cấp (`Theme.ButtonStyles`)
- **Chính (`.kmPrimary`)**: nền `accent`, chữ trắng 12–13 semibold, cao 26/30. **Tối đa 1 nút chính mỗi vùng**: toolbar =
  Xuất; bước tạo karaoke = Tạo Karaoke / Tự động tạo; sheet Xuất = Xuất; hộp thoại = hành động xác nhận.
- **Phụ (`.kmSecondary`)**: nền `elevated`, chữ `ink`, viền `stroke`; hover `hover`, nhấn `pressed`. Mở, Lưu, Thêm dòng…
- **Cấp 3 / icon (`.kmIcon`)**: không nền, icon `inkDim` 13pt, hover nền `hover` bo 4, ô chạm ≥ 22×22, luôn có `.help`.
- **Xoá**: nút phụ, chữ `error`; hành động xoá quan trọng luôn hỏi lại.
- Bật / tắt (Song ca, Vạch an toàn): kiểu phụ; khi BẬT = nền `accentSoft` + chữ `accent` + icon đổi (không chỉ đổi màu).
- Nút bị khoá: chữ `inkDisabled`, không nền. Màu nhấn KHÔNG dùng để báo "bấm được".

## 8. Trạng thái tương tác (mọi thành phần)
normal · hover (`hover`) · nhấn (`pressed`) · chọn (`accentSoft` + chữ/icon `accent` + vạch nhấn 2px bên trái hoặc dưới) ·
khoá (`inkDisabled`) · focus bàn phím (vòng `accent` 2px, hệ thống). Chọn phải nhất quán giữa kho media, danh sách lời,
inspector và timeline. Không trạng thái nào chỉ dựa vào màu (kèm icon / độ đậm / vạch).

## 9. Panel
- Thanh tiêu đề 30: `panelTitle` + nút icon bên phải; nền `panel`; kẻ dưới `stroke`.
- Nội dung: padding 12, cuộn trong panel (không cuộn cả cửa sổ), mục = tiêu đề mục (`panelTitle`) + nội dung, cách nhau 12 +
  đường kẻ; mục phụ gập lại được (chevron 10pt, bấm cả hàng).
- Panel trái: rail tab **cố định vị trí** (tab chưa dùng được thì mờ + giải thích ở tooltip, không biến mất); tab chọn =
  icon + nhãn `accent`, nền `accentSoft`. Nhãn 11.
- Kích thước: cửa sổ min 1180×720; panel trái min 300 / lý tưởng 360 / max 520; inspector min 280 / lý tưởng 320 / max 420;
  preview luôn ưu tiên (`layoutPriority`). Timeline min 220 / lý tưởng 340.

## 10. Toolbar (cao 40, nền `panelAlt`, nền đặc)
Trái: ‹ Thư viện · hoàn tác / làm lại (icon) · tên dự án (`title`, sửa tại chỗ) · chấm chưa lưu (kèm tooltip).
Phải: nhóm phụ **Dự án mới · Mở · Lưu · Lưu thành** (vẫn để ngoài theo yêu cầu chủ dự án, dạng icon + nhãn nhỏ cấp phụ) ·
khoảng cách · **Xuất** (nút chính duy nhất). Bản dùng thử (TrialBanner) ở giữa, kiểu huy hiệu.

## 11. Preview / canvas
Phẳng, không bo, không bóng, nền `bg`; tỉ lệ khung theo dự án, căn giữa. Điều khiển (Vạch an toàn, chất lượng) = nút icon nhỏ
góc trên, mờ `inkDim` tới khi hover. Thanh transport ngay dưới: nút phát (icon lớn nhất 15), thời gian `mono`.

## 12. Inspector (theo ngữ cảnh)
| Đang chọn | Nội dung |
|---|---|
| Dòng / chữ lời, hoặc không chọn gì trên làn lời | Kiểu chữ karaoke (`StylePanel`) |
| Lớp đè (ảnh / video / text) | Biến đổi · Màu · Chuyển động (keyframe) — như hiện tại |
| Làn nhạc | Âm lượng · Fade · Cắt đầu/cuối · Nguồn |
| Không chọn gì | Dự án: khung hình, nền, thông tin |
Mục = `InspectorSection` (tiêu đề `panelTitle`, gập được). Hàng = nhãn cột trái rộng 88 căn phải + control lấp phần còn lại, cao 22.

## 13. Field / control
Cao 22 (inspector) / 26; bo 4; nền `elevated`; viền `stroke` → `strokeStrong` khi hover; focus vòng `accent`. Slider: rãnh 3px
`strokeStrong`, phần đã kéo `accent` (bipolar: tô từ giữa), núm 12; bấm đúp = về mặc định. Nhấp ra ngoài = thoát sửa (giữ
`OutsideClickDismiss`). TextField không tự focus.

## 14. Timeline (ưu tiên cao nhất — vẽ AppKit, token `Theme.NS`)
- Nền làn `panel`, làn xen kẽ trắng 2%; header làn cố định (icon SF 11 + tên `badge`, nút 👁/🔒/loa = icon 11).
- Thước: nền `panelAlt`, vạch `stroke`, số `mono` 10 `inkFaint`.
- Màu theo loại làn (bão hoà thấp, luôn đi kèm nhãn): Nhạc = xám xanh #4A5A6A (sóng #7F95A8) · Lời = `accent` 22% viền
  `accent` 60% · Lớp đè ảnh/video = #5E5A8A · Text = #4F7A64 · Karaoke = `accent` 30%.
- Khối: bo 3, nhãn `badge` trắng 85%. **Chọn** = viền trắng 1.5 + sáng hơn 8%. **Dòng đang hát** = nền `accent` 35%;
  **chữ đang hát** = `accent` 70%. **Chưa chắc** = gạch chân 2px `warning` (mới — hiện trên timeline). **Khoá** = 45% độ đậm +
  icon khoá. **Tắt tiếng / ẩn** = 40% độ đậm + icon. Mép kéo được = 4px sáng hơn khi hover.
- Vạch đỏ `playhead` 1.5px + tay nắm tam giác trên thước. Keyframe = hình thoi `ink` viền `bg` (1 màu; phân biệt bằng làn).
- Không emoji (🎬 🎵 🅰 🚫 🔇 ★ → SF Symbols vẽ bằng `NSImage(systemSymbolName:)` cache sẵn).
- Không animation / layer động mới; màu tạo 1 lần.

## 15. Luồng lời & tiến trình
- Hai đường ở bước 2: **Tôi có lời** / **Không cần lời** = 2 lựa chọn ngang nhau (thẻ chọn lớn duy nhất được phép trong
  editor), sau đó hội tụ cùng editor.
- Tiến trình = danh sách chặng gọn: icon trạng thái (đang chạy = ProgressView nhỏ, xong = ✓ `success`, lỗi = ! `error`) · tên
  chặng · thanh tiến độ thật · thời gian đã chạy `mono` · nút **Huỷ** (phụ) · "Chi tiết" gập. **"Tôi có lời" giữ 2 chặng riêng**
  (phân tích nhạc ✓ → tạo karaoke) — yêu cầu cứng của chủ dự án. Không tên mô hình / thuật ngữ kỹ thuật.
- Từ chưa chắc: gạch chân `warning`, bấm → popover gợi ý thay thế (thay chữ, giữ nguyên giờ).

## 16. Xuất
Sheet 560 rộng, bo 8, tiêu đề `sheetTitle`. Thứ tự: **Khung hình** (segmented 16:9 · 9:16 · 1:1 · 12:16) → **Chất lượng**
(độ phân giải, FPS) → **Âm thanh** → **Nơi lưu** → nút chính **Xuất video** dưới cùng bên phải. SRT / ASS vào mục "Phụ đề"
(nút phụ). Tuỳ chọn nâng cao (ProRes, Ken Burns, lấp 2 bên) gập trong "Nâng cao".

## 17. Màu (color grading)
Nhóm: Ánh sáng · Màu sắc · Hiệu ứng · Đường cong · HSL · LUT — tiêu đề `panelTitle` (bỏ 9pt riêng). Mỗi mục có ⟲ đặt lại; mục
đã chỉnh có chấm `accent` cạnh tiêu đề. Slider theo §13. Tuân thủ `docs/COLOR_ENGINE*.md` (không slider giả).

## 18. Popover / hộp thoại / menu
Bo 8, bóng hệ thống, padding 12, tiêu đề `label` semibold. Nút xác nhận = chính (phải), Huỷ = phụ. Esc đóng.

## 19. Trạng thái trống & thông báo
Trống = 1 icon SF 28 `inkFaint` + 1 dòng `label` + tối đa 1 nút. Ví dụ: "Thả video hoặc nhạc vào đây" · "Dán lời hoặc tạo tự
động" · "Tạo hoặc mở một dự án". Lỗi = thanh mảnh dưới đáy, icon `error` + chữ `ink` + nút Ẩn (không tô đỏ cả dòng chữ).

## 20. Icon
SF Symbols, nét regular, 13 (toolbar) / 12 (panel) / 11 (timeline header). Không emoji, không bộ icon web. Nút chỉ có icon luôn
có `.help` + nhãn trợ năng.

## 21. Bàn phím & trợ năng
Giữ nguyên mọi phím tắt (Space phát / dừng, ⌘Z / ⇧⌘Z, ⌫, ⌘K tách, ⌘S…). Tab đi qua được các control chính; focus thấy rõ.
Tương phản chữ ≥ 4.5:1 trên nền panel (ink / inkDim đạt; inkFaint chỉ cho chữ phụ ≥ 11). Chữ nhỏ nhất 10 (chỉ huy hiệu).

## 22. Quy tắc hiệu năng khi làm giao diện
Không closure mới vào `.focusedSceneValue` / environment; không tính nặng trong `body`; không `.shadow` / `.blur` / `clipShape`
quanh view cập nhật mỗi khung hình; không animation liên tục; màu AppKit là `static let`. Mỗi chặng đo CPU đứng yên / phát /
cuộn timeline trên Intel trước–sau.

## 23. Thành phần dùng chung (đã có trong `Theme.swift`)
- Nút: `.kmPrimary` / `.kmPrimaryLarge`, `.kmSecondary` / `.kmSecondarySmall`, `.kmToggle(on)`, `.kmIcon` (`KMIconButtonStyle(selected:)`).
- `PanelHeader(title:icon:trailing:)` — thanh tiêu đề 30pt.  `KMChoiceCard` — thẻ lựa chọn ngang nhau.  `ElapsedLabel` — đồng hồ "đã chạy".
- `Theme.NS.symbol(name,size,color)` — SF Symbol tô màu, cache sẵn, để vẽ trong Core Graphics (timeline).
- `MediaThumbCache.image(for:maxPixel:)` — ảnh thu nhỏ giải mã 1 lần (kho media, Home).
- Duyệt thay đổi giao diện: `./Scripts/pack-test.sh` → "KaraokeMaker THIẾT KẾ MỚI.app" trên Desktop (không đụng app chính).
