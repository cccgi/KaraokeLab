# UI_AUDIT — giao diện editor hiện tại (2026-09-29, trước khi thiết kế lại)

Phạm vi: `Sources/KaraokeMaker/Views/*` (12.6k dòng) sau khi `ContentView` được tách 14 file. Đo bằng code, chưa có ảnh
chụp (app đang được chủ dự án dùng thử). Không đụng: canh giờ / ASR / export engine / audio (CLAUDE.md ⛔).

## 1. Điểm mạnh — GIỮ
- **Bố cục đúng kiểu editor chuyên nghiệp**: `ContentView.mainLayout` = toolbar / `HSplitView`(panel trái · preview · inspector)
  / `VSplitView` → `syncBar` + timeline. Khớp sơ đồ mục tiêu và mong muốn của chủ dự án (3 cột + syncBar + timeline, tông
  tối, không cuộn dọc dài, nút quan trọng để "ở ngoài").
- **Có sẵn mầm token**: `Theme.swift` (bg/panel/panelAlt/elevated/stroke/ink/inkDim, `Metric`), **1 màu nhấn duy nhất
  #2395c5** (chủ dự án chọn — giữ nguyên), `sectionHeaderStyle()`.
- **Timeline AppKit** (`TimelineCanvasView` trong `TimelineEditor.swift`): vẽ bằng Core Graphics, kéo theo mẫu
  pending → preview (không đụng store) → commit 1 lần ở mouseUp, snap, làn lớp đè có 👁/🔒. Nhanh và mượt — giữ kiến trúc.
- **Các bản sửa hiệu năng** (KNOWN_ISSUES): `EditorCommandSink` qua `.focusedSceneValue` đã `Equatable`; `BeatSepProxy` /
  `AdvancedKaraokeProxy` throttle; vạch đỏ không dùng `CAAnimation`; `PlaybackTicks` tách nhịp giây.
- **Luồng "Tạo Karaoke" 2 đường** (Có lời / Không cần lời) với tiến trình 2 chặng tách biệt (yêu cầu cứng của chủ dự án),
  từ chưa chắc có gợi ý thay thế (`LyricEditPanel`), bảng chọn màu dùng chung (`AppColorPicker`), đa ngôn ngữ `L("…")`.

## 2. Điểm yếu (kèm chỗ trong code)
**Phân cấp nút rối** — 15 chỗ `.borderedProminent`:
- Toolbar (`ContentView+Toolbar.swift`) có 5 nút xanh đặc cùng cỡ: Dự án mới / Mở / Lưu / Lưu thành / Xuất. "Xuất" không
  nổi hơn "Lưu thành".
- `syncBar` (`ContentView+TimelineChrome.swift:32`) có thêm 5 nút xanh đặc (Thêm chữ, Thêm dòng, Song ca, Chữ sớm ×2).
  Màu nhấn đang bị dùng với nghĩa "bấm được", không phải "hành động chính".
- Luồng tạo karaoke có 6 nút xanh, bảng Xuất có 3 nút xanh.

**Tỉ lệ khung không ưu tiên preview** (`ContentView.swift:181,297–304`):
- Cửa sổ tối thiểu 1380×780, nên không thu hẹp được.
- Panel trái min 430 / lý tưởng 720 (lớn hơn preview, min 460); inspector 360–560.
- Trên MacBook Air 13" (1470 pt), preview chỉ còn ~680 pt khi các cột ở mức tối thiểu.
- Preview được bo 10 và đổ bóng bán kính 12 (`ContentView+PreviewCenter.swift`), trông như một thẻ nổi.

**Token không được dùng nhất quán**:
- 18 cỡ chữ khác nhau (7 → 44), 19 giá trị padding, 8 bán kính bo góc viết thẳng số.
- Khoảng 12 mức `Color.white.opacity(…)` viết tay.
- `.orange` / `.green` / `.red` / `.blue` dùng tuỳ chỗ.
- `Theme` thiếu các token: chữ cấp 3 (tertiary), cảnh báo / lỗi / thành công, chọn / hover / focus, chiều cao control, thang khoảng cách.

**Quá nhiều "thẻ"** — nội dung panel bị bọc trong hộp bo góc có viền:
- `subCard` (`PreviewCenter:79`) và `collapsibleSection` (`CreateKaraoke:567`).
- Các tab Nền video / Thêm text / Sóng nhạc bọc đúng 1 `subCard` trong 1 `ScrollView` (2 lớp khung).
- Onboarding dùng `.ultraThinMaterial` + bóng 20.

**Chữ không cùng hệ**:
- Tiêu đề mục: panel dùng `sectionHeaderStyle` 12pt; bảng màu dùng 9pt `.tertiary` riêng (`ColorPanel:61,69,79`) và "MÀU" `caption2.bold`.
- Bước tạo karaoke dùng `.title3.bold`; mục sổ và bảng Xuất dùng `.headline`.
- Có 77 chỗ `caption2` (~10pt): khó đọc trên iMac 2017.

**Nhiều chữ hướng dẫn dài**, không dùng tiết lộ dần (progressive disclosure):
- `textLayerPanel`, `backgroundPanelBody`, `onboardingCard` (3 bước), `duetBar`, gợi ý timeline (`TimelineEditor:320`).

**Timeline dùng ~10 sắc màu không theo nghĩa** (`TimelineEditor.swift`):
- Vạch đỏ `systemRed`; kim cương keyframe xanh ngọc + vàng; khối lời teal; lớp đè tím; text xanh lá; staging cam;
  `systemYellow` / `systemGreen`; chữ xanh nhạt.
- Emoji làm nhãn clip: 🎬 🎵 🅰 🚫 🔇 và "★ KARAOKE".
- Từ chưa chắc **không** hiện trên timeline (chỉ có ở tab Sửa lời).

**Emoji trong giao diện**: 🥁 🎤 (`CreateKaraoke:457–459`), ⚠︎ ❌ (`ExportPanel`), cộng các emoji timeline ở trên.

**Inspector không theo ngữ cảnh** (`ContentView+Inspector.swift`):
- Không chọn gì thì luôn hiện "Kiểu chữ karaoke" (`StylePanel`).
- Âm lượng / fade / cắt audio và cài đặt khung / dự án nằm rải ở panel trái và sheet Xuất.
- Chọn lớp đè thì có inspector riêng (vị trí, màu…), nhưng tiêu đề khác kiểu.

**Tab trái đổi chỗ** (`CreateKaraoke:138`):
- "Tạo Karaoke" biến mất sau khi canh xong; "Sửa lời" hiện ra. Vị trí các tab xê dịch, người dùng khó nhớ chỗ.
- Nhãn tab 10.5pt.

**Xuất** (`ContentView+ExportPanel.swift`, sheet 580×660):
- SRT, ASS và Video xếp chồng, mỗi phần một nút chính.
- Chưa chia rõ Khung hình → Chất lượng → Âm thanh → Nơi lưu → Xuất.

**Trạng thái**:
- Thanh lỗi là chữ đỏ kéo ngang toàn cửa sổ.
- Chấm "chưa lưu" màu cam 5px; chấm "xong" xanh lá 6px trên tab chỉ dựa vào màu.

**Home** (`HomeView.swift`): cỡ 17 / 20 / 40, khác hệ với editor.

**Trợ năng (accessibility)**:
- Hầu hết nút icon đã có `.help`.
- Trạng thái chỉ bằng màu: chấm xong, viền Song ca.
- Chữ 9–10pt; focus dùng mặc định.

## 3. Rủi ro hiệu năng — thiết kế lại PHẢI giữ
1. `ContentView.body`:
   - Không thêm giá trị chứa closure vào `.focusedSceneValue` / environment. `EditorCommandSink` phải giữ `Equatable`
     (bài học 2026-09-24: 190% CPU khi đứng yên).
   - ~60 `@State`, `body` chạy lại thường xuyên. Không lọc / sắp xếp / định dạng nặng trong `body` (ví dụ lọc overlays
     inline ở `textLayerPanel`) → tính sẵn khi dữ liệu đổi.
2. **Preview** (`KaraokePreview` / `KaraokePreviewCanvas`, cập nhật mỗi khung hình):
   - Bỏ `.shadow` và `.clipShape` bo góc quanh preview đang chạy. Bóng mờ trên layer đổi liên tục có thể ép dựng offscreen
     trên Intel → vừa đẹp hơn (phẳng) vừa nhẹ hơn.
3. **Timeline canvas**:
   - Giữ vẽ bằng Core Graphics, không đưa SwiftUI vào hàng / khối.
   - Không thêm animation hay layer động cho vạch đỏ.
   - Màu → `static let` NSColor dùng lại (không tạo mới mỗi lần vẽ).
4. **Vật liệu / blur**: chỉ cho popover / sheet / overlay tĩnh; không cho toolbar, panel, timeline.
5. **Animation**: chỉ đổi tab / mở mục (≤ 0.18s); không animation trên preview / timeline / thanh tiến trình liên tục.
6. **Đo mỗi chặng** (Intel):
   - CPU khi đứng yên (`ps -o %cpu`, 20s);
   - phát nhạc;
   - cuộn / zoom timeline;
   - đổi tab;
   - kéo giãn cửa sổ;
   - mở dự án.

   So với bản trước chặng.

## 4. Hướng đề xuất (tóm tắt — chi tiết ở `DESIGN_SYSTEM.md`)
- Tối trung tính, **1 nhấn #2395c5** chỉ cho: chọn / đang hoạt động / hành động chính / trạng thái karaoke. Vạch đỏ giữ
  màu đỏ, vì chủ dự án gọi nó là "vạch đỏ" trong mọi hướng dẫn.
- Panel phẳng, ghép sát, phân mục bằng tiêu đề + đường kẻ thay vì thẻ. Preview phẳng, chiếm ưu thế.
- Khung cửa sổ:
  - min ~1180 pt;
  - panel trái 300–520 (lý tưởng 360);
  - inspector 280–420 (lý tưởng 320);
  - cho phép thu hẹp.
- Hệ nút 3 cấp: mỗi vùng tối đa 1 nút chính (toolbar: Xuất; tạo karaoke: Tạo; sheet Xuất: Xuất). Mở / Lưu vẫn hiện ngoài
  nhưng ở cấp phụ.
- Thang chữ 6 cỡ, thang khoảng cách 4–6–8–12–16–24, bo góc 0 / 4 / 6 / 8, chiều cao control 22 / 26 / 30.
- Timeline: bảng màu theo nghĩa (loại làn, chọn, đang hát, chưa chắc, khoá, tắt tiếng); bỏ emoji → SF Symbols; hiện từ
  chưa chắc bằng gạch chân màu cảnh báo nhạt.
- Inspector theo ngữ cảnh: Lời / Chữ → Kiểu chữ; Lớp đè → Biến đổi / Màu; Nhạc → Âm lượng / Fade / Cắt; không chọn → Dự án / Khung.
- Làm theo 9 chặng của nhiệm vụ. Mỗi chặng: build, chạy, đo CPU, bản thử riêng cho chủ dự án duyệt trước khi thay app chính.
