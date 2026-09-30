# UI_REVIEW_FINAL — sau 9 chặng thiết kế lại (2026-09-29)

Đối chiếu với `docs/DESIGN_SYSTEM.md` và danh sách kiểm của nhiệm vụ. Skill "UI UX Pro Max" không có trong kho (không tải từ nguồn
lạ); bộ "Design" của Anthropic đã được gợi ý nhưng chưa cài → đánh giá này do Claude tự làm theo quy chuẩn. Ảnh chụp + số đo thật: §8
(`Scripts/ui-check.sh`). Chủ dự án duyệt trên bản thử `KaraokeMaker THIẾT KẾ MỚI.app` (`Scripts/pack-test.sh`).

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

## 7. Còn tồn — trạng thái sau phản hồi của chủ dự án (2026-09-29, khuya)
1. **Inspector cho Nhạc / Dự án** — CHỜ chủ dự án chọn cách bấm (bấm làn nhạc hiện = tua vạch đỏ; đề xuất: nút "Nhạc" ở đầu làn để
   chọn, giữ bấm-để-tua; "Dự án" = tab ở đầu inspector khi không chọn gì).
2. **ĐÃ SỬA** — Tab "Tạo Karaoke" LUÔN hiện. Tạo xong → nút "Tạo nhanh / Tạo chất lượng / Không cần lời" KHOÁ (kèm dòng giải thích 🔒)
   cho tới khi người dùng DÁN LẠI / SỬA lời ở ô tạo karaoke hoặc ĐỔI file nhạc (`canCreateKaraoke`, `karaokeInputChanged`).
3. **ĐÃ SỬA** — Khung hình xuất = segmented **16:9 · 9:16 · 1:1 · 12:16** + menu độ phân giải theo tỉ lệ (`VideoResolution.Aspect`;
   12:16 mới: 810×1080, 1080×1440). Kích thước lạ (dự án cũ) hiện "Tuỳ chỉnh W × H", không bị đổi.
4. **ĐÃ SỬA** — 5 biến thể hàng trượt gộp vào 1 `KMSliderRow` / `KMSlider` (`Views/KMSlider.swift`); nút "Cột mảnh cổ điển" thành nút
   BẬT/TẮT (bấm lần 2 trả về kiểu trước — nhớ trong phiên; không nhớ được thì về kiểu mặc định). `AppColorPicker` giữ bố cục riêng.
5. **ĐÃ SỬA** — Slider theo §13: rãnh 3pt, phần đã kéo màu nhấn (khoảng −…+ tô từ 0), núm 12, nắm trúng núm không nhảy, bấm đúp = mặc
   định, ghi ra ngoài ≤ 20 lần/giây + 1 lần lúc thả. Cả thanh tua ở thanh phát.
6. **ĐÃ LÀM** — `Scripts/ui-check.sh`: bản dựng kiểm thử riêng tự mở dự án (bản chép), chụp 3 cỡ cửa sổ + lúc phát + bảng Xuất, đo CPU
   Home / editor đứng yên / đang phát. Kết quả ở `.ui-check/<giờ>/` (gitignore — ảnh có lời bài hát). Số đo: xem §8.

## 8. Ảnh chụp + đo thật (`Scripts/ui-check.sh`, iMac 2017 Intel, dự án 32 dòng, 2026-09-29 23:34)
| Đo (CPU 1 nhân) | Kết quả |
|---|---|
| Home đứng yên | 0.8 % |
| Editor đứng yên | 0.5 % |
| Editor đang phát | 4.2 % |
| Dừng phát (sau 5 s) | 0.2 % |
| Bộ nhớ | ~260 MB |

Ảnh chụp tìm ra và đã sửa (không thấy được khi chỉ đọc code):
- **Cột phải (Kiểu chữ) bị TRÀN** ở mọi cỡ cửa sổ — mất mép trái/phải ("E TEXT", "nt size"). Do hàng B/I/U + "HOA/thường" cố định 210pt
  trong cột 300pt (lỗi của chặng 1 khi hạ cột từ 360). Sửa: hàng tự xuống 2 dòng khi hẹp (`ViewThatFits`) + cột min 320.
- **Cỡ cửa sổ tối thiểu vẫn 1360 × 780**: `AppDelegate.fitMainWindow` ghi đè khung SwiftUI → nay 1180 × 720 thật.
- Nhãn rail tiếng Anh bị cắt ("Create K…", "Video Ba…", "Audio Wa…") → nhãn ngắn 1 từ (Karaoke · Backdrop · Lyrics · Text ·
  Visualizer · Media); tiếng Việt giữ nguyên; tên đầy đủ ở tooltip + VoiceOver.
- Home: số thời lượng đè lên chữ ảnh bìa → chuyển lên góc trên.
- Sóng nhạc: "High" → "Height". Bảng Xuất thừa ~1/3 khoảng trống → cao 560.
