# UI_REVIEW_FINAL — sau 9 chặng thiết kế lại (2026-09-29)

Đối chiếu với `docs/DESIGN_SYSTEM.md` và danh sách kiểm của nhiệm vụ. Skill "UI UX Pro Max" không có trong kho (không tải từ nguồn
lạ); bộ "Design" của Anthropic đã được gợi ý nhưng chưa cài → đánh giá này do Claude tự làm theo quy chuẩn. **Chưa có ảnh chụp màn hình**
(phiên này không có quyền chụp màn hình) — chủ dự án duyệt trên bản thử `KaraokeMaker THIẾT KẾ MỚI.app` (`Scripts/pack-test.sh`).

## 1. Nhất quán — đo trước / sau (`Views/*.swift`)
| Chỉ số | Trước | Sau |
|---|---|---|
| Nút xanh đặc `.borderedProminent` | 15 | **0** (thay bằng 3 cấp: 14 chính · 38 phụ · 11 icon) |
| Emoji trong giao diện (🎬 🎵 🅰 🚫 🔇 🥁 🎤 ⚠︎ ★…) | 11 chỗ | **0** (SF Symbols) |
| Cỡ chữ khác nhau | 18 (7 → 44) | chữ: 10–15 + 20 (Home); cỡ < 10 chỉ còn ở ICON nhỏ (chevron, dấu ✓, ✕ tab) |
| `.caption2` (~10pt) | 77 | 21 (chỉ còn nhãn trong ô chật: bảng chọn màu, sóng nhạc) — chú thích đã lên 11 |
| Padding số tay | 19 mức | 14 mức, phần lớn đổi sang `Theme.Space` |
| Bóng / blur quanh panel & preview | preview bóng r12, onboarding blur + bóng r20 | **0** (chỉ còn bóng 1.5px ở núm trượt) |
| Gradient trang trí | nút Home, thẻ Home | **0** (còn gradient CHỨC NĂNG: phổ màu, rãnh Nhiệt độ/Sắc) |
| Màu hệ thống tuỳ chỗ trên timeline | ~10 sắc | token theo nghĩa (`Theme.NS.*`), 3 chỗ còn `NSColor.system*` (hộp chọn người hát) |

## 2. Khoảng cách / phân cấp
- Tốt: toolbar 40pt, 1 nút chính (Xuất); panel phẳng (tiêu đề + đường kẻ); bước tạo karaoke đánh số, không hộp; preview phẳng
  chiếm ưu thế (panel trái 340–560, inspector 300–440, cửa sổ min 1180).
- Còn: `StylePanel` và bảng Sóng nhạc (`ContentView+Visualizer`) mới đổi cỡ chữ/màu/bo góc, bố cục bên trong giữ nguyên (nhiều hàng).

## 3. Kiểu trùng lặp
Đã gom: `KMButtonBody` (3 cấp nút), `PanelHeader`, `KMChoiceCard`, `ElapsedLabel`, `MediaThumbCache`, `Theme.NS.symbol`.
Còn riêng: `AppColorPicker` (865 dòng, kiểu popover riêng), hàng trượt ở `bgSlider` / `colorSlider` / `overlaySlider` / `fadeRow` (4 biến thể
cùng mục đích — nên gộp 1 `KMSliderRow` ở lần sau).

## 4. Trợ năng
- Nút chỉ-icon mới đều có `.help`; trạng thái "xong" = dấu ✓ (không chỉ chấm màu); Song ca / Vạch an toàn đổi icon khi bật.
- Tương phản: chữ gợi ý `inkFaint` nâng 40% → **50%** (≈ 5.0:1 trên panel; 40% chỉ ~3.7:1). `ink`/`inkDim` đạt.
- Focus bàn phím: dùng vòng focus hệ thống (chưa tự vẽ). Phím tắt giữ nguyên toàn bộ; sheet Xuất / Thùng rác đóng bằng Esc.

## 5. Mật độ panel · timeline · chế độ tối · cửa sổ hẹp · bàn phím
- Timeline: màu theo loại làn (ảnh/video tím nhạt, chữ xanh xám, nhạc thêm xanh lá nhạt, KARAOKE xanh ngọc, lời = nhấn), vạch đỏ token,
  nhãn làn 10pt, **từ chưa chắc gạch chân vàng**. Kéo thả / snap / hit-test không đổi. Chiều cao làn giữ nguyên.
- Chế độ tối: app vẫn ép `.dark` (không có chế độ sáng — đúng thiết kế).
- Cửa sổ hẹp: 1180 × 720 dùng được; rail tab trái thu nhãn tới 85% khi chật.

## 6. Hiệu năng (Intel)
- Không thêm giá trị nào vào `.focusedSceneValue` / environment; `ContentView.body` không thêm tính toán nặng (chỉ 1 `Set` khoá từ chưa chắc).
- **Sửa 2 lỗi hiệu năng có sẵn**: kho Media và lưới Home giải mã NGUYÊN file ảnh mỗi lần body chạy lại → nay `MediaThumbCache` (ImageIO,
  thu nhỏ, 1 lần/tệp).
- Bỏ bóng + bo góc quanh preview (layer vẽ lại mỗi khung hình).
- "Sửa lời theo vạch đỏ": ticker riêng trong `LyricEditPanel` (4 Hz khi phát, ghi state chỉ khi đổi dòng) — `ContentView` không dựng lại.
- `ElapsedLabel` 1 Hz, chỉ tồn tại khi 1 chặng đang chạy. Hover nút là state cục bộ từng nút.
- Đo: bản thử chặng 1–3 đứng yên 20 s = **0.0% CPU**. Bản cuối CHƯA đo trong editor có dự án mở (cần chủ dự án mở app) — đo lại khi duyệt.

## 7. Còn tồn (không làm trong đợt này — có lý do)
1. **Inspector cho Nhạc / Dự án**: mô hình chọn chỉ có `none / lyricLine / overlay`; bấm làn nhạc hiện = tua vạch đỏ (thói quen chủ dự án) →
   cần quyết định UX trước khi thêm "chọn làn nhạc".
2. Tab "Tạo Karaoke" biến mất sau khi canh xong (quyết định sản phẩm cũ) → vị trí tab xê dịch; giữ nguyên, chờ chủ dự án.
3. Khung hình xuất vẫn là menu danh sách preset (chưa segmented 16:9 · 9:16 · 1:1 · 12:16) — cần xem danh sách `VideoResolution.presets`.
4. `AppColorPicker`, bố cục trong `StylePanel` / Sóng nhạc, 4 biến thể hàng trượt → gộp ở đợt sau.
5. Slider hệ thống (chưa tô phần đã kéo bằng màu nhấn như §13).
6. Chưa có ảnh chụp màn hình; hiệu năng bản cuối cần đo khi mở dự án thật.
