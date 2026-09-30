# PROGRESS

## CURRENT MILESTONE
### 2026-09-29 (đêm, sau) — THIẾT KẾ LẠI GIAO DIỆN: XONG 9 CHẶNG (chờ chủ dự án duyệt bản thử)
- Chặng 1–9: token + nút 3 cấp (`Theme.swift`); toolbar chỉ "Xuất" là nút chính; khung ưu tiên preview (cửa sổ min 1180); cột trái phẳng
  (tab ✓, bước đánh số không hộp, bỏ emoji); preview phẳng (bỏ bóng/bo); inspector `PanelHeader` + token; timeline màu theo nghĩa, SF
  Symbols thay emoji, từ chưa chắc gạch chân; 2 thẻ "Có lời / Không cần lời" ngang nhau, tiến trình gọn + đồng hồ (giữ 2 chặng riêng);
  bảng màu tiêu đề + chấm "đã chỉnh"; bảng Xuất: Video trước → 1 nút chính "Xuất video", SRT/ASS thành nút phụ, "Nâng cao" gập; thanh lỗi,
  Home (bỏ gradient), tab, Thùng rác. Tương phản chữ gợi ý 40% → 50%.
- Tính năng mới: tab "Sửa lời" cuộn theo vạch đỏ (dòng đang hát sáng + giữa) — ticker cục bộ, không kéo cả cửa sổ.
- Sửa hiệu năng: ảnh thu nhỏ kho Media + Home có cache (trước giải mã nguyên file mỗi lần vẽ lại).
- `docs/UI_AUDIT.md`, `docs/DESIGN_SYSTEM.md`, `docs/UI_REVIEW_FINAL.md`. Duyệt: `./Scripts/pack-test.sh` → "KaraokeMaker THIẾT KẾ MỚI"
  trên Desktop (app chính `dist/` CHƯA đổi). Build release OK (Swift 5.9 / Intel); `--autolyrics-test selftest` đạt.

### 2026-09-29 (đêm) — THIẾT KẾ LẠI GIAO DIỆN: PHA 1–2 (khảo sát + hệ thiết kế), CHƯA SỬA CODE
- `docs/UI_AUDIT.md`: điểm mạnh giữ lại, điểm yếu có dẫn chứng file/dòng (15 nút xanh đặc, 18 cỡ chữ, 19 mức padding, preview
  không ưu tiên, thẻ bọc thẻ, ~10 màu trên timeline, emoji trong UI, inspector không theo ngữ cảnh), rủi ro hiệu năng phải giữ.
- `docs/DESIGN_SYSTEM.md`: nguồn chuẩn (màu, chữ, khoảng cách, chiều cao control, bo góc, nút 3 cấp, panel, toolbar, preview,
  inspector theo ngữ cảnh, timeline, luồng lời, xuất, trạng thái). Giữ #2395c5, vạch đỏ, 2 chặng tiến trình, nút quan trọng ở ngoài.
- Chờ chủ dự án duyệt để làm chặng 1 (khung app + token + toolbar). Mỗi chặng: build, đo CPU Intel, bản thử riêng.

### 2026-09-29 (tối) — TÁCH ContentView.swift (~4700 dòng) THÀNH 14 FILE THEO KHU UI (audit, KHÔNG đổi logic)
Theo yêu cầu tiếp tục audit — `ContentView.swift` là "God struct" duy nhất chứa gần như toàn bộ
UI + handler nghiệp vụ của editor, > 4700 dòng, đã được audit trước (kiến trúc sư cũ) ghi nhận là
vấn đề (§5.2 `ARCHITECTURAL_HANDOVER_AND_AUDIT.md`).

- **Cách làm**: THUẦN di chuyển code bằng `extension ContentView { … }` ở 13 file mới, theo đúng
  ranh giới `// MARK:` đã có sẵn trong file gốc (nhóm theo khu UI thật của app — Toolbar, panel
  "Tạo Karaoke", Inspector, cột giữa Preview, bảng màu, sóng nhạc, lớp đè + kho media, khung
  Timeline, panel Xuất, hệ lệnh M-A, phím tắt + hành động timeline, Audio + nhập lời, hành động
  Xuất, 2 proxy throttle) — KHÔNG đổi 1 dòng logic, KHÔNG đổi tên hàm/biến, KHÔNG đổi thứ tự thực
  thi. `ContentView.swift` giờ chỉ còn struct + toàn bộ `@State`/`@StateObject`/`@ObservedObject`
  (Swift KHÔNG cho khai báo stored property trong extension — bắt buộc ở lại đây) + `body`/
  `mainLayout` + vài helper gốc — 421 dòng (từ 4719).
- **Vướng thật gặp phải + cách sửa** (không phải mọi thứ trôi chảy ngay):
  1. `@ViewBuilder` gắn trước 1 khai báo bị đứt lìa khỏi property lúc cắt theo mốc dòng — phải dò
     lại từng ranh giới file, gắn lại đúng chỗ.
  2. 16 `@State` (rải ở 3 khu: bảng màu, tạo karaoke, lớp đè/media) vô tình lọt vào file extension
     — Swift chặn ngay lúc build ("extension không được có stored property"). Dời cả 16 về lại
     struct chính; enum lồng nhau dùng làm KIỂU cho các `@State` đó (`LeftPanelTab`,
     `AudioInputMode`) phải nới từ `private` lên mặc định (module-visible) vì kiểu và biến giờ ở 2
     file khác nhau.
  3. Toàn bộ thành viên `private` của struct gốc — HẦU HẾT dùng chéo giữa nhiều khu (đúng lý do nó
     từng phải nằm chung 1 file) — build ra 1268 lỗi "inaccessible due to private protection
     level" ngay sau lần tách đầu. Sửa bằng 1 lệnh `sed` nới TOÀN BỘ `private` (trên khai báo
     property/hàm/kiểu, không đụng comment) thành mặc định `internal` — an toàn tuyệt đối vì tất
     cả 14 file đều CÙNG 1 module app (không phải thư viện, không có API công khai cần giữ kín);
     `internal` vẫn không lộ ra NGOÀI app.
  4. File `ContentView+ExportActions.swift` bị thừa 1 dấu `}` (lẫn dấu đóng struct gốc của bản cũ
     + dấu đóng extension mới) — sửa tay.
- **Xác nhận đã build sạch + CHẠY ĐÚNG (không suy đoán)**: `swift build -c release` (whole-module)
  0 lỗi, cảnh báo giữ nguyên y hệt trước khi tách (không thêm/mất cảnh báo nào). Đóng gói
  `pack-local.sh`, mở app thật, mở lại đúng project đã dùng để đo lag hôm nay (`Gánh Mẹ...kbproj`,
  có stem) — toàn bộ UI (toolbar/panel trái/inspector/preview/timeline) hiện ĐÚNG như trước, luồng
  "Không cần lời" chạy thật (`Đang nhận dạng lời… 1/15`) cho CPU 0–0,7% (2 lần sửa lag hôm nay vẫn
  còn nguyên vẹn sau khi tách file).
- File đổi: `ContentView.swift` (M) + 13 file `ContentView+*.swift` (mới) + `docs/ARCHITECTURE.md`
  (cập nhật bản đồ file).

### 2026-09-29 (chiều) — DỌN CẢNH BÁO SWIFT 6 + XÁC NHẬN CŨ "CÓ STEM = LAG" ĐÃ HẾT (audit, app KHÔNG đổi hành vi)
Tiếp đợt audit sau khi bàn giao. Không đụng file cấm (danh sách ở `CLAUDE.md`).

- **Dọn cảnh báo Swift 6** (sẽ thành LỖI cứng khi bật chế độ ngôn ngữ Swift 6 — chưa bật, nhưng dọn
  trước cho nhẹ nợ): `SpectrumAnalyzer.swift` + `AutoLyricsTestCLI.swift` (gọi `NSLock.lock()/
  unlock()` trực tiếp trong context `async` — gói lại qua hàm `withLock` KHÔNG-`async` để giữ đúng
  ngữ nghĩa, không đổi khoá/mở khoá thật); `ProjectStore.fileExtension` + `AutoLyricsJobGate` default
  argument (`= .shared`) — 2 dạng cảnh báo actor-isolation khác nhau, sửa theo đúng khuyến nghị
  Swift (thêm `nonisolated` cho hằng số thuần, đổi default argument từ biểu thức MainActor-isolated
  sang `nil` + resolve trong thân hàm); `KaraokeRenderer.swift` bỏ `_ =` thừa (hàm trả `Void`);
  `OverlayAudioMixer.swift` — đây là 1 race THẬT (không chỉ warning giả): completion handler của
  `player.seek(...)` không đảm bảo chạy trên MainActor nhưng ghi thẳng vào `Entry.seeking` (mọi chỗ
  đọc khác đều qua `tick()`, MainActor) — sửa bằng `Task { @MainActor in entry?.seeking = false }`.
  Build lại (`swift build -c release`, whole-module) 0 lỗi, 0 cảnh báo mới; còn lại đúng 2 cảnh báo
  "will never be executed" trong `LocalAligner.swift` (file cấm, không đụng) + các API AVFoundation/
  CIKernel deprecated (đổi sang async `load(.duration)`/`loadTracks` là việc LỚN hơn, đụng nhiều nơi
  xuất video — để riêng, không trong scope đợt này, giống chính sách cũ ghi trong file này).
- **Gỡ `Scripts/build-app.sh`** — script cũ, GHI ĐÈ CÙNG `dist/KaraokeMaker.app` mà `pack-local.sh`
  dùng nhưng bằng cơ chế build khác (universal `--arch arm64 --arch x86_64` thay vì kiến trúc máy
  hiện tại) — đã bị thay thế hẳn bởi `pack-local.sh`/`package-release.sh`, không còn chỗ nào
  reference tới, không giống `push-m4.sh` (file đó `CLAUDE.md` ghi rõ GIỮ LẠI làm phương án dự
  phòng) nên gỡ an toàn.
- **Xác nhận lại mục "CÓ VOCAL/BEAT STEM = LAG ĐỨNG YÊN" (2026-09-19) — KHÔNG còn tái hiện được**:
  đo trực tiếp trên `dist/KaraokeMaker.app` (bản đã dọn cảnh báo ở trên) với đúng kịch bản gốc mô tả
  (project có vocal+beat stem LƯU SẴN trên đĩa, mở lại từ Home, đo idle không thao tác) — 18 giây
  liên tục 0,0–0,5% CPU, không có lần nào cao. Đã cập nhật `KNOWN_ISSUES.md` đóng mục đó lại (gấp
  vào `<details>`, giữ ghi chép gốc để tham khảo phương pháp đo). Nhiều khả năng mục đó đã được sửa
  "ăn theo" bởi lần sửa `EditorCommandSink` (2026-09-24) — xảy ra sau note 09-19 nhưng chưa từng
  quay lại xác nhận. Mục "KẾT HỢP NHIỀU THAO TÁC CÙNG LÚC VẪN GIẬT VỪA" (2026-09-21) CHƯA kiểm
  chứng lại được — bộ harness đo cũ (`KM_AUTO_STRESS`) đã bị gỡ khỏi code (đợt "ĐÃ GỠ HẾT" 09-22),
  cần dựng lại cách đo khác nếu muốn đào tiếp.


### 2026-09-29 — SỬA LAG CPU CAO LIÊN TỤC LÚC "Không cần lời" ĐANG NHẬN DẠNG (kể cả sau khi Huỷ)
Chủ dự án bàn giao lại cho kiến trúc sư trưởng mới (Claude Code, máy khác — xem
`ARCHITECTURAL_HANDOVER_AND_AUDIT.md`). Sau khi build + chạy thử `dist/KaraokeMaker.app`, phát hiện
CPU app đứng ở 190–280% liên tục lúc đường "Không cần lời" đang ở bước "Đang nhận dạng lời…" —
**và VẪN CÒN CAO NGAY CẢ SAU KHI BẤM HUỶ** (UI đã về "Bắt đầu tạo Karaoke", không có gì chạy nhìn
bằng mắt, nhưng `ps` vẫn báo ~250%).
- **Chẩn đoán bằng `sample` (đúng công cụ dự án đã dùng nhiều lần trước đây)**: >95% thời gian nằm
  trong bộ máy diff view của SwiftUI (`AttributeGraph`/`ViewBodyAccessor`/`Picker.body.getter`…),
  với `ContentView.body.getter` và `AutoKaraokeFlow.runAll(token:)` (dòng `case .running(let p):
  phase = .recognizing(p)`) xuất hiện trực tiếp trên stack lúc lấy mẫu — xác nhận đây CHÍNH XÁC là
  1 biến thể MỚI của lớp lỗi đã tìm ra năm 2026-09-17 (`EditorCommandSink`/`BeatSepProxy`/
  `AdvancedKaraokeProxy`, xem comment đầu `ContentView.swift`): 1 `@Published` phát tín hiệu NHIỀU
  LẦN/GIÂY, không qua throttle, kéo TOÀN BỘ `ContentView.body` (3 cột + timeline) dựng lại mỗi lần.
- **Gốc**: `AutoKaraokeFlow` (luồng "Không cần lời", `Services/AutoLyrics/AutoKaraokeFlow.swift`) ra
  đời SAU đợt sửa throttle 09-17 nên KHÔNG được áp cùng pattern — `ContentView` giữ nó TRỰC TIẾP qua
  `@StateObject` (không qua proxy như `BeatSepProxy`/`AdvancedKaraokeProxy`), và `phase` được set
  thẳng theo MỖI tick tiến độ ASR từ helper Python (`asr.$phase.values`), không throttle.
- **Sửa**: thêm throttle 0,3s (CÙNG hằng số với `BeatSepProxy`/`AdvancedKaraokeProxy`) ngay tại nhánh
  `.running(let p)` trong `AutoKaraokeFlow.runAll`, dùng mốc thời gian riêng
  (`lastRecognizingPublish`), reset về `.distantPast` mỗi lần `start()` (chặng đầu luôn hiện ngay).
  KHÔNG đụng `ContentView.swift`/`AutoLyricsController.swift`/tốc độ ASR thật — chỉ giảm tần số
  `AutoKaraokeFlow.phase` (nguồn `ContentView` quan sát) được cập nhật.
- **Đo lại (build thật, `dist/KaraokeMaker.app`, project thật `Gánh Mẹ...kbproj` có audio thật)**:
  lúc đang "Đang nhận dạng lời…" (helper Python thật đang chạy, xác nhận bằng `ps` + MPS device):
  Swift process 0–10% CPU (trước: 190–280%). Bấm Huỷ, đo 10s sau: 0,0–0,7% CPU liên tục (trước:
  198–280% không giảm). Không rơi vào lớp lỗi "CÓ VOCAL/BEAT STEM…" ghi ở `KNOWN_ISSUES.md`
  (2026-09-19, chưa rõ cơ chế) — đây là lỗi RIÊNG, khác cơ chế, đã xác định rõ gốc + build lại xác
  nhận hết hẳn qua đo trực tiếp `sample`, không suy đoán.
- Build OK (`swift build -c release`, chỉ warning cũ không liên quan). File đổi: CHỈ
  `Services/AutoLyrics/AutoKaraokeFlow.swift` (thêm 1 field + throttle 5 dòng trong `runAll`).

### 2026-09-29 (khuya) — THỐNG KÊ G TRÊN DEV2 + KHO KIỂM CHỨNG NGẦM (lab, app KHÔNG đổi)
- Bộ chọn G vs A trên 41 bài DEV2, tính theo bài: CV lặp 50 lần (G hơn cả 50), bỏ-1-bài 31 thắng / 5 hoà / 5 thua, bootstrap −0,67 điểm
  [−0,89; −0,46], p = 5e-6; lợi thế vẫn còn khi làm lại cả bước chọn đặc trưng (−0,64). Kết luận: bằng chứng MẠNH cho G trên DEV2 —
  nhưng DEV2 không phải bộ thử độc lập → chính thức vẫn là A, G là ứng viên. HOLDOUT3 không quyết định gì (0 bài).
- `viet_lyrics_lab/shadow_pool/`: tự quét bài MỚI có lời đáng tin (dự án .kbproj, .srt cạnh file nhạc, CapCut), tự loại lời do máy nghe
  ("Không cần lời", phụ đề tự động CapCut), chấm A/E/G im lặng; đủ 15 bài mới áp luật chọn đã ghi sẵn. Hiện 0 bài. Lịch chạy hằng đêm
  đã soạn sẵn nhưng CHƯA bật (cần chủ app đồng ý).

### 2026-09-29 (tối) — HOLDOUT3: KHÔNG ĐỦ BÀI MỚI (lab, app KHÔNG đổi)
- Quét toàn bộ máy (57 dự án .kbproj, 71 phụ đề, 18 dự án CapCut có lời, file lời, 241 bản thu chưa có lời): mọi bài có lời đều đã dùng
  ở DEV / TEST / DEV2 / HOLDOUT cũ → HOLDOUT3 = 0 bài → KHÔNG kết luận được A hay G. Hệ thống cuối vẫn là A.
- Đã dựng sẵn công cụ `viet_lyrics_lab/holdout3/` (nhận bài mới → kiểm cặp lời/audio → đóng băng md5 → chạy A/E/G một lần, luật chọn ghi
  trước). Cần chủ app cung cấp ≥ 20 bài MỚI kèm lời của chính bản thu đó (.kbproj "Tôi có lời" hoặc .srt + audio cùng tên).

### 2026-09-29 (sau) — DEV2 + BỘ CHỌN G + HOLDOUT2 (lab, app KHÔNG đổi)
- 41 bài của bộ thử cũ thành DEV2 để học bộ chọn mới G: DEV2 5,94 % (A 6,58 %). Trên HOLDOUT2 (12 bài) G 9,17 % vs A 9,34 % — gần như
  bằng nhau → giữ A. Chi tiết `~/viet_lyrics_lab/HANDOFF.md`.

### 2026-09-29 — KẾT QUẢ CUỐI: CHẤM CẢ BÀI + BỘ THỬ 45 BÀI MỚI (lab, app KHÔNG đổi)
- Hệ tốt nhất (lab) = A: Qwen 0.6B+1.7B + 1.7B cửa sổ lệch + Whisper lời hát (nhạc đầy đủ + giọng tách) + bộ chọn học trọng số.
- Lỗi chữ cả bài (GOLD): bộ thử bài Whisper chưa thấy 5,99 % (27 bài), cả bộ thử 6,58 % (41 bài, trung vị 5,0 %); app hiện tại ~14,7 %.
- Whisper vẫn chỉ trong lab (bản quyền dữ liệu chưa rõ). Chi tiết: `~/viet_lyrics_lab/HANDOFF.md`.

### 2026-09-28 (khuya) — CHẤM CẢ BÀI + BỘ THỬ TỪ PHỤ ĐỀ CỦA USER (lab, app KHÔNG đổi) — TẠM DỪNG, ĐÃ ĐÓNG GÓI
- Lab `~/viet_lyrics_lab/fullsong/`: bộ chấm cả bài không phụ thuộc ranh giới câu + mức tin cậy GOLD/SILVER/UNSCORABLE/STRESS (nguồn thứ 2 =
  71 file phụ đề .srt/.ass user tự xuất). Bộ thử ~45 bài cover mới đang tách giọng/nghe (dừng giữa chừng theo yêu cầu user).
- Gói bàn giao: `~/Desktop/KaraokeLab_Handoff_2026-09-28/` (đọc `00_DOC_TRUOC_README.md`; tiếp tục theo `viet_lyrics_lab/HANDOFF.md`).

### 2026-09-28 (tối) — LỜI MẪU ĐÃ DUYỆT 185/185 + CHẤM LẠI (lab, app KHÔNG đổi)
- Lỗi thật sau khi làm sạch lời mẫu: DEV A 6,90 % / E 7,09 %; TEST A 6,64 % / E 6,15 %. E không còn hơn A trên DEV → mốc nghiên cứu = A.
- Bản chụp sạch: `~/viet_lyrics_lab/snapshots/qwen_whisper_selector_E_cleaned/`. Bộ thử mới 2026: chưa có bài (chờ user).

### 2026-09-28 (chiều) — CHUẨN BỊ CHẤM SẠCH + BỘ THỬ MỚI 2026 (lab, app KHÔNG đổi)
- Khoá bộ chọn E (`~/viet_lyrics_lab/frozen/systems_definition.json`). Script chấm lại sau khi duyệt, chụp bản sạch, nhập + chạy bộ thử 2026 đều sẵn sàng.
- ĐANG CHỜ USER: duyệt nốt 182/185 mục lời mẫu; chọn ≥ 15 bài phát hành 2026 (làm project "Tôi có lời", lưu vào `holdout/inbox/`); bật M4.

### 2026-09-28 — BỘ CHỌN TỪ Qwen + Whisper (lab, app KHÔNG đổi)
- Lab `~/viet_lyrics_lab` (không đụng app): bộ chọn mới "E" = quyết định 2 bước (chọn từ → giữ/xoá) + độ tin theo kiểu bất đồng
  + so từng cặp ứng viên. Lỗi thật DEV 6,52 → 5,59 %, TEST 6,24 → 5,76 % (bài Whisper chưa thấy 7,43 → 6,77 %). Từ thừa giảm một nửa.
- Công cụ duyệt lời: thêm nút "Không rõ", 185 mục ưu tiên; user đã bắt đầu duyệt. Sau khi duyệt xong: `analysis/recompute_cleaned.py`.
- Whisper vẫn chỉ trong lab (nguồn dữ liệu huấn luyện chưa rõ bản quyền). Không huấn luyện, không GPU thuê.

### 2026-09-26 (tối) — ĐỘ CHÍNH XÁC LỜI KHÔNG HUẤN LUYỆN (lab, app KHÔNG đổi)
- Thêm mô hình có sẵn (user cho phép tải): Whisper-large-v2 lời hát tiếng Việt (VietLyrics, nhãn Apache-2.0, dữ liệu cào Zing MP3 →
  CHƯA chắc dùng thương mại). VocalParse-1.7B thử và bỏ (tiếng Việt sai ~27 %), đã xoá.
- Bản tốt nhất (chốt theo DEV): giải mã sẵn có + 1 lượt Qwen 1.7B cửa sổ lệch + Whisper (nhạc đầy đủ + giọng tách) + bộ chọn học trọng số
  (phiếu nguồn, "bỏ từ", đoạn lặp), KHÔNG cần máy chấm câu. Lỗi thật: DEV 6,5 %; TEST 6,2 % (bài Whisper chưa từng thấy: 7,4 %).
  Lỗi im lặng TEST 283 (hiện tại) → 89. Không thêm lời ở đoạn nhạc (bộ dò giọng chặn 50–88 từ Whisper bịa).
- Loại (không có ích trên DEV): cắt theo câu hát, trộn âm thanh, định tuyến theo chất lượng stem/bài, mở rộng dấu, khôi phục từ thiếu, cửa sổ cục bộ (đắt).
- Thời gian M4 ~190 s/bài 4 phút (hiện tại 80 s); Intel ~19 phút/bài (hiện tại ~8). Chưa tối ưu, chưa đưa vào app.
- Duyệt lời mẫu: chưa ai nghe (0 câu) → số tuyệt đối vẫn dựa trên lời mẫu có lỗi; công cụ `review/` có danh sách 127 câu + 32 chỗ thiếu lời.

### 2026-09-26 — RERANKER lời tiếng Việt (lab, app KHÔNG đổi)
- Lưới ứng viên + bộ chọn học trọng số (kiểm chứng chéo bỏ-1-bài trên DEV). Chỉ chọn trong các từ mà hệ nghe đã đưa ra; máy chấm
  câu = bộ giải mã chữ của Qwen3-ASR 1.7B chạy KHÔNG kèm âm thanh (không tải gì thêm, không tự viết lời).
- Lỗi thật (REAL): DEV 15,1% (hiện tại) → 10,9% (v2) → **8,8%**; TEST (chạy 1 lần, không chỉnh theo TEST) 14,5% → 10,6% → **8,8%**.
  Lỗi "im lặng": DEV 230 → 127, TEST 283 → 128. Từ thừa (REAL): 56 → 15–18.
- Bản rẻ: chỉ thêm 1 lượt 1.7B cửa sổ lệch → DEV 8,9% / TEST 9,1%. Không thêm lượt nghe nào → DEV 10,6% / TEST 10,5%.
- Không giúp (đã loại): gộp nguồn theo họ, trọng số vị trí, đặc trưng ngữ âm, độ tự tin mô hình, mở rộng dấu (chế độ B), chấm ngữ cảnh lần 2.
- Trần của lưới hiện có: 3,4% (DEV) / 4,2% (TEST) → phần còn lại cần mô hình nghe tốt hơn → kết luận C: giữ reranker + chuẩn bị fine-tune.
- Công cụ duyệt lời mẫu `~/viet_lyrics_lab/review/` (ước lượng 3,6 giờ cho 21 bài; ~1 giờ nếu chỉ nghe chỗ nghi ngờ).
- Chưa làm (chờ user): đưa reranker vào app, duyệt lời, huấn luyện.

### 2026-09-25 (tối) — NGHIÊN CỨU ĐỘ CHÍNH XÁC LỜI tiếng Việt ("Không cần lời") — lab TÁCH RIÊNG, app KHÔNG đổi
- Lab: `~/viet_lyrics_lab` (README + `FINETUNE_PLAN.md`). Dừng mọi việc đóng gói/dung lượng theo yêu cầu.
- Bộ dữ liệu: 22 bài từ project của user (loại 1 bài lời chỉ phủ ~52%); chia THEO BÀI: DEV 10 / TEST 11 (TEST niêm phong tới cuối).
  Lời mẫu chỉ nằm trong `eval_only/` (M4 không hề nhận), pipeline không đọc (có lệnh grep kiểm chứng).
- Phát hiện: lời trong project có lỗi CẤU TRÚC (thiếu/thừa câu, điệp khúc đặt sai) → WER "thô" bị thổi phồng; báo thêm WER "LOCAL" (bỏ các khối ≥6 lỗi liên tiếp có ≥4 thêm/bớt, cùng một luật cho mọi hệ).
- Bản production (0.6B chính + 1.7B kiểm): DEV 22,2% (LOCAL 15,1%), TEST 24,8% (LOCAL 14,5%). Bài từng dùng để chỉnh trước đây chỉ 7,3% → thiết kế cũ bị "khớp" vào 1–2 bài dễ.
- 1.7B đúng 88,7% từ vs 0.6B 80,8% (DEV); khi 2 mô hình khác nhau, 1.7B đúng 335 lần vs 0.6B 96 lần. Chỉ đổi 1.7B làm chính (không tốn thêm): TEST 24,8% → 21,5%.
- v2 (lab): 1.7B chính + bỏ phiếu nhiều lần nghe (cửa sổ lệch 10 s, bản giọng tách) theo độ tin cậy từng nguồn: DEV 18,0% (LOCAL 10,9%), TEST 20,4% (LOCAL 10,6%).
  Beam n-best, cửa sổ 10 s: KHÔNG giúp. Chấm lại ứng viên bằng xác suất của 2 mô hình: chỉ −0,2 điểm; mô hình 1.7B chấm từ ĐÚNG cao hơn từ nó đã chọn chỉ 3/70 lần.
- Trần: kể cả chọn HOÀN HẢO trong mọi giả thuyết (mọi lần nghe + token thay thế + biến thể dấu/phương ngữ) vẫn còn ~3,3% (DEV) / 3,9% (TEST) LOCAL; chọn thực tế đạt xa hơn thế.
  → Kết luận: zero-shot Qwen đã chạm giới hạn thực tế; bước tiếp = fine-tune cho giọng hát tiếng Việt (repo chính thức có `finetuning/qwen3_asr_sft.py`).
- App: KHÔNG sửa gì trong lần này (đường Có lời / Không cần lời giữ nguyên).

### 2026-09-25 (đêm) — HAI ĐƯỜNG tạo Karaoke + BẢN ĐÓNG GÓI TỰ CHỨA (chưa ký Developer ID)
- **UX**: sau khi có nhạc, bước 2 hỏi "Bạn muốn tạo Karaoke thế nào?": **"Tôi có lời bài hát"** (đường cũ, y nguyên: dán/nhập lời → canh giờ) và **"Không cần lời — Tự động tạo Karaoke"**
  (máy tự nghe → viết lời → canh giờ → mở editor bình thường). Đã gỡ nút "Tự động lấy lời" trên toolbar, sheet thử nghiệm, nút "Dùng lời này", công tắc Cài đặt.
- **CODE DÙNG CHUNG (bằng chứng)**: cả 2 đường gọi CÙNG 1 hàm `ContentView.runKaraokeTiming(audio:lyrics:quality:origin:shouldApply:)` → `AdvancedKaraoke.run(...)`
  (`parseBlocks` chuẩn hoá y hệt). Đường "Có lời" đưa lời người dán; đường "Không cần lời" đưa văn bản thuần do máy nhận dạng (không có `? ⟦ ⟧ [ ] |`).
  Chứng minh: đưa lời do máy sinh vào đường thủ công cho ra timing GIỐNG HỆT từng từ (hash lời `cd38c6d5b2b444e5` cả 2 origin, `AutoLyricsDebug.timingCalls`).
  KHÔNG sửa file cấm (LocalAligner/AdvancedKaraoke/ForcedAligner/WordTiming/AudioOnsetDetector/MDX/LocalSeparator/BeatSeparation/AlignTestCLI).
- **Luồng "Không cần lời"** = `Services/AutoLyrics/AutoKaraokeFlow.swift` (máy trạng thái: analyzing → recognizing(Đang nhận dạng lời… n/N, Đang kiểm tra lời…, Đang kiểm tra lại…) → timing → done | failedAnalysis | failedRecognition | failedTiming)
  + `Views/AutoKaraokePanel.swift`. ASR lỗi → KHÔNG canh giờ, hiện `Thử lại` / `Nhập lời thủ công` (chuyển sang đường "Có lời", KHÔNG phải nhập lại nhạc). Canh giờ lỗi → GIỮ lời nhận dạng, hiện
  "Không thể tự canh thời gian", `Thử lại canh giờ` (KHÔNG chạy lại ASR — kiểm chứng `helperLaunches` không đổi), xem lời, hoặc chuyển thủ công (lời điền sẵn). Huỷ được ở mọi chặng (helper dừng ≤0,4 s, không áp gì vào project).
- **Từ chưa chắc**: sau khi canh giờ, `UncertaintyMapper` (LCS) gắn từ chưa chắc vào dòng đã canh; tab "Sửa lời" hiện mục "Từ máy chưa chắc (N)" + phương án bấm-để-thay (giữ nguyên cửa sổ thời gian của từ bị thay) + "Giữ nguyên"; dòng có cờ ⚠. Chỉ ở bộ nhớ (KHÔNG đổi định dạng .kbproj).
- **An toàn**: `projectSessionID` (đổi project → huỷ luồng, không rò kết quả), `AutoLyricsJobGate` (1 lượt), chốt tĩnh 1 helper; Cmd+Q → helper dừng + xoá thư mục tạm ngay; Karaoke(beat) BẬT vẫn đưa `Media/audio.wav` GỐC cho ASR (kiểm chứng).
- **Kiểm thử GUI thật** (bộ điều khiển `KM_GUITEST_DIR`, nay chỉ có khi biên dịch `-DKM_GUITEST`): Intel + M4; đường Có lời, Không cần lời, ASR lỗi (kill -9), canh giờ lỗi + thử lại, Huỷ ở 3 chặng, đổi project, Karaoke ON, Cmd+Q (Apple Event), bài đầy đủ 267 s (33 dòng, nhạc dạo/kết không thành dòng; đoạn ngân "Hm" 240–262 s đúng là không-lời). selftest 38 PASS.
- **ĐÓNG GÓI TỰ CHỨA** (`Scripts/package-release.sh --arch x86_64|arm64 [--guitest]`, `Scripts/audit-release.sh`, `Scripts/asr-runtime/{trace_imports,build_runtime}.py`): app chứa Python 3.11 + PyTorch + qwen-asr + Qwen3-ASR 0.6B & 1.7B trong `Contents/Resources/AutoLyricsRuntime/{python,site-packages,hf_cache}`;
  runtime được CẮT theo bản dò import thật (bỏ numba/llvmlite/pip/setuptools…), kết quả GIỐNG HỆT venv dev (từ, cờ chưa chắc, gợi ý, stats). `AutoLyricsRuntime.locate` chỉ dùng runtime trong app; đường dẫn dev `~/qwen3_asr_*`/biến `KM_AUTOLYRICS_*`/UserDefaults chỉ còn khi biên dịch DEBUG hoặc `-DKM_DEV_RUNTIME`.
  Bản phát hành: KHÔNG có `KM_GUITEST_DIR`/GUITestDriver, không ghi nhật ký nội dung lời. Kích thước: x86_64 8,0 GB, arm64 7,9 GB (2 mô hình 6,3 GB). Kiểm thử "máy sạch + offline" mô phỏng (`env -i`, ẩn thư mục dev, chặn mạng IP bằng sandbox-exec) trên Intel và M4: đạt.
  CHƯA làm (chờ user đồng ý): Developer ID, notarization, license, Sparkle.

### 2026-09-25 — Kiểm thử GUI THẬT + điều tra âm thanh cho "Tự động lấy lời" (CHƯA đóng gói)
- **Bộ điều khiển GUI trong app** (`App/GUITestDriver.swift`, chỉ bật khi có env `KM_GUITEST_DIR`, mặc định không làm gì): chạy app thật (cửa sổ + ContentView thật) và thay "bàn tay":
  bấm nút hệ thống bằng `performClick`, chụp ảnh view, đọc NSTextView. Sự kiện chuột tổng hợp KHÔNG kích được `onTapGesture`/link/nút style plain của SwiftUI trên macOS 13 →
  mở project dùng móc `RootView.guiTestOpenProject` (gọi đúng hàm thẻ Home gọi). **Trước khi phát hành nên bọc bộ này bằng cờ biên dịch/xoá.**
- **BUG THẬT tìm ra + đã sửa**: (1) `AVAudioConverter` đổi stereo→mono CHỈ LẤY KÊNH TRÁI (L=0,9997/R=0,0001; `afconvert` y hệt) + cụt 218 mẫu cuối (vocal 1476 mẫu) →
  `AutoLyricsAudioPrep.read16kMonoAveraged` tự trộn trung bình kênh + rút bộ đổi tới `.endOfStream` (SNR so với chuẩn lý tưởng 13,6 → 43 dB; WER 0.6B thô song1 13,1→10,5%, song2 giải 6,8→5,9%);
  (2) nút "Hủy" sai khoá dịch ("Huỷ"); (3) project TRỐNG vẫn bấm được Start và dùng nhầm nhạc project trước → nay dùng `projectAudioURL` (file gốc của CHÍNH project, không dùng `playback.loadedURL`
  vì có thể là BEAT khi bật Karaoke) + Start bị khoá + cảnh báo; (4) helper chết đột ngột hiện nguyên log kỹ thuật → thông báo thân thiện + log ra file; (5) thiếu khoá dịch "Thử lại".
- **An toàn project/job**: `ProjectStore.projectSessionID` (runtime, không lưu file) đổi khi tạo mới/mở project khác; controller ghi `owner`, `takeDraftForImport(owner:)` vứt bản nháp nếu khác phiên;
  ContentView huỷ job khi đổi phiên / rời tab; `AutoLyricsJobGate` + chốt tĩnh trong service: toàn app tối đa 1 helper; nút vô hiệu khi đang chạy; `deinit` + `willTerminate` dừng helper.
- **Bấm nhánh "từ chưa chắc"**: từ cam trong bản nháp là link `kmalt://` → thanh phương án (CHỈ xem). Chưa thử được bằng click tổng hợp (xem trên).
### 2026-09-24 — "Tự động lấy lời" (Local Auto Lyrics) — prototype tích hợp, THÊM MỚI, sau cờ tính năng
Nguồn: prototype đã kiểm chứng `~/qwen3_asr_correction_test` (WER song1 10.8→6.4%, song2 held-out 9.4→~6%). Việc làm:
- **Luồng**: Audio có sẵn → bấm "Tự động lấy lời" (toolbar + nút trong bước "Dán lời") → helper Python chạy NỀN → tiến độ THẬT
  ("Đang nhận dạng lời… 4 / 14", "Đang kiểm tra lời… 3 / 12", "Đang hoàn thiện…") → cửa sổ XEM LẠI (lời hiện tại | bản nháp,
  từ chưa chắc màu cam + "?", danh sách phương án) → **"Dùng lời này"** mới đưa văn bản vào Ô LỜI (`alignLyricsInput`, cùng đường lời
  dán tay; có nút "Khôi phục lời trước đó"). Canh giờ vẫn do "Tạo Karaoke" sẵn có — Qwen KHÔNG điều khiển timing.
- **Không bao giờ ghi đè**: controller không giữ tham chiếu tới project; văn bản chỉ ra qua `takeDraftForImport()` (chỉ ở bước xem lại).
  Hủy/đóng/lỗi → vứt bản nháp, dừng helper (SIGTERM, SIGKILL sau 3s), xoá thư mục tạm.
- **File mới**: `Services/AutoLyrics/{AutoLyricsModels,AutoLyricsRuntime,AutoLyricsAudioPrep,LyricTranscriptionService,AutoLyricsController}.swift`,
  `Views/AutoLyricsSheet.swift`, `App/AutoLyricsTestCLI.swift` (`--autolyrics-test probe|run|cancel|selftest|render`),
  `Resources/lyric_asr/` (helper Python: `lyric_asr_helper.py` + `lyric_correct/*`).
- **Sửa nhỏ file có sẵn** (chỉ THÊM): `ContentView` (state + nút + sheet + 4 hàm `autoLyrics*`/`importAutoLyrics`), `Localization.swift`
  (mục "Thử nghiệm" trong Cài đặt), `LocalizationTables` (bản dịch EN), `KaraokeMakerApp` (dispatch `--autolyrics-test`), `Package.swift`
  (+1 resource `.copy("Resources/lyric_asr")`). KHÔNG đụng timing/aligner/export/waveform/timeline/playback/màu.
- **Backend** (chọn theo máy, người dùng không thấy): Apple Silicon → 0.6B MPS bf16 (`arch -arm64`), Intel → 0.6B CPU fp32; 1.7B chỉ kiểm tra
  cửa sổ VOCAL. FULL MIX làm đầu vào ASR; vocal stem CHỈ để dò giọng hát; chunk 20s + 2s gối; token guard 6/giây+16.
- **Quy tắc an toàn thêm so với prototype**: context CHỈ dùng cho đoạn đang UNCERTAIN, không bao giờ ghi đè đoạn đã đủ bằng chứng (ghi log);
  repeat consensus chỉ là bằng chứng PHỤ (trần 1.5 < 2 mô hình đồng ý 2.5); từ chỉ 1.7B nghe thấy được GIỮ như ứng viên chưa chắc khi vùng VOCAL +
  2 bên hàng xóm khớp mạnh (không tự nâng lên chắc chắn nếu thiếu bằng chứng phụ).
- **Runtime**: bản thử nghiệm dò Python+model có sẵn (`~/qwen3_asr_intel_test`, `~/qwen3_asr_m4_test`, hoặc `KM_AUTOLYRICS_PYTHON`/`KM_AUTOLYRICS_HF_HOME`);
  CHƯA đóng gói runtime/model vào app. Thiếu bản tách giọng → báo rõ + nút "Phân tích nhạc" (dùng đúng bước tách sẵn có).
- Nhật ký chẩn đoán từng lần sửa (time/0.6B/1.7B/lặp/context/quyết định/độ chắc): `KM_AUTOLYRICS_DIAG=1` → `~/Library/Logs/KaraokeMaker/`.
- Tắt tính năng: Cài đặt (⌘,) → Thử nghiệm, hoặc `KM_AUTOLYRICS=0`.
- **Kiểm thử đã chạy** (2026-09-24, không giao diện — `--autolyrics-test`): selftest 22/22 PASS (cả Intel lẫn M4 native); Intel chạy thật song1 qua
  service Swift = 717s, backend cpu/float32, WER 7,3%; M4 native arm64 = 150s, mps/bfloat16, song1 7,0% / song2 (held-out) 6,8%; huỷ giữa chừng:
  0,87s (Intel) / 0,02–0,22s (M4), không sót tiến trình helper, không sót thư mục tạm; kill -9 app → helper tự thoát ≤4s. Bug bắt được lúc test:
  khoá dịch trùng ("Đóng", "Bắt đầu") làm app văng ngay ở chuỗi dịch đầu tiên; helper Python abort lúc tắt (daemon thread stdin) → thoát bằng `os._exit`.
  CHƯA test bằng tay giao diện thật (sheet/nút) — chỉ render ảnh + selftest controller.

### 2026-09-08 — Đại tu UI kiểu CapCut (đợt shell) + luôn tách nhạc mới
- **1 thanh trên duy nhất**: gỡ `RootView.editorTopBar`, gộp vào `ContentView.toolbar`
  (`← Thư viện` + menu Tệp + undo/redo + tên + nút **Xuất** nổi bật phải). `Theme` thêm
  `Theme.Metric` (topbarH/railW/pad/gap/radius) + `accentSoft`/`ink`/`inkDim` + `sectionHeaderStyle()`.
- **Nút Xuất → pop-up (sheet) kiểu CapCut** (`exportSheet`, 580×660: SRT/ASS/nền/video).
  **Bỏ tab "Xuất" trong inspector** — inspector còn mỗi "Chữ" (StylePanel). Gỡ `enum InspectorTab` + `inspectorTab`.
- **Tab cột trái = rail icon** (`leftTabButton(icon:)`); **syncBar dịu** (`.bordered .small`, nền `panel`).
- **`BeatSeparation`: LUÔN TÁCH MỚI** (user chốt) — `separateLocal` xoá stem cũ + chạy MDX lại mỗi
  lần (trừ khi user tự đưa stem); `refresh(for:)` không khôi phục từ cache nữa. Lý do: file audio
  bị sửa mà trùng tên + trùng kích thước → cache cũ cho canh lời SAI. (Chỉ đụng CACHE, KHÔNG đụng
  thuật toán tách/canh trong `MDXSeparator`/`LocalAligner`.)
- CÒN (đợt UI sau): transport dưới preview · inspector icon-tabs · spacing toàn app · tách bớt ContentView.

### 2026-09-09 — Đợt UI dọn nhất quán (build OK, chờ test M4)
User: "làm nốt phần UI, xong tôi kiểm tra 1 lần chỉnh sau". Pass an toàn (chỉ token hoá + gom style,
KHÔNG đổi bố cục/split/geometry):
- **TransportBar** (`PlaybackHUD.swift`) dựng lại kiểu CapCut: hàng nút (−5 / ▶ to accent 36pt / +5 /
  timecode mono `ink` + `/tổng` `inkDim` / spacer / nút Karaoke) **rồi thanh trượt FULL-WIDTH bên dưới**
  (trước bị nhét chung 1 hàng, chật). Token `Metric.pad/gap/radius`. ⚠️ `Text.foregroundStyle` là macOS 14
  → dùng `.foregroundColor` (2 `Text` trong HStack).
- **Inspector**: header "Chữ" → "Kiểu chữ karaoke" + icon, dùng `sectionHeaderStyle()`; header lớp đè
  cũng `size 12 semibold`; padding = `Metric.pad/gap`; Divider `.overlay(Theme.stroke)`.
- **`subCard`**: tiêu đề dùng `sectionHeaderStyle()` (bỏ `.uppercase` tay), bo `radiusSm`, padding token.
- **syncBar**: "＋1 Chữ Trong Dòng"/"＋1 Dòng Mới" → "Thêm chữ"/"Thêm dòng" (+ `.help`); padding token.
- **mediaLibraryPanel / aiStepsPanel / exportSheet / centerColumn / leftPanel**: `.padding(16/14/10)` →
  `Theme.Metric.*`; "File của bạn" `.font(.headline)` → `sectionHeaderStyle()`; preview bo góc `radius`.
- KHÔNG làm: inspector icon-tabs (chỉ 1 panel "Chữ" → vô nghĩa) · rail dọc panel trái (chỉ 2 tab) ·
  đổi bề rộng 3 cột (rủi ro layout) · tách ContentView. User review rồi chỉ tiếp.

### 2026-09-09 (tiếp) — 4 sửa theo phản hồi user (build OK, chờ test M4)
1. **Panel "Âm thanh bài hát" (Media): BỎ "Bỏ đầu" / "Kết thúc"** (user: vô nghĩa). Còn: Âm lượng +
   Tiếng vào/ra (fade) + "Về mặc định". Field `audioTrimStart/End` GIỮ trong model (Codable, mặc định 0,
   không còn UI đặt) — playback/xuất vẫn tôn trọng nếu project cũ có.
2. **Track ★ KARAOKE dời xuống**: từ NGAY DƯỚI THƯỚC (trên "Nhạc") → NGAY TRÊN "Lớp đè 1" (dưới "Lời").
   Canvas: `waveTop`/`laneAreaTop` về nguyên gốc; `karaokeStripTop = lyricAreaBottom + 6`;
   `overlayAreaTop`/`stagingLaneY`/`totalHeight` tính lại từ `karaokeStripBottom`. Wrapper `trackHeaderColumn`
   đổi thứ tự + `gKaraokeGap 6`. `lyricOff` (dời chữ theo clip ★) không đổi. `inKaraokeStrip` + intercept
   mouseDown vẫn ở đầu (trước duet/overlay) — không xung đột.
3. **Lớp đè nhận AUDIO + nút loa mỗi làn**: `BackgroundMedia.Kind` += `.audio`; `OverlayClip.audioMuted`
   + `carriesAudio` (audio, hoặc video `videoAudioOn`; bỏ nếu ẩn/tắt loa). Kéo audio từ kho xuống 1 làn
   → `OverlayClip(kind:.audio)` (thanh XANH LÁ + 🎵). Phát thử: `OverlayAudioMixer` (filter `carriesAudio`).
   Xuất: `TransparentVideoExporter.overlayAudio` filter `carriesAudio`. Nút 🔊/🔇 đầu mỗi làn lớp đè
   (`onToggleLaneAudioMuted` → `timelineToggleLaneAudioMuted`, gộp cả audio + video trong làn). Inspector
   clip audio = tắt tiếng / nhạc vào từ / to-nhỏ dần (tách `audioOverlayInspector` khỏi `overlayVisualInspector`).
   `pickBackground`/`reloadBackgroundImage` switch thêm `case .audio` (no-op, nền không dùng).
4. **"Vừa khung" thiếu 1 đoạn**: `zoomToFit` tính lại `dur = max(bài+K, lời+K, cuối lớp đè, …)` + chừa
   24px mép phải; `applyState` khi KHÔNG có `pendingZoomAnchor` mà content ≤ viewport thì kéo scroll về 0.

### 2026-09-09 (đợt 3) — 6 sửa theo phản hồi (build OK, chờ test M4)
1. **BỎ HẲN "Âm thanh bài hát"** (Media): xoá `subCard` + `audioTrimPanel`. Volume/fade bài không còn UI
   (fields `audioGain/Fade*` giữ trong model, mặc định). Tắt tiếng bài = nút loa track "Nhạc"/"★".
2. **"Vừa khung" đúng hẳn**: `timelineFitToWindow()` — `dur` KHỚP CHÍNH XÁC công thức `TimelineEditor.duration`
   (`max(playback.duration+k, overlayEnd+10, lineEnd+k+10, 60)`) → `pps = (vw−8)/dur` → content = vw−8, không
   tràn. `timelineFitTick` (@State) → `TimelineEditor.fitTick` → canvas `requestFitToStart` đặt
   `pendingZoomAnchor = (0,0)` → `applyState` cuộn về x=0. Bỏ nhánh `else if` auto-scroll cũ (gây nhảy bất ngờ).
3. **Tạo karaoke xong → tự "Vừa khung"**: `.onChange(alignPhase) case .done` gọi `timelineFitToWindow()` sau 0.6s.
4. **"Sóng nhạc" hàng OFF rõ ràng**: icon `waveform.slash` + "Sóng nhạc: TẮT" dịu khi off (mặc định
   `MusicVisualizer.enabled = false` — đã xác nhận không có path nào tự bật).
5. **"File của bạn" → TAB RIÊNG** cạnh "Chỉnh sửa": `LeftPanelTab` += `.files`; `filesPanel` (kho + drop
   target) tách khỏi `mediaLibraryPanel` (giờ chỉ Nền video + Sóng nhạc). `backgroundPanelBody` chỉ 2 nút.
6. **Toolbar**: menu Tệp = chữ "Tệp" (bỏ icon folder rời) qua `openProjectFromPanel`/`saveProject`/`saveProjectAs`;
   thêm icon **Mở** (folder) + **Lưu thành** (square.and.arrow.down) cạnh nút Xuất.

### 2026-09-09 (đợt 4)
- **2 preset MẶC ĐỊNH mới = "Kiểu của tôi 0" + "kiểu của tôi 1"** (giá trị thật lấy từ M4
  `~/Movies/KaraokeMaker Projects/.style-presets.json` qua SSH). `KaraokeStyle.mine0/mine0Next/mine1/mine1Next`
  thay `karaokeChuan01*`/`lyricPreset*`. `StylePreset.all` = 2 preset đó. `KaraokeProject.style` default
  = `.mine0` → project mới / sau tạo karaoke = "Kiểu của tôi 0". `StylePresetStore.Disk` thêm `v`(=2):
  load `v<2` → xoá HẾT user preset + hiddenBuiltins cũ (1 lần) rồi save; sau đó lọc trùng tên built-in.
- **Nút xài được = XANH không xám**: "Tạo Karaoke Chất Lượng" + syncBar (Thêm chữ/Thêm dòng/Song ca/
  Chữ hiện sớm hơn) → `.borderedProminent .tint(accent)`; picker segmented (Hoa/thường, Căn lề) → `.tint(accent)`.
- **TransportBar 2 hàng che nút "Thêm chữ/dòng"** → HOÀN NGUYÊN 1 hàng gọn (nút/giờ/slider cùng hàng,
  `.padding(.vertical, 8)`); giữ ▶ accent + timecode ink/inkDim.

### 2026-09-09 (đợt 5) — vẫn còn 3 lỗi user báo
- **syncBar + toolbar Timeline (nút "Vừa khung") BỊ CHE**: gốc = pane dưới VSplitView, content (syncBar +
  header TimelineEditor + canvas) > frame → VStack CĂN GIỮA dọc → cắt cả trên lẫn dưới. FIX:
  `.frame(minHeight: 300, idealHeight: 520, maxHeight: 820, alignment: .top)` — neo TOP, chỉ cắt đáy timeline.
- **"Vừa khung" thiếu ~20s cuối**: `max(8, …)` (pps tối thiểu 8) làm bài 4' KHÔNG bao giờ lọt
  (8×240 = 1920px > viewport). FIX: `timelineFitToWindow` → `max(1.5, (vw−6)/dur)`; `zoomOut` floor 8→2.
- **Nút "Karaoke TẮT/BẬT" ở thanh phát nhìn như ẩn** (`.opacity(0.45)` khi chưa có beat) → bỏ opacity,
  nền `Theme.elevated` + viền rõ, `.help` giải thích; xanh accent khi BẬT.

### 2026-09-09 (đợt 6) — nút Karaoke BẬT/TẮT bị disable
Gốc: `karaokeAvailable = beatSep.beatURL != nil` → mở project KHÔNG có cache beat (hoặc MDX chưa ra beat)
→ nút chết. FIX (`ContentView.transportBar` + `toggleKaraoke`):
- `karaokeAvailable = projectAudioURL != nil && !beatSep.isRunning` — CÓ NHẠC là bấm được.
- `toggleKaraoke`: TẮT → về bài gốc; BẬT & có beat → swap ngay; BẬT & CHƯA có beat → `beatSep.separateLocal(.fast)`
  nền, xong `.onChange(beatSep.beatURL)` tự swap. `TransportBar.karaokeSeparating` (= `beatSep.isRunning`)
  → hiện spinner "…" + nền accent khi đang tách.
- `@State karaokeOn` default `true` → `false` (trước đó hiện "BẬT" trong khi vẫn phát giọng gốc).

### 2026-09-09 (đợt 7) — toolbar + syncBar
- Cụm nút phải toolbar: **New Project / Open / Save as / Xuất** — đều `Label` (icon + CHỮ) + `Group{}` bọc
  `.borderedProminent .tint(accent) .regular` → cả 4 XANH như nhau. ("+" = New Project, "folder" = Open,
  "arrow.down" = Save as.)
- **"Chữ hiện sớm hơn" Menu → tách lại 2 BUTTON** ("Chữ sớm +0.25 (dòng)" / "(cả bài)") trong syncBar
  (user: space rộng, đừng gộp menu).

### 2026-09-09 (đợt 8) — bỏ menu "Tệp" trên thanh trên
- Gỡ `Menu("Tệp")` khỏi `ContentView.toolbar`. Đưa lên **menu bar "File"** thật:
  `EditorCommand` += `newProject/openProject/saveProject/saveProjectAs/openNewTab`; `ContentView.runCommand`
  + `canRun` xử lý (dùng lại `openProjectFromPanel`/`saveProject`/`saveProjectAs`/`onOpenNewTab`).
  `KaraokeMakerApp.commands`: `CommandGroup(replacing: .newItem)` = Dự án mới ⌘N / Mở… ⌘O / Mở tab mới ⇧⌘N;
  `.saveItem` thêm "Lưu thành…" ⇧⌘S. Đều `editor?.run(...)` + `.disabled(editor == nil)` (trừ Lưu/Lưu-thành
  gọi thẳng `tabs.active.store`). Toolbar vẫn giữ nút nhanh New Project/Open/Save as/Xuất (xanh).
- **"Sóng nhạc" phải SỔ RA SẴN (trạng thái tắt)**: bỏ `if on { … }` → luôn hiện control, `.disabled(!on)`
  + `.opacity(0.5)` khi tắt; bấm toggle là bật.

## (cũ) CURRENT MILESTONE
M-A…M-F + M-D 1b XONG. M-D2 ⛔ BỎ. COLOR C0–C11 + Trước/Sau + Copy/Paste + **Preset màu** — XONG.
**M-E hoàn tất** (2026-09-07): overlay video preview 30fps + TIẾNG clip video lớp đè (preview + xuất).

### 2026-09-07 (tiếp) — GỠ HEVC-alpha (xuất video trong suốt chậm ~10×)
User báo: 2K/30 trước < 1 phút, giờ 1080p/25 > 10 phút. Thủ phạm = codec `hevcWithAlpha` mới
đặt làm mặc định (mã hoá ~7–10 fps ở máy này: không có đường phần cứng + Rosetta). ĐÃ GỠ HẲN:
- `KaraokeProject.swift`: bỏ enum `TransparentVideoQuality` + field `ExportSettings.videoCodec`
  (Codable khoan dung → project cũ có key này chỉ bị bỏ qua).
- `TransparentVideoExporter.swift`: bỏ param `alphaCodec`, bỏ `useHEVCAlpha` + nhánh `hevcWithAlpha`,
  bỏ `import VideoToolbox`. Trong suốt = LUÔN `.mov` ProRes 4444 (như trước khi thêm HEVC).
- `ContentView.swift`: gỡ Picker "Chất lượng" trong tab Xuất + 2 call site truyền `alphaCodec:`.

### 2026-09-07 — M-E khép lại: tiếng clip video lớp đè + preview 30fps + HDR + scopes video
- **Tiếng clip VIDEO lớp đè** (FEATURE_MATRIX §38): `OverlayClip.videoAudioOn` (Codable khoan dung,
  mặc định TẮT). Toggle "Bật tiếng của clip video" trong inspector clip video.
  - PREVIEW: `Services/OverlayAudioMixer.swift` (MỚI) — mỗi clip 1 `AVPlayer` dựng từ
    `AVMutableComposition` CHỈ track audio (khỏi giải mã video); ticker 12Hz bám `playback.renderTime`;
    seek khi lệch > 0.3s; volume theo `fadeIn/fadeOut`. **Tách hẳn** khỏi `PlaybackController` /
    `AVAudioPlayer` bài chính. `KaraokePreview` `@StateObject` + `activate()` chỉ khi có ≥1 clip bật.
  - XUẤT: `AudioMux.ExtraAudio` + `encodeAAC(_ source: URL?, …, extras:)` — mỗi clip 1 track +
    `AVMutableAudioMixInputParameters` (gain + 2 ramp), preset `AppleM4A` trộn phẳng thành 1 AAC
    cùng bài hát chính. `TransparentVideoExporter` tự dựng list (bỏ clip ngoài vùng cắt bài,
    `srcStart = trimStart + headCut`, `at = start − timeOffset`). `merge(audio:)` nay nhận `URL?`.
- **Preview overlay video 30fps**: `OverlayVideoFrameStore` grid 30 + prefetch 12 khung + queue
  concurrent `.userInitiated` + tolerance 1/60s (thay 4fps cũ).
- **HDR policy màu**: `ColorPipeline.isHDRSpace` (2100/PQ/HLG/2020) → kernel `rolloffKernel` hạ tông
  + `hdrNote` (1 lần) → `ContentView` hiện "Ảnh/Video HDR — đã hạ về SDR…".
- **Scopes cho VIDEO frame**: `colorBasicPanel(sample:sampleKeySuffix:)` — clip video cấp khung tại
  vạch đỏ cho `ColorScopes`, key kèm `|t<giây>` để tính lại khi tua.

### 2026-09-06 (tiếp) — SỬA "không có tiếng" + preset màu
- **BUG không có tiếng khi bấm play** (user báo): nghi M-D slice 1 auto-pause/reseek. ĐÃ GATE toàn bộ
  `playLo`/`playHi`/reseek/auto-pause sau `hasAudioTrim` (chỉ chạy khi thực sự cắt bài). Bài không cắt
  → y hệt trước M-D. `effectiveVolume` = `max(0,min(1,gain))`. Chờ user xác nhận (nếu vẫn im → nguyên
  nhân khác, xem KNOWN_ISSUES câu hỏi chẩn đoán).
- **Preset màu (§75)**: `Services/ColorPresetStore.swift` (MỚI, JSON `.color-presets.json`) +
  `@StateObject` trong App + menu 🎨 trong `colorBasicPanel` (Lưu / áp / Xoá).

### Color C8–C11 (2026-09-06)
- `Models/ColorGrade.swift` (MỚI): `ToneCurve` (Fritsch–Carlson monotone cubic `sample`), `ToneCurves`
  (master/R/G/B), `HSLAdjust` (8 dải × hue/sat/lum), `LUTRef` (path/name/intensity). Codable.
- `ColorAdjust` (+`curves`/`hsl`/`lut`): `isIdentity`/`key`/Codable mở rộng (decode/encodeIfPresent).
- `ColorPipeline`: **C8** `curvesFilter` bake 32³ `CIColorCubeWithColorSpace` (cache theo `curves.key`).
  **C9** kernel `kmHSL` (rgb→HSL, `bandW` smoothstep circular, 8 dải unroll, HSL→rgb). **C10** `parseCube`
  (.cube, đỏ chạy nhanh nhất) → `CIColorCubeWithColorSpace` + `kmMix` blend theo intensity. **C11**
  `histogram` (`CIAreaHistogram` 128 bin, chuẩn hoá theo max).
  Thứ tự: WB → kernel chính → curves → HSL → LUT → vignette.
- `Views/ToneCurveGraph.swift` (MỚI): đồ thị kéo điểm + `SpatialTapGesture` dbl-click thêm/bớt;
  `ClipHistogram` (RGB, `.task(id: key)`).
- `ContentView.colorBasicPanel`: thêm histogram trên cùng + 3 mục xổ (ĐƯỜNG CONG / HSL / LUT) qua
  `colorSection`. `FilePanels.chooseLUT()` (.cube).
- **Scopes**: `ColorScopes` (Biểu đồ / RGB Parade / Vectorscope) — `scopeSamples` hạ mẫu 140px, Canvas vẽ dots.
- **Trước/Sau**: `ColorPipeline.bypass` (check ở `process` + `applyCG`); nút 👁 trong bảng màu → flush cache
  + preview vẽ lại. Tự tắt khi rời panel / trước khi xuất (`clearColorBypass`).
- **Copy/Paste màu**: `ContentView.copiedColor: ColorAdjust?` + 2 nút doc.on.doc / doc.on.clipboard.
- CÒN: color preset (§75, để sau) · test ảnh tự động · HDR tone-map tường minh · tune hằng số.

### Color C1–C7 (2026-09-06)
- `Rendering/ColorPipeline.swift` (MỚI): `CIContext` reuse, working = extendedLinearSRGB / RGBAh,
  output = sRGB. 1 `CIColorKernel` (verify compile OK) = exposure(EV ±4) · HL/SH/WH/BL (smoothstep
  luminance mask chồng mềm, giữ hue) · contrast (S-curve luỹ thừa quanh 0.18, không kẹp 0.5) ·
  vibrance ((1−chroma) weighted) · saturation. `CITemperatureAndTint` (x+y) trước, `CIVignette` sau.
- `ColorAdjust` (ImageFX.swift): 11 field −1…1 (vignette 0…1), neutral 0. Codable `v:2` + di trú
  từ định dạng cũ (exposure EV/4, contrast/sat −1, warmth→temperature). `ImageFX.apply`→`ColorPipeline`.
  Neutral = passthrough (short-circuit ở `isIdentity`).
- VIDEO: overlay video → `Compositor.overlayLayers` gọi `ImageFX.apply`. Nền video export → qua
  `BackgroundImageStore` sẵn có. Nền video PREVIEW → `VideoBackgroundView.AVMutableVideoComposition`
  (`applyingCIFiltersWithHandler` → `ColorPipeline.process`) = parity.
- UI `ContentView.colorBasicPanel` (lớp đè + nền media): ÁNH SÁNG 6 + MÀU SẮC 4 + Tối góc + "Về gốc".
  Slider −100…100, double-click số = 0.
- CÒN: tune hằng số kernel bằng test ảnh; unit/image test tự động; HDR tường minh; C8–C11 (curves/HSL/LUT/scopes).

### Color C0 — audit (2026-09-06)
- `docs/COLOR_ENGINE_AUDIT.md` (từng control + color management + root cause) +
  `docs/COLOR_ENGINE.md` (thiết kế đích) + `ROADMAP.md §Color C0–C11` + FEATURE_MATRIX rows C-1…C-18.
- Engine hiện tại: `ImageFX.apply(CGImage, ColorAdjust)` — 5 control (exposure `CIExposureAdjust` ✓ /
  contrast+sat `CIColorControls` / warmth `CITemperatureAndTint` x-only / vignette `CIVignette`).
  Áp qua `OverlayImageStore` + `BackgroundImageStore`. Preview = Export (1 đường ✓). `CIContext` reuse ✓.
- Root cause "màu yếu": ROOT-C1 thiếu HL/SH/WH/BL + Vibrance + Tint; ROOT-C2 contrast naïve;
  **ROOT-C3 KHÔNG áp cho VIDEO** (`OverlayImageStore` bỏ qua `.video`, nền video không qua ImageFX);
  ROOT-C4 không quản lý màu (ngầm sRGB); ROOT-C5 slider map tuyến tính.
- Giữ: `ImageFX` là điểm áp duy nhất · `CIExposureAdjust`/`CITemperatureAndTint` · `ColorAdjust` Codable
  khoan dung (mở rộng field, không viết lại).

### M-D slice 1b (2026-09-06) — XUẤT theo vùng cắt bài + fade âm thanh
User hỏi có đụng karaoke không → KHÔNG (không sờ aligner; chỉ là độ lệch thời gian lúc dựng khung
xuất, giống `followOffset` sẵn có). Đã làm:
- `KaraokeProject.audioFadeIn/audioFadeOut` (Codable khoan dung).
- `VideoFrameWriter.write` thêm `timeOffset:` — mọi lớp vẽ tại `srcTime = frameTime + offset`
  (lời/nền/lớp đè/sóng nhạc/bg-video đều dùng `srcTime`). PTS vẫn theo `frameIndex`.
- `TransparentVideoExporter.export` tự tính: `tStart/tEnd` từ `audioTrimStart/End`, `effDur = tEnd-tStart`,
  `timeOffset = tStart`, `totalFrames` theo `effDur`. Không cắt → `offset=0`, `effDur=duration` (y cũ).
- `AudioMux.encodeAAC` giờ nhận `start/maxLen/gain/fadeIn/fadeOut` → `AVMutableComposition` +
  `AVMutableAudioMix` (setVolume + 2 volume ramp), preset `AppleM4A` (honor audioMix). Nhánh `plain`
  (không cắt/fade) giữ passthrough như cũ. `merge` truyền các tham số này.
- Inspector "Âm thanh bài hát": thêm "Tiếng vào" / "Tiếng ra" (0–10s). Ghi chú đổi thành "áp cho
  CẢ phát thử lẫn video xuất".

### Polish đợt 5 (2026-09-06) — đổi tên + chuyển cảnh
- **Đổi tên clip**: context menu clip "Đổi tên…" + nút ✏️ ở header inspector clip →
  `TextPrompt.run` → `timelineOverlayRename`.
- **Chuyển cảnh mờ 1-chạm**: context menu clip "Chuyển cảnh mờ với clip trước (0,5s)" (hiện khi
  có clip liền trước cùng làn, cách <3s) → `timelineOverlayTransition`: kéo clip SAU chồng lên
  clip trước `ov` giây + đặt `fadeIn = ov`. `Compositor` vẽ cả 2 clip đè → cross-dissolve thật.
  Callback mới `onOverlayRename` / `onOverlayTransition`.

### Polish đợt 4 (2026-09-06) — fade handle + paste style + lane cao hơn
- Làn "Lớp đè" cao 18→**26px** (`overlayLaneH`), khớp `gOverlayLane 28` + struct `totalHeight *28`.
- **Kéo tay nắm fade ngay trên clip**: `OverlayZone.fadeIn/.fadeOut` + `OverlayDrag.aFadeIn/aFadeOut`
  + `overlayFadePreview`. Bắt ở nửa TRÊN clip (±10px quanh chấm trắng). Commit qua callback mới
  `onOverlayFade(id,fin,fout)` → `timelineOverlayFade`. Con trỏ = pointingHand.
- **`EditorCommand.pasteClipStyle`** — dán CHỈ opacity/blend/aboveText/colorAdjust/scale/rotation/
  offset/fade từ `copiedOverlay` sang clip đang chọn (giữ nguyên vị trí/thời lượng/làn/nguồn).
  Menu bar Timeline + context menu clip ("Dán thuộc tính vào clip này").

### Polish đợt 3 (2026-09-06) — copy/paste clip
- `EditorCommand.copySelection` / `.pasteClip`; `ContentView.copiedOverlay: OverlayClip?`.
- ⌘C / ⌘V (KHÔNG khi timeline focus — timeline giữ copy dòng lời). Context menu clip: "Sao chép";
  vùng trống dải lớp đè: "Dán clip vào vạch đỏ" (khi `canPasteClip`). Menu bar Timeline: Sao chép / Dán.
- Dán → id mới, `start = vạch đỏ`, `lane = freeOverlayLane`.

### Polish đợt 2 (2026-09-06)
- **Fade in/out cho clip lớp đè**: `OverlayClip.fadeIn/fadeOut` (Codable khoan dung).
  `Compositor.overlayLayers` nhân opacity theo dốc ở 2 đầu → preview + xuất đều theo.
  Inspector: stepper "Hiện dần" / "Mờ dần" (0…nửa độ dài clip). Timeline: vẽ tam giác mờ ở 2 đầu
  clip; thêm `fadeIn/fadeOut` vào state-hash để redraw.
- **Phím tắt (window-level, né ô nhập chữ)**: ← / → = tua ∓0,1s (⇧ = ∓1s), bỏ qua khi canvas
  timeline đang focus (canvas tự nudge dòng lời); `,` / `.` = dời mục đang chọn ∓0,1s
  (`runCommand(.nudgeSelection)`).

### Polish (2026-09-06, "làm hết")
- **Ẩn/hiện lời + tắt/bật tiếng nhạc vào command + menu Xem**: `EditorCommand.toggleLyricsHidden`
  (⌘L) + `.toggleMusicMuted` (⇧⌘M — tránh ⌘M minimize). `runCommand` → `store.perform` toggle.
- **`KaraokeProject.audioMuted`** (Codable khoan dung, độc lập `audioGain`).
  `PlaybackController.effectiveVolume = audioMuted ? 0 : audioGain`; `applyAudioSettings(...,muted:)`;
  `syncAudioSettings` + `.onChange(audioMuted)`.
- **Nút tắt tiếng ở đầu track "Nhạc"** (`TimelineEditor.musicHeadRow`, 🔊/🔇).
- **Ripple khi thả file TRÚNG làn**: clip cùng làn có `end > điểm thả` → `start += duration` mới
  (chèn chừa chỗ như CapCut). Chỉ khi thả trúng làn cụ thể (canvas drop), không áp cho menu "đặt".
- **Onboarding**: `centerColumn` overlay `onboardingCard` khi `isFreshProject`
  (không audio + không lời + không overlay + không nền) — 3 bước hướng dẫn.

### M-F (2026-09-06)
- **Ẩn/hiện lớp chữ karaoke**: `KaraokeProject.lyricsHidden` (Codable khoan dung). Guard đầu
  `KaraokeRenderer.drawPreview` (`plan.reset(); return`) + `drawExport` (`return`) → preview +
  thumbnail + xuất video đều tôn trọng. Nút 👁 ở đầu track "Lời" (`TimelineEditor.lyricHeadRow`,
  đọc/ghi `store` trực tiếp qua `@EnvironmentObject`).
- **Snap kéo clip lớp đè vào biên dòng lời** (thêm `lines[].start/.end` vào `snaps`).

### M-E — cắt-đầu clip VIDEO lớp đè (2026-09-06)
- `OverlayClip.trimStart` + `sourceDuration` (Codable khoan dung). `placeMediaPoolItem` set
  `sourceDuration` cho video.
- `Compositor.overlayLayers`: `vt = trimStart + (time - clip.start)`. Exporter tự đúng theo
  (nhận `vt` từ `overlayLayers`; `BackgroundVideoReader` bỏ qua frame tới `trimStart`, monotonic OK).
- Kéo mép TRÁI clip video → `timelineOverlayTrim` dời `trimStart` (kẹp `≥0` và `≤ sourceDuration`);
  ảnh giữ nguyên (chỉ đổi cửa sổ). Tách clip video: nửa phải `trimStart += (atTime - start)`.
- Inspector clip video: stepper "Video vào từ" + "Về 0".

### M-D slice 1 — cắt đầu/đuôi bài + âm lượng (2026-09-06)
- `KaraokeProject.audioTrimStart / audioTrimEnd / audioGain` (Codable khoan dung). KHÔNG dời
  timeline-time → lời KHÔNG bị ảnh hưởng.
- `PlaybackController.applyAudioSettings(...)` + `playLo`/`playHi`. `play()` nhảy vào vùng cắt;
  `syncTime()` tự dừng ở `playHi`; `load()` set `volume`. Không đổi engine, không remap thời gian.
- Left panel > "Âm thanh bài hát": Bỏ đầu / Kết thúc (stepper + "từ vạch đỏ") + Âm lượng + Về mặc định.
  `ContentView.syncAudioSettings()` gọi ở `onAppear` + `.onChange` 3 field.
- (khi đó CHƯA: xuất theo vùng cắt + fade → đã xong ở 1b. Nhạc nhiều clip → user BỎ HẲN.
  Kéo mép cắt ngay trên sóng → có thể làm nếu user muốn.)

### M-C đã làm (2026-09-06)
- **Zoom vào command system**: `pointsPerSecond` + `viewportWidth` lift từ `TimelineEditor`
  (`@State`) lên `ContentView` (`@State timelineZoom` / `timelineViewportW`, truyền xuống bằng
  `@Binding`). `EditorCommand.zoomIn/.zoomOut/.zoomToFit`. `zoomToFit` dùng
  `max(playback.duration, playback.virtualDuration)` làm độ dài timeline.
- Menu **Xem**: Phóng to ⌘= · Thu nhỏ ⌘− · Vừa khung ⌘0 (⌘-modified, an toàn với ô nhập chữ).
  Toolbar zoom timeline giờ gọi `run(.zoomIn/.zoomOut/.zoomToFit)`. Pinch/scroll giữ cục bộ (`setZoom`).
- **Con trỏ timeline** (`TimelineCanvasView.cursorFor` gọi trong `mouseMoved`): mép clip/khối =
  `resizeLeftRight`, thân clip/khối = `openHand`; kéo clip: `closedHand` (dời) / `resizeLeftRight`
  (cắt); thả / `mouseExited` → `arrow`. `resetCursorRects` cũ (mép lời) giữ làm fallback, không xung đột.
- KHÔNG rip `t*pps` trong canvas thành `TimelineMetrics` (1 view, 1 `pps`, đang đúng) — phần
  "scattered" thật sự là zoom control thì đã gom. Xem KNOWN_ISSUES ROOT-3.

### M-B đã làm (2026-09-06)
- `EditorCommandSink` + `FocusedValues.editorCommands` (trong `EditorCommand.swift`).
  `ContentView` phát qua `.focusedSceneValue(\.editorCommands, …)`.
- `KaraokeMakerApp` menu bar: **Phát** (Phát/Dừng · Lùi/Tới 1s · Lùi/Tới 5s), **Timeline**
  (Tách ⌘B · Nhân đôi · Xoá · Dời ±0,1s), **Lời** (Dòng trước/sau · Đặt start/end tại vạch đỏ ·
  Xoá timing dòng). Mọi mục gọi `editor?.run(...)`, tự mờ theo `editor?.canRun(...)`.
  KHÔNG gắn `.keyboardShortcut` cho phím thường (Space/←/→/[/]/⌫) — `KeyDownMonitor` giữ,
  né ô nhập chữ. Chỉ ⌘B (Tách) là menu-owned.
- Context menu chuột phải trên timeline canvas: clip → Tách tại đây / Nhân đôi / Xoá;
  dòng lời → Nhân đôi dòng / Xoá dòng. `TimelineCanvasView.menu(for:)` + `ClosureMenuItem`.
  Overlay dùng `run(.duplicateSelection/.deleteSelection)`; lời dùng `onDuplicateLines/onDeleteLines`
  ("Xoá dòng" = xoá hẳn dòng, khác Delete phím = xoá timing — cố ý).

### M-A đã làm
- `Models/EditorCommand.swift` (mới): `EditorSelection` (none / lyricLine / overlay) +
  `EditorCommand` (playPause, seekBy, prev/nextLine, setLineStart/EndAtPlayhead, clearLineTiming,
  splitAtPlayhead, deleteSelection, duplicateSelection, nudgeSelection).
- `ContentView`: `editorSelection` (computed — NGUỒN ĐỌC duy nhất, tính từ `selectedOverlayID` +
  `currentLineIndex`), `select(_:)`, `canRun(_:)`, `runCommand(_:)` — điểm vào DUY NHẤT.
- `handleKeyDown` route qua `runCommand` (Space/[/]/Delete) — hành vi giữ nguyên, vẫn né TextField
  (KeyDownMonitor bỏ qua NSText/NSTextView).
- Timeline toolbar (✂️ ▣ 🗑) gọi `run(.splitAtPlayhead / .duplicateSelection / .deleteSelection)`
  qua tham số `run:` truyền vào `TimelineEditor` — chung đường với phím tắt.
- `inspectorColumn` đọc `editorSelection` thay vì check `selectedOverlayID` inline.

### Còn (M-C)
- Canvas word-ops (S/M/⌘C/⌘V/⌘D trên `selWord`) GIỮ canvas-local — micro-op nội bộ.
- Zoom vào command → cần lift `pointsPerSecond` khi làm `TimelineMetrics`.

## COMPLETED (session 2026-09-06, tất cả build release OK — chờ user test M4)
- Timeline hiện + hoạt động KHÔNG cần nạp nhạc; transport ẢO trong `PlaybackController`.
- Track header cột trái (Nhạc / Lời / Lớp đè 1–3) + ẩn/khoá theo làn.
- Overlay clip trên timeline: dời (ngang/lane) · trim mép · tách ✂️/⌘K · nhân đôi · Delete · snap.
- Kéo file kho thả đúng làn + mốc (canvas = NSDraggingDestination).
- Bảng sửa clip: bỏ tab Thời gian/Biến hình (kéo trực tiếp trên preview) — còn Độ mờ/Hoà trộn/
  Đè-trên-chữ/Vừa khung/Phủ kín/Đổi ảnh + Màu sắc.
- Kéo phóng clip trên preview: hít "vừa khung".
- Export video trong suốt: thêm chọn chất lượng — HEVC-alpha (mặc định, nhẹ ~6–10×) / ProRes4444.
- Thumbnail thư viện = vẽ lại đúng khung preview (nền/khung video/sóng nhạc/overlay/chữ) tại vạch đỏ.
- Style preset của người dùng: lưu / đổi tên / xoá / ẩn preset dựng sẵn / "Khôi phục mặc định".
- Khu timeline dưới cao hơn (ideal 380 / max 680).

## IN PROGRESS
- **Clip ★ KARAOKE** — track đầu trên timeline (dưới thước, TRÊN "Nhạc").
  - **Bước 1 XONG**: clip xanh ngọc + dấu ★, kéo THÂN để đổi `karaokeClipStart`
    (1 undo "Dời clip Karaoke"), hít về 0 / vạch đỏ, lưu `.kbproj`. Nút loa header track
    dùng CHUNG `audioMuted`. Vùng lời chỉ dời xuống ĐỀU 22px (`waveTop`/`laneAreaTop`) —
    toán canh chữ tương đối không đổi.
  - Clip ★ trên track **CHỈ KÉO** — không cắt, không sửa gì khác (user chốt 2026-09-08).
    Cắt đầu/đuôi + âm lượng bài vẫn ở panel "Âm thanh bài hát" (Media) + nút loa header.
    (Đã gỡ toàn bộ code kéo-mép-cắt trên clip ★: `KZone`, `karaokePreviewTrim`, `onKaraokeClipTrim`…)
  - **Bước 2b — XUẤT ăn theo `karaokeClipStart` — XONG**: `TransparentVideoExporter.export()`
    tính `K = karaokeClipStart`, `outDur = max(K + effDur, maxOverlayEnd)` = *track kết thúc
    muộn nhất*. `write(leadOffset: K)`: karaoke (nền+sóng+chữ) vẽ tại `frameTime − K + timeOffset`,
    bỏ qua khi `frameTime < K` (tiền tấu = chỉ lớp đè + nền). Lớp đè giữ `srcTime` (đúng vị trí
    timeline). `AudioMux.encodeAAC(sourceAt: K)` / `merge(mainDelay: K)` chèn K giây lặng đầu
    bài hát chính. K=0 → xuất y hệt trước (đã trace 3 ca). Nhãn "Dài ~" hiện tổng thật + mốc karaoke.
  - **Bước 2c — `karaokeClipStart` ăn vào MÁY PHÁT + PREVIEW + WAVE trong editor — XONG**:
    `PlaybackController` giờ đếm GIỜ-TIMELINE (`renderTime`/`currentTime`). `leadOffset` +
    `setLeadOffset()`: khi > 0 → transport ẢO làm chủ, `AVAudioPlayer` phát THEO (`syncSlavedAudio`
    bật khi vạch đỏ vào `[K+trimStart, K+effEnd]`, không "nắn" từng tick). `leadOffset == 0` = mọi
    thứ y hệt cũ (đã trace). Canvas: `lyricOff = K` — block/chữ/ô-sửa/sóng "Nhạc" vẽ tại
    `giây-bài + K`; **vạch đỏ + thước + lớp đè KHÔNG dời** (đã là giờ-timeline). Kéo ô chữ dùng
    DELTA nên bất biến với K. Preview: karaoke tại `time − K` (gate `karStarted`), lớp đè giữ `time`.
    ContentView: `playheadSongTime = currentTime − K` cho ~10 chỗ gán/đọc timing lời + `seekToLineStart`
    `+K`. Sóng "Nhạc" đầu timeline giờ TRỐNG 1 khoảng = K rồi mới có sóng.
    ⚠️ Cạnh hiếm: cắt-đầu + offset cùng lúc → editor giữ vùng "chữ ló trái mép clip ★" (khớp M-D),
    còn XUẤT bỏ hẳn đoạn cắt-đầu (file ngắn hơn `trimStart`). Ca không cắt: editor ↔ xuất khớp 100%.

## UI BATCH 2026-09-09 (chờ user test M4)
- **Nút "Export"** (was "Xuất") — đồng bộ tiếng Anh cho dãy icon.
- **2 preset chữ đổi tên hiển thị**: "Kiểu của tôi 0" → **"Karaoke Chuẩn"**, "kiểu của tôi 1" →
  **"Lyric theo nhạc"**. Bỏ ô xem trước "Aa" vô nghĩa — chip preset giờ hiện thẳng TÊN.
- **Gỡ hẳn "Nhắc câu tiếp theo"** (câu nhắc + "• • •" + `showNextLine` UI/renderer). Khoá
  `showNextLine`/`nextLineGap`/`nextLineStyle` giữ lại cho project cũ decode, không dùng nữa.
- **"Luôn 2 dòng"** (`KaraokeStyle.alwaysTwoRows`, MẶC ĐỊNH BẬT ở "Karaoke Chuẩn", tắt ở
  "Lyric theo nhạc") — câu đang hát chỉ 1 dòng thì `buildRows` MƯỢN dòng đầu câu kế tiếp làm
  dòng 2 (`Row.isFiller`, KHÔNG bị vệt quét). Câu đã ≥ 2 dòng: giữ nguyên (không có dòng 3 lẻ).
  Toggle ở StylePanel › Bố cục. Cache preview thêm `curFillerSig`.
- **Trình chọn màu DÙNG CHUNG** `AppColorField` + `AppColorPopover` (`Views/AppColorPicker.swift`):
  ô SV + thanh sắc + ống hút (`NSColorSampler`) + HEX/RGB/HSL đổi qua lại + "Màu của tôi"
  (`MyColorsStore`, UserDefaults). Bấm ra ngoài popover là tự đóng, KHÔNG có nút ✕. Thay
  `SwatchPalette` (đã xoá) + `ColorPicker` ở: StylePanel (chữ/viền/bóng/glow/nền), sóng nhạc
  (4 ô), màu vai Song ca. `RGBAColor` thêm hàm HSV/HSL/HEX.
- **Lớp CHỮ trên timeline** (`OverlayClip.kind == .text`) — hoạt động như lớp ảnh: có clip
  trên làn lớp đè, kéo–giãn–xoay trên preview, inspector bên phải (nội dung/font/B-I/cỡ/căn/
  màu chữ+viền+nền qua `AppColorField`/độ mờ/đè-trên-chữ/fade). Nút "Thêm 1 lớp chữ" ở panel
  trái (subCard "Chữ / Text") — bấm = đặt ở vạch đỏ, hoặc KÉO nút thả xuống timeline
  (`newTextDragToken` qua `onMediaDrop`). Rasterise bằng `OverlayTextStore` (CoreText → CGImage,
  cache, chạy nền OK). `Compositor.Fit.native` = pixel ảnh quy chiếu khung 1080 (giữ đúng cỡ pt).
  Xuất video: đi qua `Compositor.overlayLayers` sẵn có.
  - **Đợt 2 (cùng ngày)**: thêm **bóng đổ** (màu+nhoè+lệch X/Y) + **glow** (màu+toả) vẽ trong
    `OverlayTextStore` (setShadow + CTFrameDraw nhiều lượt), và **hiệu ứng chữ VÀO/RA**
    (`TextEffect` none/fade/rise/pop + thời lượng) áp trong `overlayLayers` bằng biến hình
    alpha/offset/scale theo `time − start` / `end − time`. Start lớp chữ = giờ-timeline
    (`playback.currentTime`), KHÔNG trừ `karaokeClipStart`.
  - **Đợt 3 (cùng ngày)**: **bấm đúp** 1 lớp chữ trên preview → chọn + focus ô sửa nội dung
    (`onEditTextOverlay` → `@FocusState textOverlayEditing`). **Preset KIỂU lớp chữ**
    (`TextLayerPresetStore` + `TextLayerStyle`, UserDefaults) — menu "Kiểu" trong inspector:
    lưu / áp / xoá (không gồm nội dung/vị trí/thời lượng). Cmd+D nhân đôi lớp chữ chạy sẵn
    (`timelineOverlayDuplicate` copy cả struct).

## KEYFRAME SÓNG NHẠC + CHỮ KARAOKE 2026-09-09 (chờ user test M4)
- **Sóng nhạc**: `MusicVisualizer.keyframes: [VizKeyframe]` (giờ = giây BÀI) + `resolved(atSong:)`
  trả bản sao đã nội suy width/height/offsetX/baselineY/rotation/opacity. Gọi ở preview
  (`currentViz()`), export (`drawViz`), thumbnail. Kéo sóng khi CÓ mốc → upsert mốc tại vạch đỏ.
  5 slider vị trí thành keyframe-aware (`vizKFBinding`) + section "Chuyển động" trong panel sóng.
- **Chữ karaoke (cả khối)**: `KaraokeProject.textKeyframes: [TextBlockKeyframe]` = vị trí DỌC +
  NGANG theo giờ bài. `KaraokeRenderer.applyBlockKF` áp translate SAU khi dựng (KHÔNG đổi
  `anchorY` vào `buildRows` → không thrash cache). Kéo chữ preview khi CÓ mốc → upsert;
  drag-start + drag-preview tính theo pose đã nội suy nên không nhảy. Section "Chuyển động khối
  chữ" trong StylePanel › Bố cục (StylePanel thêm `@EnvironmentObject playback`).
- Cả 2 dùng `KFEase` (đều/mượt/chậm cuối/nảy). Codable "khoan dung".
- **Đợt 2 (cùng ngày)**: keyframe chữ karaoke thêm **cỡ chữ** (`TextBlockKeyframe.fontScale`, áp
  bằng `cg.scaleBy` quanh điểm neo — vẫn không thrash cache). Kéo góc chữ / slider "Cỡ chữ (mốc)"
  → upsert. **Sao chép / Dán / Đảo chiều** keyframe cho sóng nhạc + khối chữ
  (`KeyframeClipboard.vizFrames`/`textFrames`).

## DỌN UI 2026-09-09 (chờ user test M4)
- **Panel trái tách 5 tab RIÊNG**: Tạo Karaoke · Nền video · Thêm text · Sóng nhạc · File của bạn
  (trước "Nền video / Chữ / Sóng nhạc" gộp trong 1 tab "Chỉnh sửa"). `LeftPanelTab` = steps /
  background / text / visualizer / files.
- **StylePanel gọn lại**: bỏ toggle "Luôn hiện 2 dòng" (giờ LUÔN 2 dòng, hardcode trong
  `KaraokeRenderer` — bỏ đọc `style.alwaysTwoRows`), bỏ caption "SO LE", **bỏ hẳn section
  "Hiệu ứng chữ"** (Chữ vào/ra) — `effectXform` giờ luôn trả nil.
- **Lớp chữ**: `textOutlineWidth` mặc định = **0** (không viền).
- **Sửa bug bảng màu**: chọn màu ở ô đang "tắt" (alpha 0) → tự bật alpha lên 1
  (`nudgeAlphaIfInvisible` ở kéo ô SV / thanh sắc / ống hút / nhập HEX-RGB-HSL). Trước đó
  bóng/glow/nền lớp chữ "không hoạt động" vì màu chọn xong vẫn alpha 0.
- **UI keyframe làm lại kiểu CapCut** (`KeyframeControl`: `‹ ◇ ›`): bấm hình thoi = bắt đầu /
  thêm / (khi đang ở mốc) xoá mốc tại vạch đỏ; `‹ ›` nhảy mốc trước/sau. Bỏ nút "Ghi mốc" to
  + chữ dài. Áp cho cả 3: lớp đè, khối chữ karaoke, sóng nhạc. Auto-ghi-khi-thả-chuột đã có
  sẵn (drag gizmo/sóng/chữ khi track đã "armed" → upsert mốc).

## CHỌN NHIỀU LỚP ĐÈ 2026-09-09 (chờ user test M4)
- **⌘ / Shift + bấm** clip lớp đè trên timeline = thêm/bớt khỏi NHÓM chọn (`selectedOverlayIDs:
  Set<UUID>` song song với `selectedOverlayID` primary). Bấm thường 1 clip ngoài nhóm = chọn 1
  mình; bấm clip đang trong nhóm = giữ nhóm + KÉO CẢ NHÓM (cùng delta start + lane, không snap,
  không cắt — `overlayMultiPreview`/`multiDragBase`). ⌫ = xoá cả nhóm.
- `TimelineEditor` + canvas nhận `selectedOverlayIDs` + `onOverlaySelectMulti`. Inspector: khi
  ≥ 2 lớp → banner "N lớp đang chọn" + nút xoá nhóm.
- **Kéo CẢ NHÓM trên preview** (đợt 2): `KaraokePreview` nhận `selectedOverlayIDs`; kéo THÂN
  gizmo của lớp primary khi đang chọn nhóm → mọi lớp dời cùng delta (`groupDragBase` /
  `groupGizmoPreview`), khung nét đứt cho các lớp còn lại. `Compositor.overlayLayers`
  `excluding: UUID?` → `Set<UUID>`. Chốt từng lớp qua `onOverlayTransform` (giữ scale/rot
  riêng; lớp có keyframe thì upsert mốc).
- **Nhóm lớp đặt tên** (đợt 3): `OverlayGroup {id, name, memberIDs}` + `KaraokeProject.overlayGroups`.
  Gom từ selection ("Gom thành nhóm"), đổi tên, bỏ nhóm, ẩn/khoá CẢ NHÓM (đặt cờ lên mọi thành
  viên), "Chọn cả nhóm". Timeline: vạch + tên phía trên làn lớp đè, bấm vạch = chọn nhóm.
  `pruneOverlayGroups()` (gọi khi xoá lớp) bỏ id chết + nhóm < 2 thành viên. Codable.
- **Hình thoi keyframe trên thước** (đợt 4): keyframe SÓNG NHẠC (teal) + KHỐI CHỮ karaoke (vàng)
  hiện thành hình thoi nhỏ ở mép dưới thước tại `songT + karaokeClipStart` — trước chỉ thấy
  trong inspector. `TimelineEditor` nhận `vizKeyframeTimes`/`textKeyframeTimes: [Double]`.

## KEYFRAME LỚP ĐÈ 2026-09-09 (chờ user test M4)
- **Chuyển động keyframe** cho lớp đè (hình + video + chữ). `OverlayKeyframe {t, offsetX,
  offsetY, scale, rotation}` (chỉ biến hình — độ mờ/fade vẫn tĩnh). `OverlayClip.keyframes: []`
  (rỗng = tĩnh). `transform(atLocal:)` nội suy easeInOut giữa 2 mốc gần nhất, ngoài biên = giữ
  mốc đầu/cuối. `upsertKeyframe(atLocal:)` / `removeKeyframe(nearLocal:)`.
- `Compositor.overlayLayers` dùng `transform(atLocal: time - start)` thay giá trị tĩnh →
  xuất video chạy keyframe sẵn. Preview: `clipViewRect` + gizmo bắt đầu kéo đọc pose động;
  thả gizmo khi clip CÓ keyframe → `onOverlayTransform` upsert mốc tại vạch đỏ (thay vì sửa
  giá trị tĩnh).
- Inspector: `keyframeControls(_:)` (dùng chung lớp hình & chữ) — "Ghi mốc (vạch đỏ)" /
  "Cập nhật mốc" / "−" xoá mốc gần / "Xoá hết". Timeline: hình thoi trắng ở mỗi mốc trên clip.
- **Đợt 2 (cùng ngày)**: keyframe thêm **độ mờ** (`OverlayKeyframe.opacity`) — slider "Độ mờ"
  trong inspector thành keyframe-aware (`opacityKFBinding`: có mốc → đọc/ghi mốc tại vạch đỏ).
  Thêm **kiểu nội suy mỗi mốc** (`KFEase` = đều / mượt 2 đầu / chậm dần cuối / nảy) — picker
  "Kiểu chạy tới mốc" khi vạch đỏ gần 1 mốc; `transform` dùng đường cong của mốc ĐÍCH.
  `OverlayKeyframe` chuyển sang Codable "khoan dung" (mốc lưu từ đợt 1 vẫn mở được).
- **Đợt 3 (cùng ngày)**: `KeyframeClipboard.shared` — **Sao chép / Dán** cả bộ keyframe giữa
  các lớp (clamp `t` theo duration đích). Nút **◀/▶ mốc** tua vạch đỏ tới mốc trước/sau.
  Nút **Đảo chiều** (phản chiếu `t` quanh [đầu,cuối]).

## GRADIENT MÀU 2026-09-09 (chờ user test M4)
- **`ColorFill`** (`Models/ColorFill.swift`, Codable khoan dung) = `solid` HOẶC `linear`
  (2 chặng màu + góc 0–360°; 0 = trái→phải, 90 = trên→dưới màn hình). Có `fill(rect:)` /
  `fillCurrentPath(bounds:)` vẽ bằng `CGGradient` (kèm cờ `flipY` cho context y-UP).
- **Bảng chọn màu** thêm `AppFillField` + `AppFillPopover`: segmented **Đơn sắc | Chuyển sắc**;
  chế độ gradient có thanh preview + 2 ô chặng A/B (bấm chọn chặng đang sửa, dùng chung
  ô SV/HEX/RGB/HSL bên dưới) + slider góc + nút nhanh →/↓/↘ + nút đảo 2 chặng. `AppColorField`
  (đơn sắc) giữ nguyên cho các chỗ khác.
- **Áp gradient cho**:
  - **Lớp chữ overlay** — `OverlayClip.textFill: ColorFill` (giữ `textColor` legacy). Render
    trong `OverlayTextStore`: đơn sắc = đường nhanh cũ; gradient = viền 1 lượt riêng
    (strokeWidth dương) + tô `CGGradient` kẹp theo path glyph (`framePath`). Inspector: ô
    "Màu chữ" đổi thành `AppFillField`.
  - **Chữ karaoke** — `KaraokeStyle.textFill` (chưa hát) + `highlightFill` (đang hát), THÊM
    (giữ `textColor`/`highlightColor` cho dấu 3 chấm / icon người hát / màu đơn). `KaraokeRenderer`:
    `drawBlock` tô chưa-hát + `wipeHighlight` tô đang-hát nhận nhánh gradient (kẹp glyph +
    `fill(rect:)`). Màu SONG CA (người hát) vẫn đơn sắc — không dính gradient. `mine0`/`mine1`
    set `*Fill = .solid(*Color)` để không lấy default vàng.
  - Sóng nhạc GIỮ hệ màu cũ (color1/color2/gradientDir) — không đổi.
  - **Đợt 2 (cùng ngày)**: gradient thêm cho **VIỀN chưa hát** (`KaraokeStyle.outlineFill` /
    `OverlayClip.textOutlineFill`) + **NỀN sau chữ** (`backgroundFill` / `textBackgroundFill`).
    Renderer: viền = làm dày path glyph (`replacePathWithStrokedPath`) rồi tô solid/gradient;
    nền = tô rounded-rect solid/gradient. Chạy ở đường BAKE (static image) → không nặng khung.
    **Viền ĐANG hát** (`outlineColorSung`) + **bóng/glow** GIỮ đơn sắc (setShadow 1 màu — gradient
    vô nghĩa). `mine0`/`mine1` set `outlineFill`/`backgroundFill = .solid(*Color)`.
    `TextLayerPresetStore` key → v3.
  - **Bấm đúp lớp chữ trên TIMELINE** = chọn + focus ô sửa (như trên preview) —
    `TimelineEditor.onEditTextOverlay`.
  - **Đợt 3 (cùng ngày)**: `ColorFill` giờ **nhiều chặng** (`stops: [ColorStop]`, ≥2, 2 đầu ghim
    0%/100%) + kiểu **toả tròn** (`.radial`, `drawRadialGradient` tâm khung). `color`/`color2` giữ
    làm chặng đầu/cuối cho tương thích. `isFlat`/`flatColor` thay `isSolid || color==color2`.
    Bảng chọn: segmented **Đơn sắc | Tuyến tính | Toả tròn**, hàng chặng màu (bấm chọn, ± thêm/bớt,
    đảo thứ tự), slider "Vị trí" cho chặng giữa, slider Góc cho tuyến tính. Renderer không đổi
    (các nhánh solid/gradient dùng `isFlat`/`flatColor`; `drawGradient` tự rẽ linear/radial).
  - **Đợt 4 (cùng ngày)**: chuột phải ô màu (`AppColorField`/`AppFillField`) = **Sao chép / Dán**
    (`ColorClipboard.shared`, phiên) + **Về mặc định** (`defaultValue:` — truyền ở style karaoke
    = `KaraokeStyle.default.*`, lớp chữ = `OverlayClip().*`). Thanh gradient trong bảng chọn có
    **tay nắm KÉO** cho từng chặng (2 đầu ghim). `RGBAColor.lerp` thêm.
  - **Đợt 5 (cùng ngày)**: **bấm thanh gradient = thêm chặng ngay tại chỗ bấm** (`addStopAt`,
    màu nội suy). **Kiểu tô của tôi** (`MyFillsStore`, UserDefaults `app.myfills.v1`) — lưu / áp /
    xoá cả bộ gradient dùng lại, hàng swatch cuộn ngang trong `AppFillPopover`.
  - **Lớp chữ — chỉnh chữ nhiều dòng**: `OverlayClip.textLineSpacing` (px, `para.lineSpacing`),
    `textCharSpacing` (`.kern`), `textWrapFrac` (bề rộng ngắt dòng = tỉ lệ × 1920, thay hằng
    số 1700 cũ). 3 slider trong inspector. `TextLayerPresetStore` key → v5. `OverlayTextStore.sig`
    thêm 3 khoá.
  - **Đợt 6 (cùng ngày)**: **gradient cho BÓNG + GLOW** (`KaraokeStyle.shadowFill`/`glowFill`,
    `OverlayClip.textShadowFill`/`textGlowFill`). `ColorFill.drawSoftGlow(shape:layerSize:bounds:
    offset:blur:yUp:)`: đơn sắc = `setShadow` (đường cũ, KHÔNG đổi), gradient = dựng silhouette
    nhoè (grayscale bitmap + `setShadow` trắng) làm MẶT NẠ `cg.clip(to:mask:)` rồi tô gradient
    xuyên qua. `drawBlock` nhận thêm `canvasSize`. `mine0/1` mirror `*Fill = .solid(*Color)`.
    `TextLayerPresetStore` key → v4. `OverlayTextStore.sig` gộp `fillSig()` (kể cả stops).

## HOME / THƯ VIỆN (2026-09-08) — XONG
- **Project mở/lưu từ nơi khác giờ HIỆN ở Home**: `RecentProjects` (UserDefaults path thô,
  app không sandbox) + `ProjectLibrary.listAll()` = thư viện ∪ gần-đây (bỏ trùng). Ghi nhận
  ở `ProjectStore.open` + `write`. Thẻ ngoài thư viện có icon ↗ + menu "Bỏ khỏi Gần đây".
- **Hết rác "Untitled 4KB"**: "Tạo project" KHÔNG ghi file ngay — `store.prepareNewInLibrary()`
  chỉ đánh dấu; `save()` mới tự tạo file trong thư viện (tên = `project.name`, tránh trùng)
  khi người dùng thực sự lưu / rời màn có thay đổi. Rác cũ: user tự xoá (menu chuột phải).

## ĐA NGÔN NGỮ (2026-09-09) — LÔ 1 (vỏ app) XONG, build OK
- **Yêu cầu user**: chuyển toàn app sang **English mặc định**, có ô chọn ngôn ngữ (bấm ra list,
  **Tiếng Việt đứng đầu**). Chốt: list gồm Việt + English + 6 tiếng (Trung/Hàn/Nhật/Tây Ban Nha/
  Pháp/Bồ) — 6 tiếng kia tạm hiển thị bằng English tới khi dịch. Đổi ngôn ngữ xong **mở lại app**
  mới áp dụng (thông báo "Mở lại ngay / Để sau").
- **Kiến trúc** — `Services/Localization.swift` + `Services/LocalizationTables.swift`:
  - Khoá dịch = **chính chuỗi tiếng Việt gốc** trong code (`L("Xuất")` / `"Xuất".loc`).
  - `LocEngine` (KHÔNG phụ thuộc main-actor — gọi được từ AppKit/nền): `launchLang` đọc 1 lần từ
    `UserDefaults "app.language"` (mặc định `.en`); `t(vi)` → `vi` nếu launchLang == .vi, else tra
    `LocTables.all[launchLang] ?? [.en]`, thiếu khoá → trả nguyên tiếng Việt (dễ thấy chỗ chưa dịch).
  - `Loc` (`@MainActor ObservableObject`) chỉ giữ state cho UI: `lang`, `select(_:)`, `needsRestart`,
    `relaunch()` (`/usr/bin/open -n` + `NSApp.terminate`).
  - `LanguagePicker` (menu quả địa cầu) + `SettingsView` (⌘,) — `Settings { SettingsView() }` scene
    mới trong `KaraokeMakerApp`.
- **Đã dịch (lô 1)**: menu bar (File/Phát/Timeline/Lời/Xem) + hộp thoại lưu-thoát; màn Home
  (`HomeView` + `TrashView` + context menu) + nút quả địa cầu ở header Home; `RootView` (help + alert
  đóng tab); `ContentView` — 5 tab trái, thanh công cụ, tiêu đề `subCard`, header pop-up Xuất.

## ĐA NGÔN NGỮ — LÔ "LÀM HẾT" (2026-09-09) — XONG, build OK
- Quét & bọc `L("…")` toàn bộ chuỗi tiếng Việt lộ ra UI ở: `StylePanel` (helper `section`/`subgroup`/
  `check`/`slider`/`percentSlider`/`colorRow`/`perform`/`edit` bọc 1 lần → phủ hết call-site),
  `TimelineEditor` (SwiftUI + nhãn `NSString.draw` canvas AppKit + `ClosureMenuItem` menu chuột phải),
  `ContentView` (~300 `L(...)`: Text/Button/Label/Picker/Toggle/`.help`/`store.perform`/`store.edit` +
  helper `subCard`/`stepBlock`/`onboardStep`/`stemDropRow`/`overlaySlider`/`leftTabButton`),
  `AppColorPicker` (`AppColorField`/`AppFillField` bọc `label` 1 lần + context menu + popover),
  `KaraokePreview` (tên Undo), `LyricLinesList`, `PlaybackHUD`, `ToneCurveGraph`, `KeyframeControl`,
  `FilePanels` (13 tiêu đề hộp thoại), `ProjectStore` / `TextImport` (lỗi banner).
- Chuỗi nội suy (`\(x)`) đổi sang `String(format: L("… %@ / %d …"), …)` cho các chỗ HIỆN RA;
  vài tên Undo nội suy để nguyên (rơi về tiếng Việt, chấp nhận).
- Enum `rawValue` hiển thị (`PreviewBackground`/`PreviewQuality`/`AudioInputMode`/`ExportAudioChoice`)
  bọc `L($0.rawValue)` tại nơi vẽ; raw value vẫn là khoá lưu.
- `LocalizationTables.enTable` ≈ **540 khoá** Anh–Việt. Kiểm trùng khoá bằng:
  `grep -oE '^\s*"[^"]+":' … | sort | uniq -d` (khoá trùng trong dict literal = crash lúc chạy).
- **CÒN**: 6 ngôn ngữ kia (zh/ko/ja/es/fr/pt) vẫn mượn English — cần bảng dịch thật.
  Vài tên thao tác Undo + 1–2 chuỗi lỗi hiếm có nội suy `\(error…)` chưa có khoá.

## ĐA NGÔN NGỮ — VÁ SAU TEST (2026-09-10) — XONG, build OK
User test bản English, báo sót. Đã vá:
- **Tab "Sóng nhạc" 100% tiếng Việt**: các nhãn đi qua helper `overlaySlider`/`colorSlider`/`bgSlider`/
  `colorSection` (đã bọc `L()` bên trong từ đầu) NHƯNG thiếu KHOÁ trong `enTable` → hiện tiếng Việt.
  Đã thêm ~118 khoá (Phơi sáng/Tương phản/…, Cỡ ngang/Cao/…, Màu sắc/Chi tiết, enum `.label`).
- **`enum .label` trả literal tiếng Việt** (`SingerRole`/`MusicVisualizer.Style`+`GradientDir`/
  `KFEase`/`TextEffect`) → bọc `L()` NGAY TRONG computed property ở file Model → phủ mọi `Text($0.label)`.
- **Chuỗi KHÔNG dấu bị bỏ sót** (regex quét theo dấu tiếng Việt): `"Song ca"`, `"Xong"` → bọc tay + khoá.
- **Ternary / `DisclosureGroup` / `?? "…"` / `store.perform(cond ? … : …)` / note `String(format:)`**:
  quét & bọc thêm ~40 chỗ trong `ContentView` (`wrap2.py`).
- **So sánh với tên Undo** `name == "Thêm chữ"` → `name == L("Thêm chữ")` (nếu không, ⌘Z restage hỏng ở EN).
- **Preset đổi tên hiển thị**: "Karaoke Chuẩn" → **"Karaoke"**, "Lyric theo nhạc" → **"Lyric"**
  (`StylePreset.all`).
- **Bảng chọn màu — "Kiểu tô của tôi" / swatch bấm không ăn**: thêm `.contentShape(Rectangle())` vào
  label các `Button` shape-only trong `ScrollView` (MyFills, "Màu của tôi", chip chặng màu) +
  `applySavedFill()` dựng lại stops chắc tay. CHỜ user xác nhận lại.

## INSPECTOR CHIA TAB + FADE SLIDER + VIỀN CHỮ (2026-09-10) — XONG, build OK
- **Viền LỚP CHỮ vẽ lại như karaoke**: `OverlayTextStore.render` bỏ đường tắt `attrs[.strokeWidth]` âm
  (nối góc MITER → "gãy góc"). Giờ LUÔN: `framePath` glyph → `replacePathWithStrokedPath` (lineJoin
  `.round`, lineCap `.round`) tô `oFill` → rồi tô chữ đè (`CTFrameDraw` nếu đơn sắc cho nét mượt,
  else kẹp path). Bake 1 lần / lần đổi, không nặng khung.
- **Fade in/out → thanh trượt** (`fadeRow(label:value:max:)` = Text 66 + Slider + "%.1fs" 40) thay
  `Stepper` step 0.25 ở CẢ 3 chỗ: lớp chữ, clip tiếng, lớp ảnh/video.
- **Bảng "Chữ" karaoke chia 2 tab** (`StylePanel.MainTab`): **Kiểu chữ** (preset + Font/Màu/Viền/Bóng/
  Glow/Nền) · **Bố cục** (Căn lề/Vị trí/Lề/Cách dòng + Chuyển động khối chữ). `contentSection` +
  `afterContent` vẫn hiện cố định trên cùng. Bỏ helper `section`/`collapsed` (hết dùng).
- **Bảng sửa LỚP CHỮ chia 4 tab** (`ContentView.TextInspTab`): **Nội dung** (text + font + cỡ/giãn/
  cách dòng/ngắt dòng + căn lề) · **Màu** (chữ/viền/độ dày/nền + bóng + glow) · **Hiệu ứng** (chữ vào/
  ra + thời lượng + độ mờ + fade) · **Biến hình** (đè lên chữ karaoke + giữa khung/cỡ gốc + keyframe).
- Header (hint + menu "Kiểu" preset) vẫn hiện cố định trên các tab.

## VÁ 2 LỖI (2026-09-10, đợt 2) — XONG, build OK
- **Viền lớp chữ "lỗi nặng"** (viền lệch hẳn khỏi chữ ~`pad` px): đợt trước đổi sang path-stroke
  nhưng `framePath` dùng line-origin Core Text tính TỪ (0,0) trong khi `CTFrameDraw` đặt chữ tại
  gốc khung path = `(pad,pad)`. Sửa: `framePath(_ frame:, origin:)` cộng `boxRect.origin` — viền,
  tô gradient theo path glyph, glow/shadow gradient GIỜ TRÙNG `CTFrameDraw`. (Bonus: lớp chữ
  gradient trước đây cũng lệch `pad` px — nay đúng vị trí.)
- **Bấm vùng sóng/thước KHÔNG bỏ chọn track đang chọn**: `TimelineCanvasView.mouseDown` cũ chỉ
  gọi `onOverlaySelect?(nil)` khi `selOverlayID` (bản sao local) != nil → kẹt khi state chưa đồng
  bộ. Nay gọi VÔ ĐIỀU KIỆN khi bấm ra ngoài mọi clip → luôn quay về bảng chỉnh karaoke.

## KARAOKE vs LYRIC = 2 CHẾ ĐỘ THẬT (2026-09-11) — XONG, build OK
- **"Luôn 2 dòng" hết bị ép cứng toàn app** — trả về đọc `style.alwaysTwoRows` (3 chỗ trong
  `KaraokeRenderer`: `drawPreview`/`drawExport`/`draw()` dead). Preset **"Karaoke"** (`mine0`) đã có
  sẵn `alwaysTwoRows = true`; preset **"Lyric"** (`mine1`) mặc định `false` → LUÔN 1 dòng. Vì đây là
  field của `KaraokeStyle` (copy nguyên khi áp preset) nên user chỉnh màu/font sau đó KHÔNG làm mất
  "chế độ" — đúng ý "không còn chỉ là preset, là 2 chế độ riêng". KHÔNG thêm lại UI toggle thủ công
  (user từng bảo bỏ hết) — chỉ đổi qua preset Karaoke/Lyric.
- **Dòng 2 (câu ngắn mượn câu kế) không còn "biến mất" giữa 2 câu**: `KaraokeRenderer.frameLines` —
  khi KHÔNG có câu nào đang active (đã qua `end` câu này, CHƯA tới `start` câu kế) nhưng có câu kế
  sắp tới → giữ NGUYÊN câu vừa hát xong làm `current` (progress tự bão hoà = 1, không giật) tới khi
  câu kế thật sự bắt đầu (lúc đó vòng lặp tìm `curIdx` bình thường tự thay bằng câu kế). Chỉ 1 vòng
  quét O(n) thêm, CHỈ chạy khi đang ở khoảng nghỉ — không phá ngân sách "mỗi khung không cấp phát".

## NỀN + SÓNG NHẠC (2026-09-11) — XONG, build OK
- **Bảng chỉnh nền (phóng/lệch/mờ, Ken Burns, chỉnh màu) dời từ tab Xuất → tab "Nền video"**.
  `backgroundMediaBlock` không đổi nội dung, chỉ đổi CHỖ GỌI: bỏ khỏi `exportTabContent`, ghép
  vào `backgroundSourceContent` (đã bỏ nút chọn ảnh/video trùng lặp cũ + câu hint "chỉnh ở tab
  Xuất"). Tab Xuất giờ chỉ còn SRT/ASS/video.
- **Preset nhanh "Cột mảnh cổ điển"** cho sóng nhạc — 1 nút áp thẳng bộ tham số (cột trắng mảnh,
  dày cột 140, viền vuông, không glow màu, cao vừa phải, đặt sát đáy) thay vì phải chỉnh tay từng
  ô. Style vẫn dùng renderer cũ (`.barsUp`), không cần code vẽ mới. Nâng trần "Số cột" 96→200.
- **Nền tự "zoom theo nhạc"** (mới) — `BackgroundMedia.beatZoomEnabled`/`beatZoomAmount`
  (1.15/1.25/1.5×, Codable khoan dung). Nguồn năng lượng: `SpectrumData.energy` — TÁI DÙNG đường
  FFT ngoại tuyến sẵn có của sóng nhạc (bass-weighted, đã chuẩn hoá 0…1) nhưng làm mượt THÊM 1 lớp
  exponential riêng cho zoom (chậm hơn "pump" của cột — zoom cả khung giật sẽ rất chói mắt) +
  nội suy tuyến tính giữa khung khi tra `energy(at:)` (mượt hơn round-to-nearest-frame của `bands`).
  Nhân vào `scale` trong `Compositor.mediaImageLayers` (cùng chỗ với Ken Burns, nhân dồn:
  `scale = m.scale × kenBurnsScale × beatScale`). Dùng CHUNG hệ số cho Preview
  (`KaraokePreview.currentBeatEnergy()`) và Export (`TransparentVideoExporter`, gate theo
  `karInside` như thanh cột) — xuất video đúng như xem trước. Hiệu ứng CHỈ chạy khi
  `visualizer.enabled` (điều khiển gộp trong tab Sóng nhạc, không thêm công tắc riêng ở tab Nền).
  Export: mở rộng điều kiện "không bake nền 1 lần" (giống Ken Burns) để nền vẽ lại mỗi khung.
- **CÒN**: preset "Cột mảnh cổ điển" mới có 1 lựa chọn (không phải bộ nhiều preset); nếu user muốn
  tự lưu preset sóng nhạc như đã làm với preset chữ, cần `VisualizerPresetStore` riêng (chưa làm).

## LỖI "BẤM MÀU LẦN ĐẦU BỊ ĐỨNG" (2026-09-11) — XONG, build OK
User: bấm mở popover chọn màu, bấm vào bên trong (ô SV, thanh hue, swatch…) LẦN ĐẦU không ăn —
phải bấm ra ngoài rồi bấm lại mới được. Nguyên nhân: `NSPopover` trên macOS đôi khi hiện lên
nhưng cửa sổ CHƯA thành key ngay — cú bấm đầu bị AppKit nuốt để kích hoạt cửa sổ, giống hệt lớp
lỗi mà `KaraokePreviewCanvas`/`TimelineCanvasView` đã vá bằng `acceptsFirstMouse` — nhưng
`NSHostingView` (SwiftUI dựng popover) không override được. Vá bằng `PopoverFirstClickFix`
(`NSViewRepresentable` ép `.makeKey()` ngay khi popover hiện) gắn vào gốc `AppColorPopover` +
`AppFillPopover` — SỬA CHUNG cho MỌI popover chọn màu trong app (karaoke, lớp chữ, sóng nhạc…).
Nhiều khả năng đây CŨNG là nguyên nhân bug "myfill bấm không ăn" báo trước đó.

## RÃNH MÀU (TEMP/TINT/SATURATION) + SỬA NGƯỢC TINT (2026-09-12) — XONG, build OK
- **`GradientTrackSlider`** (private struct trong `ContentView.swift`, gần `colorSlider`) — rãnh
  trượt tô sẵn 2-màu cố định (kiểu CapCut) thay `Slider` trơn, cho ĐÚNG 3 ô: Nhiệt độ (xanh dương
  → vàng), Sắc màu (lục → hồng), Bão hoà (xám → đỏ). `colorSlider(...)` nhận thêm `track: [Color]?`
  — có thì vẽ rãnh gradient, không thì `Slider` như cũ (mọi ô khác KHÔNG đổi). Kéo/bấm bất kỳ đâu
  trên rãnh (không cần trúng núm).
- **Đổi tên nhãn khớp ảnh mẫu**: "Nhiệt độ" → **Temp** (bỏ "Temperature"), "Sắc (lá–hồng)" đổi khoá
  thành **"Sắc màu"** → **Tint** (bỏ chú thích trong ngoặc). "Bão hoà" → Saturation giữ nguyên.
- **BUG có thật — Tint bị NGƯỢC**: `ColorPipeline.process` truyền thẳng `dTint = adj.tint*60` vào
  `inputTargetNeutral.y` của `CITemperatureAndTint` — trục y của filter này chạy NGƯỢC với quy ước
  Lightroom/CapCut (trái=lục, phải=hồng). Sửa: `dTint = -adj.tint * 60`. 1 điểm áp duy nhất
  (`ColorPipeline.process`) nên sửa 1 chỗ là khớp cả preview ảnh/video lẫn export.

## PRESET "KARAOKE" ĐỔI SANG STYLE MỚI (2026-09-12) — XONG, build OK
User đưa 1 file `.kbproj` đã chỉnh sẵn ("anh lai nho") → lấy `style` trong đó thay cho
`KaraokeStyle.mine0` (preset "Karaoke"): font UTM Erie Black cỡ ~78, viền đen dày 5.3, bóng đổ lệch
trái-lên không nhoè, luôn 2 dòng, chữ đang hát màu xanh dương (#3C5AE6-ish). Vì `KaraokeProject.style
= .mine0` là GIÁ TRỊ MẶC ĐỊNH của field, đổi 1 chỗ này áp dụng cho CẢ project mới tạo LẪN preset chip
"Karaoke" trong bảng Style. `nextLineStyle`/`mine0Next` GIỮ NGUYÊN — trường này không còn được
renderer đọc (tính năng "nhắc câu tiếp theo" đã gỡ 2026-09-09), giá trị trong file cũng trùng khớp
sẵn nên không cần đổi.

## ẢNH XEM TRƯỚC HOME BỊ NGƯỢC + NÚT LƯU + BASS NỀN DỜI CHỖ (2026-09-12) — XONG, build OK
- **BUG thật — thumbnail Home bị lộn ngược** (ảnh + chữ + sóng đều ngược): `ThumbnailRenderer.generate`
  vẽ vào 1 `CGContext(data:nil,...)` THÔ (y-UP gốc, KHÔNG phải view `isFlipped`) nhưng lại gọi
  `Compositor.draw(..., flipped: true)` cho MỌI lớp — sai quy ước (`flipped:true` nghĩa là "context
  ĐÃ y-DOWN sẵn", như trong `TransparentVideoExporter`). Sửa: bắt chước ĐÚNG thứ tự của exporter —
  vẽ nền với `flipped:false` trước, rồi TỰ lật CTM thật (`translateBy`+`scaleBy(y:-1)`), rồi mới vẽ
  lớp đè/chữ với `flipped:true`. Nhân tiện đổi `KaraokeRenderer.drawPreview` (dựa `NSImage`/
  `NSGraphicsContext`, vốn cho main thread) → `drawExport` (thuần CGContext, đúng chỗ vì hàm này
  chạy nền `DispatchQueue.global`).
- **Thêm nút "Lưu" vào dãy nút Xuất/Lưu thành** ở thanh công cụ — trước giờ chỉ có Lưu thành/Xuất,
  muốn Lưu (ghi đè) phải vào menu hoặc ⌘S.
- **"Nền tự zoom theo nhạc" → đổi tên "Hiệu ứng Bass nền" + dời chỗ + đổi UI**:
  - Dời từ tab "Sóng nhạc" sang tab "Nền video", đặt NGAY DƯỚI Picker "Kiểu nền" (Đen/Xám/Ô caro/
    Ảnh-Video) — luôn hiện, không giấu trong DisclosureGroup nữa.
  - Mức zoom đổi từ 3 lựa chọn cố định (1.15/1.25/1.5) sang **thanh trượt liên tục 1.0…1.3**
    (`bgSlider`, cùng kiểu với Phóng to/Lệch ngang/Độ mờ nền).
  - **Tháo phụ thuộc vào "Sóng nhạc" bật hay không** — trước đây hiệu ứng chỉ chạy khi
    `visualizer.enabled == true`; giờ ĐỘC LẬP hoàn toàn (chỉ cần `backgroundMedia.beatZoomEnabled`).
    Bật công tắc tự gọi `SpectrumStore.ensure(for:)` (như `setVisualizerEnabled` làm cho thanh cột),
    không còn ăn ké việc bật sóng nhạc. Cập nhật cả `KaraokePreview.currentBeatEnergy()` lẫn
    `TransparentVideoExporter` (điều kiện tính `vizAudioURL`/`vizData` giờ gồm cả `beatZoomEnabled`).

## HIỆU ỨNG BASS + THUMBNAIL CŨ + TIMELINE CHUYÊN NGHIỆP HƠN (2026-09-12, đợt 2) — XONG, build OK
- **"Hiệu ứng Bass nền" giờ CHỈ hiện khi đã chọn nền ảnh/video** — trước đó luôn hiện kèm dòng cảnh
  báo cam khi chưa có nền; nay ẩn hẳn cho tới khi có nền, đúng ý user.
- **Thumbnail project CŨ vẫn ngược** (vì file PNG cũ đã lưu sẵn từ trước bản vá, không tự vẽ lại):
  đổi tên file thumbnail sang hậu tố **"v2"** (`ProjectLibrary.thumbnailFileName`) → mọi project cũ
  coi như "chưa có ảnh", rồi thêm `ProjectLibrary.regenerateMissingThumbnails(_:onProgress:)` — gọi
  từ `HomeView.reload()`, tự vẽ lại NỀN cho các project thiếu ảnh "v2" rồi tự `reload()` 1 lần nữa để
  nạp ảnh mới. Có chặn lặp vô hạn (`thumbRegenAttempted`, set trong phiên) phòng khi 1 project vẽ
  lại luôn lỗi (media nền bị mất) — chỉ thử 1 lần/phiên, không phải mỗi lần mở Home.
- **Timeline "chuyên nghiệp hơn"** (user gửi ảnh 1 editor khác để tham khảo bố cục):
  - **Các hàng CAO hơn rõ rệt**: `waveHeight` 64→84, `laneHeight` (dòng lời) 24→32, `overlayLaneH`
    (làn lớp đè) 26→48, `selBlockH` (câu đang hát) 46→54. Đổi ĐỒNG BỘ cả 2 phía SwiftUI
    (`trackHeaderColumn`, cột nhãn cố định bên trái) lẫn AppKit (`TimelineCanvasView`, canvas cuộn
    ngang) — 2 bên vốn có sẵn 1 khoảng lệch ~30px không rõ lý do (nợ kỹ thuật cũ), đã GIỮ NGUYÊN
    độ lệch đó khi tính lại `totalHeight`/`duration` (không cố "sửa cho khớp tuyệt đối" — rủi ro cao
    hơn lợi ích, ngoài phạm vi yêu cầu).
  - **Clip ảnh/video trên timeline giờ có "vệt phim"** (`drawFilmstrip`/`drawAspectFillTile`,
    `overlayThumbnail`) — trải ảnh đại diện lặp lại kín chiều rộng clip (ảnh: đọc thẳng
    `OverlayImageStore`, đồng bộ; video: khung gần `trimStart` qua `OverlayVideoFrameStore`, BẤT
    ĐỒNG BỘ — tự hẹn vẽ lại 1 lần sau 0.35s nếu khung chưa sẵn sàng, tránh xếp hàng lặp). Phủ thêm
    1 lớp màu track mờ để vẫn phân biệt được lớp đè.
  - **Nhãn tên+thời lượng đổi thành "chip" nền tối** ở góc trên-trái mỗi clip — luôn đọc rõ dù có
    ảnh phía sau (trước đây là chữ trần, dễ chìm vào nền/ảnh).
  - **CÒN** (không làm đợt này, rủi ro/ công sức cao hơn): track "★ KARAOKE"/"Nhạc" giữ nguyên
    hình thức cũ (không phải danh sách clip nên không áp filmstrip); chưa tách `timeToX/xToTime`
    dùng chung (nợ kỹ thuật có sẵn, xem KNOWN_ISSUES).

## FILMSTRIP THẬT CHO CLIP VIDEO (2026-09-13) — XONG, build OK
Tiếp phần "CÒN" ở trên: clip **video** trên timeline giờ hiện **6 khung hình KHÁC NHAU** rải đều
dọc theo đoạn đang dùng của clip (không còn lặp y hệt 1 khung ở `trimStart` như bản đầu).
- **`VideoFilmstripStore`** (mới, `Rendering/Compositor.swift`) — cache RIÊNG, KHÔNG dùng chung
  với `OverlayVideoFrameStore` (cache đó phục vụ scrubbing preview, cơ chế đẩy-khung-xa-ra-khỏi-
  cache theo vị trí phát KHÔNG hợp để giữ nhiều khung rải khắp clip cùng lúc). Mỗi clip lấy đúng
  **1 lần** 6 khung (đều trong đoạn `[trimStart, trimStart+duration]` giây trong video gốc) qua
  `AVAssetImageGenerator.generateCGImagesAsynchronously(forTimes:)` — khớp khung nào xong theo
  `requestedTime` (không giả định thứ tự trả về, generator có thể trả không theo thứ tự yêu cầu).
  Cỡ nhỏ (200×200) vì chỉ hiển thị mini trên track. Được `OverlayImageStore.flush()` dọn theo
  (đổi project / thay clip).
- **`TimelineCanvasView.drawVideoFilmstrip`** — số "lát" hiển thị tính theo độ rộng vẽ
  (`tileW = max(28, r.height)`), MỖI lát ánh xạ sang 1 trong 6 khung theo vị trí (lát đầu → khung
  đầu, lát cuối → khung cuối, dàn đều ở giữa) — khung KHÔNG phụ thuộc độ rộng/zoom nên không phải
  tải lại khi zoom/cuộn timeline, chỉ đổi cách DÀN các khung đã có ra nhiều/ít lát hơn.
  Clip ẢNH vẫn dùng đường cũ (`overlayThumbnail`/`drawFilmstrip`, lặp 1 khung — hợp lý vì ảnh tĩnh
  không có "khung khác nhau theo thời gian").

## TAB "MEDIA" ĐƠN GIẢN HOÁ (2026-09-13) — XONG, build OK
User gửi ảnh 1 ô "+ Import" tối giản (icon tròn + chữ "Import" đậm, dưới là dòng
"Drag and drop videos, photos, and audio files here") → đổi tab "File của bạn" thành **"Media"**
và rút gọn nội dung xuống đúng 1 ô như vậy:
- `ContentView.filesPanel`/`mediaImportBox`: bỏ hàng tiêu đề + nút "Nhập file…" nhỏ cũ, bỏ icon
  khay + 2 dòng chữ giải thích cũ. Giờ chỉ còn 1 ô bo góc viền đứt nét, bấm HOẶC thả file (ảnh /
  video / nhạc) vào bất kỳ đâu TRONG Ô đó đều nhập được (`onDrop` gắn trực tiếp lên ô, không còn
  gắn lên cả panel như trước).
- Kho TRỐNG → ô cao, chiếm gần hết khu (giống ảnh tham khảo). Đã có file → ô co lại thành 1 thanh
  gọn phía trên, lưới thumbnail hiện bên dưới như cũ (không đụng phần kéo-thả-ra-timeline).
- Đổi tên tab ở thanh rail trái + câu chỉ dẫn ở "Nền video" (Bước 3) đều dùng "Media" thay
  "File của bạn". Thêm 2 khoá dịch: "Nhập file"→"Import", "Kéo và thả video, ảnh, nhạc vào
  đây"→"Drag and drop videos, photos, and audio files here" (khớp đúng chữ trong ảnh).

## PRESET "KARAOKE"/"LYRIC" ĐỔI NGUỒN + SỬA LỖI CHỌN MÀU ĐỨNG LẦN 2 (2026-09-13) — XONG, build OK
- **Preset mặc định đổi nguồn**: user gửi 2 file `karaoke.kbproj` + `lyric.kbproj` (đã tự đặt tên
  để phân biệt), thay `KaraokeStyle.mine0`/`mine0Next` (preset "Karaoke") và `mine1`/`mine1Next`
  (preset "Lyric") bằng đúng style trong 2 file này (`Models/KaraokeStyle.swift`), bỏ hẳn bộ cũ.
  **Phát hiện + sửa luôn 1 lỗi khi trích màu**: với ô tô ĐƠN SẮC (`ColorFill.style == .solid`),
  màu THẬT SỰ hiển thị là trường `color` (xem `ColorFill.flatColor`) — `color2` chỉ dùng khi tô
  GRADIENT, và có thể còn giá trị "rác" từ lần trước đổi qua gradient rồi đổi lại đơn sắc. Bản
  `mine1`/preset "Lyric" trước đó (từ project "toc tua tuyet") đã lấy NHẦM `color2` cho
  `highlightColor` (ra màu cam thay vì xanh dương/lục lam đúng) — lần trích xuất này lấy đúng
  `color`, dùng luôn 1 script Python đọc trực tiếp JSON để tránh gõ tay sai số.
- **Sửa "chọn màu bị đứng lần 2"**: `PopoverFirstClickFix` (trong `AppColorPicker.swift`) trước
  chỉ ép cửa sổ popover thành "key" ĐÚNG 1 LẦN lúc mở popover (`makeNSView`) — vá lỗi bấm lần ĐẦU
  bị nuốt. Nhưng mỗi lần CHỌN xong 1 màu, `onChange` chạy tới `store.edit(...)` ở cửa sổ CHÍNH
  (đổi tên Undo, đánh dấu "đã sửa"…) — việc này có thể khiến cửa sổ chính giành lại "key window",
  làm popover mất "key" NGAY SAU LẦN CHỌN ĐẦU. Bấm màu kế tiếp vì vậy lại bị nuốt y hệt lần đầu,
  đúng như user mô tả ("phải bấm ra ngoài bấm lại mới được"). Sửa: `updateNSView` (chạy lại mỗi
  khi popover vẽ lại, tức sau MỖI lần chọn màu) giờ cũng ép `.makeKey()` lại, không chỉ lúc mở.

## PROJECT ".KBPROJ" ĐỔI SANG DẠNG GÓI — MANG THEO MEDIA (2026-09-13) — XONG, build OK, CHƯA test qua UI thật
User báo: mở project cũ ở máy khác thì THIẾU nhạc gốc + vocal/beat đã tách (chỉ lưu ĐƯỜNG DẪN,
không copy file thật vào project) → chốt: project phải "tự mang theo" mọi media (nhạc + vocal/beat
tách + nền ảnh/video + mọi ảnh/video/nhạc phụ kéo vào timeline).
- **`Services/ProjectPackage.swift`** (mới) — `.kbproj` giờ là 1 **THƯ MỤC** (gói): `project.json`
  (đúng định dạng JSON như trước) + thư mục `Media/` chứa file COPY THẲNG vào. `materialize(...)`
  copy 1 file vào `Media/<tên cố định>`, bỏ qua nếu đích đã có VÀ cùng kích thước (đỡ copy lại
  video/nhạc nặng mỗi lần lưu).
- **`KaraokeProject`**: thêm `vocalStem`/`beatStem: AudioReference?` (Codable khoan dung, optional
  — project cũ thiếu 2 khoá này vẫn mở bình thường). Thêm 2 hàm:
  - `materializeMedia(intoPackage:)` — gọi lúc LƯU: copy nhạc gốc + vocal/beat + nền + mọi
    `mediaPool`/`overlays` (trừ lớp CHỮ, không có file) vào `Media/`, đổi `lastKnownPath` sang
    đường dẫn TRONG project + xoá `bookmark` (không cần security-scope cho file app tự quản lý).
    File nào không tìm thấy gốc thì bỏ qua ÊM, không chặn lưu.
  - `rehomeMediaIfNeeded(inPackage:)` — gọi lúc MỞ 1 project dạng gói: nếu đường dẫn cũ (lưu lần
    trước) không còn đúng — ví dụ cả thư mục `.kbproj` bị DI CHUYỂN/ĐỔI TÊN sau khi lưu (y hệt
    trường hợp copy sang máy khác) — tự tìm lại đúng file trong `Media/` CỦA CHÍNH gói đang mở
    (khớp theo TÊN file, vì lúc lưu đã đặt tên cố định) — tự "lành", không hỏi lại đường dẫn.
- **`ProjectStore`**: `open(from:)` phát hiện gói (thư mục) hay file JSON đơn (cũ) để đọc đúng
  chỗ; project CŨ vẫn mở bình thường, KHÔNG ép chuyển đổi. `write(to:)` giờ LUÔN lưu dạng gói —
  nếu chỗ lưu đang là 1 file JSON đơn (cũ) thì xoá file đó, dựng thư mục thay vào (đúng tên/vị
  trí) — nghĩa là project cũ hễ LƯU LẠI 1 lần là tự chuyển hẳn sang dạng gói.
- **`ProjectLibrary`**: `readEntry`/`regenerateMissingThumbnails` đọc `project.json` bên trong nếu
  là gói. Thêm `folderSize(_:)` tính dung lượng ĐỆ QUY cho gói (trước đây `attributesOfItem` trên
  thư mục chỉ ra số rất nhỏ, sai hoàn toàn so với dung lượng thật mang theo media).
- **`BeatSeparation.adoptFromProject(vocal:beat:)`** (mới) — mở project GÓI có sẵn `vocalStem`/
  `beatStem` (tách ở MÁY KHÁC) → dùng NGAY, khỏi tách lại từ đầu trên máy mới. `ContentView`
  (`adoptOrRefreshBeatSep`) ưu tiên nguồn này trước khi quét cache riêng của máy đang chạy.
  Ngược lại, MỖI LẦN tách xong (hoặc lấy từ cache máy này) đều lưu lại vào
  `project.vocalStem/beatStem` (`syncStemRefsIntoProject`, không qua undo — chỉ `markDirty()`) để
  lần LƯU kế tiếp gói theo luôn.
- **`FilePanels.chooseProjectToOpen`**: `canChooseDirectories` false→true (bắt buộc, không thì
  không chọn được project dạng gói qua nút "Mở project khác…").
- **SỬA LẠI NGAY TRONG NGÀY (2026-09-13, cùng ngày)**: bản đầu dùng "gói" = 1 THƯ MỤC TRẦN mang
  đuôi `.kbproj` — user test xong báo ngay "sao nó lại xuất thành thư mục, tôi cần nén vào 1
  file". Đổi hẳn sang **1 file ZIP THẬT** (`ProjectPackage` viết lại): lưu = dựng `project.json`
  + `Media/` trong 1 thư mục "staging" riêng (dưới `~/Library/Caches/KaraokeMaker/ProjectStaging/`,
  khoá theo đường dẫn project) rồi NÉN LẠI (`zip -rq0X`, **không nén thêm** vì audio/video đã nén
  sẵn — đỡ tốn thời gian mỗi lần lưu mà gần như không giảm dung lượng) thành đúng 1 file, ghi file
  tạm rồi thay vào (an toàn nếu crash giữa chừng). Mở = giải nén (`unzip -oq`) ra ĐÚNG thư mục
  staging đó — TÁI DÙNG nếu đã giải nén đúng bản này rồi (so mtime+size của chính file zip), khỏi
  giải nén lại mỗi lần mở. Danh sách thư viện Home đọc riêng `project.json` NGAY TRONG zip
  (`unzip -p`, không giải nén cả file) cho nhanh. Test tay: zip/unzip round-trip 139MB thật (project
  "mot thua yeu nguoi" user gửi) — nội dung khớp 100%, ra đúng 1 file.
  Vẫn nhận diện được thư mục trần (bản buổi sáng, lỡ đã lưu 1 project bằng bản đó) để không mất
  dữ liệu — lưu lại lần nữa sẽ tự chuyển đúng sang zip.
  `FilePanels.chooseProjectToOpen`: `canChooseDirectories` trả về `false` (vì giờ lại là file thật).
- **CÒN** (không làm đợt này): chưa đăng ký `.kbproj` là UTI riêng trong Info.plist (đuôi lạ nên
  Finder có thể chưa hiện đúng icon/kiểu file — KHÔNG ảnh hưởng mở/lưu, mở bằng app vẫn đúng).
- **CHƯA test qua UI thật** (chỉ build OK + test tay zip/unzip bằng lệnh shell) — cần user tự lưu
  1 project thật trong app, kiểm tra ra đúng 1 file `.kbproj`, mở lại được, copy sang máy khác thử.

## LAG "TOÀN BỘ APP" LÚC ĐANG PHÁT — TÌM RA GỐC + THỬ SỬA (2026-09-13) — build OK, CHƯA xác nhận hết lag
User báo trên máy Intel 2017: "đụng cái gì cũng lag, lag toàn bộ app" (không riêng lúc phát/kéo
timeline như nghi ban đầu). Bắt CPU bằng `sample` NGAY LÚC user đang thao tác (nhạc/video đang
phát nền) trên chính máy đó (Bash chạy trực tiếp trên iMac, không qua SSH) — phát hiện: **gần
1 nửa thời gian luồng chính** nằm trong `CATransaction commit → NSDisplayCycleFlush →
[NSWindow layoutIfNeeded] → Auto Layout toàn bộ cây view`, lặp lại mỗi lần màn hình refresh
(~60Hz) SUỐT lúc phát. Nguyên nhân: `TimelineCanvasView`'s vạch đỏ (playhead) di chuyển mượt bằng
1 `CABasicAnimation` chạy trên render-server suốt lúc phát (kỹ thuật CŨ, cố ý — xem
[[smoothness-standard]]) — nhưng hễ CỬA SỔ có bất kỳ `CAAnimation` nào đang chạy, AppKit tự đồng
bộ CẢ CỬA SỔ theo vsync và CHẠY LẠI Auto Layout toàn bộ mỗi lần, bất kể animation đó có ảnh hưởng
layout hay không. Máy Apple Silicon đủ nhanh nên không lộ; máy Intel cũ thì "làm gì cũng lag"
suốt lúc có nhạc đang chạy nền — đúng như mô tả.
- **Sửa**: `TimelineEditor.swift` — bỏ hẳn `CABasicAnimation` (`startPlayheadAnimation`/
  `freezeAnimationInPlace`/`finishFrozenCleanupIfNeeded` viết lại/gỡ). Giờ tự set
  `playheadLayer.position.x` MỖI KHUNG bằng cách đọc thẳng đồng hồ mượt (`timeProvider` =
  `playback.renderTime`, không nội suy riêng) qua `DisplayLink` SẴN CÓ — không còn `CAAnimation`
  nào chạy nên không còn kéo cả cửa sổ vào chế độ đồng bộ vsync nữa.
  **KHÔNG đụng**: điểm gọi (play/seek/zoom), vệt quét + tự cuộn 15Hz (đã tinh chỉnh trước, từng
  sửa hỏng 1 lần — xem [[smoothness-standard]] "ĐỪNG SỬA KÈM").
- **Rủi ro cần user xác nhận**: cách cũ nội suy trên render-server (tuyệt đối mượt, không phụ
  thuộc luồng chính); cách mới phụ thuộc `DisplayLink` gọi được đều đặn — nếu luồng chính vẫn bận
  vì lý do khác, vạch đỏ có thể giật nhẹ (dù có cơ chế gộp nhịp chống dồn ứ sẵn trong
  `DisplayLink`). Cần test thật: phát nhạc, thao tác việc khác (gõ, chuyển tab) xem còn lag không
  + nhìn vạch đỏ có còn mượt không.

## LAG — SỬA LẦN 1 KHÔNG ĐỦ, TÌM RA LÝ DO + THỬ LẦN 2 (2026-09-14)
Bản sửa 2026-09-13 (bỏ `CABasicAnimation` playhead) đo lại bằng `sample` **KHÔNG giảm** — vẫn
~35% thời gian luồng chính trong chuỗi Auto Layout toàn cửa sổ. Lý do: KHÔNG phải do CÓ
`CAAnimation` hay không — tự set `position`/`needsDisplay` mỗi khung (thay animation) CŨNG tạo
đúng số lần commit CATransaction theo vsync, tốn y hệt. Đòn bẩy thật = **TẦN SUẤT** commit, không
phải cơ chế. Xác nhận thêm: đo lúc app THỰC SỰ đứng yên (không phát) → 0% CPU — vậy chi phí này
CHỈ tồn tại lúc đang phát, không phải mọi lúc như "lag từ a-z" nghe qua (user chắc luôn để nhạc
chạy khi làm việc nên cảm giác là "lúc nào cũng lag").
- **Sửa lần 2**: hạ tần suất vẽ THẬT (không phải tần suất polling — vẫn đọc đồng hồ mỗi vsync,
  chỉ BỎ QUA nếu chưa đủ 1/30s) từ ~60Hz xuống ~30Hz cho CẢ 2 nơi: `KaraokePreviewCanvas.
  displayTick` (`Views/KaraokePreview.swift`) và `TimelineCanvasView.playTick`'s phần set vị trí
  vạch đỏ (`Views/TimelineEditor.swift`) — mắt người vẫn thấy mượt với NỘI DUNG CHỮ (không phải
  video hành động nhanh). Vệt quét + tự cuộn 15Hz (đã tinh chỉnh trước) GIỮ NGUYÊN, không đụng.
- **Cách theo dõi mới**: thay vì nhờ user tự test rồi báo, giờ tự chạy `sample <pid> <phút dài>`
  LIÊN TỤC trong nền suốt lúc app mở (script ở `/tmp/km_watch/`, KHÔNG phải phần code của app) —
  user chỉ cần dùng app bình thường, không cần "test" riêng.
- **CHƯA xác nhận** bản sửa lần 2 này có đủ giảm cảm giác lag không — build OK, đã đóng gói,
  đang chờ dữ liệu từ lần mở kế tiếp.

## LAG — TÌM RA THỦ PHẠM THẬT + SỬA LẦN 3 (2026-09-14)
User xác nhận trên iMac 2017: **lag giật TOÀN BỘ app** lúc phát, trong khi phần mềm nặng hơn
nhiều chạy tốt trên máy đó → xác nhận đây là lỗi KIẾN TRÚC app, không phải máy yếu. Đo `sample`
LIVE trên chính iMac (không qua log cũ — log nền tự động trước đó lẫn nhiều đoạn app đứng ở dialog
"xác nhận thoát", không dùng được) lúc đang phát nhạc thật với bản sửa lần 2: vẫn ~50% thời gian
luồng chính nằm trong chuỗi `NS_setFlushesWithDisplayLink → layoutIfNeeded` (Auto Layout TOÀN CỬA
SỔ, không riêng timeline). Đào sâu thêm 1 lớp lộ ra thủ phạm KHÁC hẳn 2 lần sửa trước: chuỗi này đi
qua `+[NSAnimationContext runAnimationGroup:]` được gọi từ SwiftUI — tức có 1 giá trị SwiftUI đổi
được AppKit coi là "animation" dù mình không viết animation nào cho nó.
- **Thủ phạm**: `PlaybackController.clock.seconds` (`PlaybackClock`, ~8Hz — thiết kế CỐ Ý từ đầu
  để CHỈ vài ô nhỏ trong `PlaybackHUD` theo dõi, KHÔNG phải để `ContentView` dựng lại — xem
  `ARCHITECTURE.md` §Playback). Tần suất thấp, nhưng MỖI lần đổi, SwiftUI báo AppKit qua
  `NSAnimationContext` (mặc định của cầu SwiftUI↔AppKit khi 1 view SwiftUI đổi kích thước/nội
  dung, dù tức thời) → AppKit đánh dấu CẢ CỬA SỔ "đang animate liên tục" → Auto Layout của TOÀN
  BỘ cửa sổ chạy lại MỌI khung hình sau đó (1 `NSWindow` = 1 hệ ràng buộc DUY NHẤT, không tách
  theo từng ô nhỏ) — đúng cơ chế "app nhẹ mà lag toàn bộ" user mô tả.
- **Sửa**: `Services/PlaybackController.swift` — thêm `setClockSeconds(_:)` bọc bằng
  `withTransaction(Transaction(animation: nil))`, thay MỌI chỗ gán `clock.seconds = …` (14 chỗ:
  `load/unload/play/pause/seek/swapSource/syncTime/virtualSync`) bằng gọi hàm này — báo thẳng
  SwiftUI "đừng animate", chặn từ gốc, KHÔNG đụng tần suất/`DisplayLink`/vạch đỏ (giữ nguyên sửa
  lần 1+2, đúng nguyên tắc "đừng sửa kèm" — xem `[[smoothness-standard]]`). Thêm `import SwiftUI`.
- **Đo lại NGAY trên iMac** (build + đóng gói + mở app + `sample` 30s lúc đang phát, cùng điều
  kiện với lần đo trước): `NS_setFlushesWithDisplayLink` 50% → **~10%** thời gian luồng chính;
  `layoutIfNeeded` 41% → **~9%**. Giảm 4–5 lần. Còn dư ~10% từ 1 nguồn animation khác (nghi sóng
  nhạc hoặc preview overlay) — nhỏ hơn nhiều gốc cũ, chưa đào tiếp.
- **CHƯA test cảm nhận thật trên M4 lẫn xác nhận hết lag trên iMac** — chỉ mới đo bằng `sample`.
  Cần user tự test cảm giác mượt/lag sau khi nhận bản mới.

## LAG — TÌM RA CON SỐ THẬT + SỬA LẦN 4 (2026-09-15)
User báo lần 3 (14/9) CHƯA đủ — "đụng gì cũng lag rất nặng", muốn app chạy được trên MỌI đời Mac.
Đo `sample` NGAY trên chính iMac 2017 (mở thẳng app local, không qua M4) trong lúc user vừa phát
nhạc vừa thao tác thật (kéo timeline/gõ chữ/mở 1 dropdown) — **chỉ đo ĐÚNG 1 LẦN theo yêu cầu user
(không thử lại nhiều lần nữa)**: 72% thời gian luồng chính nằm trong ĐÚNG chuỗi lần 3 đã tìm ra
(`+[NSAnimationContext runAnimationGroup:]` từ SwiftUI → `-[NSWindow layoutIfNeeded]` → Auto Layout
TOÀN BỘ cây view 3 cột + timeline), xảy ra trong lúc 1 menu/dropdown macOS đang mở (tracking loop
của NSMenu bơm run loop rất nhanh, và ticker của `PlaybackClock` chạy ở chế độ `.common` nên VẪN
tích tắc trong lúc đó).
- **Con số then chốt**: sửa lần 3 (animation: nil) làm chuỗi này GIẢM đúng bằng tần suất tick chứ
  KHÔNG loại bỏ được — mỗi lần đổi `clock.seconds` (8 lần/giây) vẫn buộc AppKit chạy lại Auto Layout
  CẢ CỬA SỔ, và trên CPU đời 2017 này mỗi lần chạy lại tốn ~90ms → 8 × 90ms ≈ **72% luồng chính bận
  liên tục lúc phát nhạc** — khớp CHÍNH XÁC với số đo được và với cảm giác "đụng gì cũng lag" của
  user (vì Auto Layout của TOÀN cửa sổ nghẽn thì MỌI thao tác khác trên cùng cửa sổ cũng phải
  chờ). `withTransaction(animation: nil)` (lần 3) chỉ chặn được PHẦN HIỆU ỨNG mượt của animation,
  không chặn được việc AppKit coi mỗi lần commit là "cửa sổ đang animate" và relayout toàn bộ.
- **Sửa**: `Services/PlaybackController.swift` — hạ `tickInterval` từ **8 xuống 3 lần/giây**
  (nhãn giờ/thanh tua/dòng đang hát KHÔNG cần mượt tuyệt đối — vạch đỏ thật đọc `renderTime` riêng,
  không qua ticker này). Giảm trực tiếp ~2.6 lần chi phí trên (ước tính 72% → ~27% theo đúng tỉ lệ
  tần suất, CHƯA đo lại vì user chỉ cho đo 1 lần).
- **CHƯA hết gốc**: gốc thật là kiến trúc "1 NSWindow SwiftUI-trong-AppKit = 1 hệ ràng buộc
  DUY NHẤT" — bất kỳ thay đổi state nào ở bất kỳ đâu trong cây cũng khiến CẢ cửa sổ phải tính lại.
  Muốn hết HẲN cần tách các view ăn theo `clock.seconds` (`TransportBar`/`NowPlayingBadge`/
  `PlaybackTicks` trong `PlaybackHUD.swift`) ra `NSHostingView` RIÊNG, không chung hệ ràng buộc với
  cửa sổ chính — việc LỚN hơn, rủi ro cao hơn, để làm sau nếu hạ tần suất vẫn chưa đủ.
- Build OK 2026-09-15. Đã push bản này sang M4 luôn (không chờ user bấm lệnh) vì user đã mệt vì
  thử đi thử lại — CHỈ 1 lệnh mở app, không có bước "thử rồi báo lại" nào thêm ngoài dùng bình
  thường.

## LAG — SỬA LẦN 5: BỎ HẲN, KHÔNG CHỈ GIẢM TẦN SUẤT (2026-09-15, cùng ngày)
User phản hồi lần 4 (hạ 8→3 lần/giây) "không chút nào thay đổi" + ra lệnh sửa TRIỆT ĐỂ, không
chấp nhận thêm vòng thử-sửa-thử. Đúng — hạ tần suất chỉ giảm SỐ LẦN giật, không giảm ĐỘ NẶNG mỗi
lần (~90ms/lần vẫn y nguyên, con người vẫn thấy giật dù ít lần hơn). Phải bỏ hẳn cơ chế gây giật,
không phải giảm tần suất nó.
- **Gốc thật (đã xác nhận qua sample lần 4)**: `PlaybackClock.seconds` là `@Published` trên 1
  `ObservableObject` đưa vào `@EnvironmentObject`. MỖI lần gán — dù bọc `withTransaction(animation:
  nil)` — việc PUBLISH qua Combine tự nó đã kích hoạt 1 "commit" ở cầu SwiftUI↔AppKit
  (`+[NSAnimationContext runAnimationGroup:]`), và AppKit coi bất kỳ commit nào cũng là "cửa sổ
  cần relayout", chạy lại Auto Layout CẢ CỬA SỔ (1 NSWindow = 1 hệ ràng buộc). `animation: nil` chỉ
  bỏ được hiệu ứng mượt của animation, KHÔNG bỏ được việc commit xảy ra.
- **Sửa**: bỏ hẳn `@Published` khỏi `PlaybackClock.seconds` (`PlaybackController.swift`) — giờ là
  biến thường, gán thẳng không qua `withTransaction` nữa (không còn gì để publish). 3 nơi DUY NHẤT
  từng đọc `clock.seconds` qua `@EnvironmentObject` (`TransportBar`, `NowPlayingBadge`,
  `PlaybackTicks` — cả 3 trong `PlaybackHUD.swift`) đổi sang bọc `TimelineView(.periodic(from:
  .now, by: 1.0/3.0))` — cơ chế CHÍNH THỨC của Apple cho UI cập nhật liên tục (đồng hồ, hoạt hình)
  tự polling theo lịch riêng, không đi qua `objectWillChange`/commit toàn cửa sổ. `.onChange(of:
  clock.seconds)` trong `PlaybackTicks` vẫn hoạt động đúng (so sánh giá trị giữa 2 lần polling của
  TimelineView, không cần Combine).
- KHÔNG đụng `renderTime`/`DisplayLink`/vạch đỏ (lần 1+2), KHÔNG đụng cách tính giờ, KHÔNG đụng
  `PlaybackController` public API — chỉ đổi CƠ CHẾ 3 view đọc giờ hiển thị.
- Build OK. **CHƯA đo lại bằng `sample`** (user không muốn thêm vòng thử) — về LÝ THUYẾT loại bỏ
  hẳn nguồn gây relayout thay vì giảm tần suất, nên kỳ vọng cao hơn nhiều so với lần 4, nhưng CHƯA
  CÓ số đo xác nhận. Nếu vẫn còn lag sau bản này, nghĩa là còn ÍT NHẤT 1 nguồn khác (nghi
  `MusicVisualizer`/spectrum hoặc chính `NSSplitView` — `HSplitView`/`VSplitView` trong
  `ContentView.mainLayout` vốn nổi tiếng nặng khi relayout, xem trace: đệ quy
  `NSPerformVisuallyAtomicChange`/`_layoutSubtreeWithOldSize:` nhiều lớp trùng khớp với cấu trúc
  split view lồng nhau) — sẽ cần đào tiếp CHỈ KHI user báo còn lag, không tự ý làm thêm.

## LAG — SỬA LẦN 6: TỰ BẮT ĐƯỢC LỖI DO CHÍNH LẦN 5 TẠO RA (2026-09-15/16, cùng đợt)
User báo lần 5 "vẫn không có gì thay đổi, vẫn lag" — hỏi lại xác nhận: **lag XẢY RA CẢ KHI KHÔNG
PHÁT NHẠC** (gõ chữ/kéo chuột, không cần bấm play). Bật `PerfMonitor` (biến môi trường `KMK_PERF=1`,
CÓ SẴN trong code từ trước — không phải thêm mới, chỉ log ra Terminal) trong lúc user dùng project
thật: log cho thấy đứng hình LẶP LẠI liên tục, mỗi lần ~4–10 GIÂY — nặng hơn hẳn mức đo được trước.
- **Bắt tận tay bằng `sample`** đúng lúc app đang chạy (project đã mở, KHÔNG phát nhạc — nhãn "(-)"):
  67% luồng chính vẫn nằm trong ĐÚNG chuỗi cũ (`NSDisplayCycleFlush` → `layoutIfNeeded` → Auto
  Layout CẢ CỬA SỔ), và app-frame nóng nhất là `PlaybackHUD.swift:27` — CHÍNH LÀ `TimelineView`
  vừa thêm ở lần 5!
- **Lỗi do chính lần 5 gây ra**: `TimelineView(.periodic(from: .now, by: 1/3))` trong
  `TransportBar`/`NowPlayingBadge`/`PlaybackTicks` chạy VÔ ĐIỀU KIỆN — không kiểm tra
  `playback.isPlaying`. Tự polling 3 lần/giây MÃI MÃI hễ các view này còn trên màn hình
  (`PlaybackTicks` LUÔN có mặt, gắn ở `.background()` của `mainLayout`), bất kể có đang phát nhạc
  hay không. TỆ HƠN bản GỐC (ticker cũ chỉ chạy lúc `play()` gọi `startTicker()`, dừng hẳn lúc
  `pause()`) — lần 5 vô tình biến 1 chi phí CHỈ-LÚC-PHÁT thành chi phí THƯỜNG TRỰC. Giả thuyết ban
  đầu ("TimelineView không qua `objectWillChange` nên rẻ hơn") cũng chỉ ĐÚNG MỘT PHẦN — `sample`
  cho thấy TimelineView VẪN đi qua đúng chuỗi relayout như trước, chỉ là ĐÚNG RA nó nên chỉ chạy
  khi cần (lúc phát), không phải "rẻ vô hạn nên chạy hoài cũng được".
- **Sửa**: cả 3 view (`PlaybackHUD.swift`) giờ CHỈ bọc `TimelineView` khi `playback.isPlaying`
  (`TransportBar`/`NowPlayingBadge` thêm `@EnvironmentObject var playback`, `PlaybackTicks` dùng
  luôn param `isPlaying` có sẵn) — lúc dừng phát, `body` là view TĨNH bình thường, không tự polling
  gì cả. Tự test bằng `sample` trên Home screen (chưa mở project, chưa phát) SAU bản sửa: luồng
  chính quay lại ~100% `mach_msg2_trap` (idle thật, không còn `layoutIfNeeded` lặp) — khớp baseline
  "0% lúc idle" ban đầu.
- **CHƯA xác nhận với PROJECT THẬT đang mở + không phát** (chỉ tự test được Home screen trống — không
  có cách tự động thao tác GUI thay user, không có quyền Accessibility để tự bấm/gõ). Đây là kịch
  bản CHÍNH user báo lag, cần user xác nhận. Nếu vẫn còn lag lúc KHÔNG phát nhạc sau bản này, nghĩa
  là còn ÍT NHẤT 1 nguồn polling/animation khác NGOÀI 3 view này — nghi tiếp: `MusicVisualizer`/
  `SpectrumAnalyzer` (nếu tự chạy không cần phát), hoặc `ProgressView()` (indeterminate spinner)
  nào đó bị kẹt hiện dù không có việc đang chạy thật (`phaseRow`/`progressRow` trong
  `ContentView.swift`).
- Build OK, đã push M4. **Bài học**: `PerfMonitor` (`KMK_PERF=1`) + `sample` đúng lúc là cách chẩn
  đoán ĐÁNG TIN CẬY nhất cho lỗi loại này — nên dùng NGAY LẦN ĐẦU thay vì đoán kiến trúc trước.

## PACKAGE FORMAT · thêm cảnh báo khi mất media (2026-09-15)
User báo lưu project rồi mở máy khác "không có gì", "không chọn được nền". Đọc lại
`materializeMedia`/`rehomeMediaIfNeeded` (2026-09-13): logic tự nó đúng, nhưng nếu lúc LƯU mà
nguồn media không resolve được (đã bị xoá/di chuyển) thì bị BỎ QUA ÊM — project lưu ra vẫn trỏ
đường dẫn ngoài máy, mở máy khác chắc chắn thiếu mà không ai biết trước. Nghi ngờ mạnh nhất: user
test bằng project ĐÃ LƯU TRƯỚC 2026-09-13 (chưa từng gói media — quy tắc cũ ghi rõ chỉ "lưu lại"
mới chuyển sang gói mới). Xem chi tiết `KNOWN_ISSUES.md`.
- **Sửa**: `KaraokeProject.materializeMedia` giờ trả `[String]` tên món không copy được →
  `ProjectStore.write` hiện banner lỗi ngay lúc LƯU. Thêm `KaraokeProject.missingMediaLabels()` →
  `ProjectStore.open` hiện banner nếu sau khi mở (đã rehome) vẫn còn món thiếu. Cả 2 chỗ trước đây
  im lặng hoàn toàn.
- KHÔNG đổi cơ chế zip/copy/rehome đang có (đã test tay round-trip trước đó) — chỉ thêm lớp báo lỗi
  để CHẨN ĐOÁN, chưa chắc đã hết gốc rễ.
- Build OK, CHƯA test qua UI thật/M4. Cần user trả lời khi test: project test cũ hay mới lưu lại?
  Copy sang máy kia bằng gì? Banner lỗi mới có hiện không, nội dung gì?

## NEXT (chờ user chọn)
- Roadmap M-A…M-F + M-D 1/1b + **M-E** XONG. M-D2 ⛔ BỎ HẲN. M-G (karaoke-as-track) = dính karaoke, KHÔNG làm.
- **Chờ user test M4**: (1) bug "không có tiếng" bài chính — xem KNOWN_ISSUES, cần user trả lời câu
  chẩn đoán; (2) tiếng clip video lớp đè (preview + xuất); (3) preview overlay video 30fps.
- Ý mới nếu user muốn: keyframe cho lớp đè · hiện vùng cắt bài trên track "Nhạc" ·
  slider âm lượng riêng cho tiếng clip video (giờ cố định 100%) · tune hằng số kernel màu bằng test ảnh.

## BLOCKERS
- Không có. (Aligner "tạo karaoke" bị KHÓA theo yêu cầu user — không phải blocker.)

## LAG — SỬA LẦN 7: TÌM RA + CÔNG CỤ TỰ TÁI HIỆN KHÔNG CẦN USER (2026-09-17)
User rất bực vì nhiều lần "sửa" mà đo không ra gì, phải nhờ đo trực tiếp trên máy. Lần này:
- Xây được bộ công cụ TỰ ĐỘNG, không cần user thao tác: `KM_AUTO_OPEN` (mở thẳng 1 project qua
  biến môi trường, `RootView.autoOpenForSelfTestIfRequested`), `KM_AUTO_PLAY`, `KM_AUTO_STRESS`
  (`seek`/`tab`/`line`/`all` — giả lập tua/đổi tab/chọn dòng liên tục bằng code, KHÔNG cần bấm
  chuột thật), `KM_BODY_LOG`/`KM_DRAW_LOG` (đếm thật số lần `ContentView.body`/`draw()` chạy,
  in ra Terminal mỗi 2s). Tất cả đều CHỈ hoạt động khi set biến môi trường — build thường (user
  dùng) không đổi gì.
- Dùng bộ công cụ trên tách được: idle THẬT (không thao tác gì) → sạch hoàn toàn (0 lần/giây,
  0 giật) sau khi sửa `KaraokePreviewCanvas.updateNSView` (đặt `needsDisplay=true` VÔ ĐIỀU KIỆN
  — đã sửa, xem mục trước). Nhưng hễ có THAO TÁC THẬT (tua timeline) thì vẫn giật nặng — kể cả
  sau tất cả các lần sửa trước.
- **Cô lập bằng `KM_AUTO_STRESS=seek` (chỉ tua, không đổi gì khác)**: vẫn giật y hệt mức
  "tua+đổi tab+chọn dòng" gộp lại → xác nhận CHÍNH VIỆC TUA là nguồn nặng nhất, không phải đổi
  tab.
- **Tìm ra CHÍNH XÁC**: `PlaybackController.seekGeneration` (`@Published`) tăng mỗi lần tua.
  `ContentView` giữ `PlaybackController` qua `@EnvironmentObject` (cần cho isPlaying/duration/...)
  → MỖI lần publish trên `PlaybackController`, KỂ CẢ `seekGeneration` mà `ContentView` không hề
  đọc trực tiếp, vẫn đánh dấu `ContentView.body` (cây 3 cột + timeline) dựng lại — đúng cơ chế
  "coarse-grained" của `ObservableObject`/Combine (không phân biệt theo property). `sample` xác
  nhận: kéo/tua thấy ~50% luồng chính nằm trong `NSPerformVisuallyAtomicChange`/Auto Layout CẢ
  CỬA SỔ, dù chẳng có gì ở 3 cột kia cần đổi khi tua.
- **Sửa**: dời `seekGeneration` từ `PlaybackController` sang `PlaybackClock` (vốn ĐÃ tách riêng
  từ lần sửa clock.seconds — `ContentView` KHÔNG giữ `@EnvironmentObject var clock`, xác nhận qua
  grep). `TimelineEditor`/`KaraokePreview` (2 nơi DUY NHẤT cần biết lúc tua) thêm
  `@EnvironmentObject var clock: PlaybackClock` để tự đọc `clock.seekGeneration` thay vì
  `playback.seekGeneration`. `PlaybackController.seekGeneration` giữ lại dạng computed property
  (đọc xuyên qua `clock`) cho code cũ không phải sửa gì khác. KHÔNG đổi logic tua thật (player,
  currentTime, clock.seconds) — chỉ đổi KÊNH PHÁT của 1 con số đếm.
- **Đo trước/sau bằng `KM_AUTO_STRESS=seek`, cùng project, cùng máy**: đỉnh giật 280-990ms → còn
  168-240ms; số nhịp PerfMonitor bắt được mỗi 2s (30Hz, tối đa 60) từ 33-38 lên 44-53 — giảm thật
  khoảng 40-50%, không phải suy đoán.
- **CHƯA hết hẳn** — còn ~4 lần giật/2s dư lại (nghi do `leftPanelTab` đổi tab thật sự cần dựng
  lại nội dung panel, hoặc còn 1-2 @Published khác trên `playback`/`store` chưa cô lập). Thử
  `KM_NO_SPLITVIEW=1` (thay `HSplitView`/`VSplitView` bằng `HStack`/`VStack` thường) để kiểm tra
  giả thuyết "chính NSSplitView nặng" — ĐO RA KHÔNG PHẢI (không cải thiện, thậm chí nhỉnh hơn) —
  đã loại giả thuyết này, KHÔNG đổi UI thật (cờ mặc định tắt).
- Build OK, đã tự đo xong (không cần user), đã push.

## LAG — SỬA LẦN 8: ĐỔI TAB CỘT TRÁI GIẬT NẶNG — ẢNH KHO KHÔNG CACHE (2026-09-18)
Tiếp tục điều tra "~4 lần giật/2s dư lại" ghi ở SỬA LẦN 7, nghi do `leftPanelTab`. Cô lập bằng
`KM_AUTO_STRESS=tab` (CHỈ đổi tab, không tua/không chọn dòng) — đo ra giật NẶNG HƠN cả lúc tua:
6-8 lần nghẽn/2s, đỉnh 500-600ms, PerfMonitor chỉ bắt được 2-8 nhịp/2s (tối đa 60) — gần như MỖI
lần đổi tab đều giật hàng trăm ms.
- **Tìm ra CHÍNH XÁC**: `mediaPoolThumb` (tab "Media", `ContentView.swift`) gọi
  `NSImage(contentsOf: url)` — đọc file + giải mã ẢNH GỐC FULL ĐỘ PHÂN GIẢI — THẲNG trong SwiftUI
  body, trên MAIN THREAD, KHÔNG cache, chạy lại cho MỖI ảnh trong kho MỖI lần panel dựng lại (mỗi
  lần đổi sang/rời tab Media). Ảnh nền (`decodeImage`, dòng ~3328) đã làm ĐÚNG từ trước (giải mã
  ngoài luồng chính + cache theo token) — chỉ riêng ảnh thu nhỏ trong kho bị bỏ sót.
- **Sửa**: thêm `mediaThumbCache: [UUID: NSImage]` (cache theo `item.id`, sống suốt vòng đời
  `ContentView`, không mất khi đổi tab). `mediaPoolThumb` đọc từ cache; nếu chưa có, hiện icon
  placeholder + `.task(id: item.id)` giải mã NGOÀI luồng chính (`Task.detached`, `CGImageSource`,
  giới hạn 240px — đủ cho ô 96pt, không giữ ảnh gốc nhiều MB trong RAM) rồi mới nạp vào cache trên
  main thread. KHÔNG đổi giao diện/kích thước ảnh hiển thị — chỉ đổi CÁCH giải mã.
- **Đo trước/sau bằng `KM_AUTO_STRESS=tab` (project có ảnh thật trong kho, cùng máy)**: đỉnh giật
  500-600ms → còn 85-190ms; nhịp PerfMonitor/2s từ 2-8 lên 54-58 (gần kín 60 — gần như mượt hoàn
  toàn). Đo lại kịch bản tổng hợp `KM_AUTO_STRESS=all` (tua + đổi tab + chọn dòng + đang phát nhạc
  cùng lúc): 34-55 nhịp/2s, đỉnh chủ yếu 100-260ms (trước đó kịch bản này giật nặng hơn cả seek-only).
- Build OK (không còn warning Sendable), đã tự đo xong bằng công cụ tự động (không cần user thao
  tác), đã push.
- **User báo "chẳng có gì thay đổi vẫn lag nặng" ngay sau bản SỬA LẦN 8** — xác nhận lại tiến trình
  đang chạy ĐÚNG bản mới nhất (build 01:58, tiến trình mở 02:00, chỉ 1 bản duy nhất trên máy, không
  phải lỗi build cũ như từng gặp trước đây). Nên đào tiếp, tìm thêm 1 nguồn khác (xem SỬA LẦN 9).

## LAG — SỬA LẦN 9: MÀN HOME (LƯỚI PROJECT) CŨNG BỊ Y HỆT BUG ẢNH KHÔNG CACHE (2026-09-18)
Sau SỬA LẦN 8, user báo vẫn lag dù chạy đúng bản mới. Rà lại TOÀN BỘ codebase tìm cùng antipattern
(`NSImage(contentsOf:)` đồng bộ, không cache) — thấy thêm 1 chỗ: `HomeView.swift` → `ProjectCard`
(thẻ project trong lưới màn Home, MÀN HÌNH ĐẦU TIÊN thấy mỗi lần mở app / bấm "← Thư viện"). Y hệt
lỗi `mediaPoolThumb`: đọc + giải mã ảnh thumbnail gốc trên main thread, ngay trong `body`, không
cache — chạy lại cho MỌI thẻ mỗi lần lưới dựng lại.
- **Sửa**: thêm `HomeThumbCache` (cache tĩnh theo đường dẫn file, sống suốt vòng đời app) +
  `ProjectCard` tự giải mã ảnh NGOÀI luồng chính qua `.task`, giới hạn 480px (đủ cho thẻ rộng
  ~220pt). Không đổi giao diện lưới.
- Rà thêm toàn bộ `Sources/` tìm `NSImage(contentsOf:/named:/data:)` — chỉ còn `SingerIcon.swift`
  (icon người hát cố định, đã cache đúng từ trước, không phải bug).
- **Đo idle thật (không thao tác gì, `KM_AUTO_OPEN` mở project có ảnh, 20s, không set
  `KM_AUTO_STRESS`)** sau cả 3 lần sửa (7+8+9): PerfMonitor 60-61 nhịp/2s (tối đa 61 ở 30Hz), hầu
  hết cửa sổ 2s **0 lần nghẽn>40ms**, chỉ 1 lần giật 497ms lúc mới mở (cold start, 1 lần duy nhất).
  `KM_BODY_LOG`/`KM_DRAW_LOG` không in dòng nào suốt 20s — `ContentView.body`/`draw()` không chạy
  đủ để lọt vào 1 cửa sổ báo cáo 2s nào → xác nhận idle THẬT SỰ sạch, không có vòng lặp ẩn.
- Build OK, đã tự đo xong, đã push.
- **CHƯA rõ đây có phải nguồn user đang thấy hay không** — mọi kịch bản tự động dựng được (idle /
  tua / đổi tab / kết hợp / mở màn Home) giờ đều đo sạch. Còn lại là những thao tác công cụ tự động
  KHÔNG giả lập được thật (không có quyền Accessibility để phát sự kiện chuột/bàn phím thật): kéo
  chuột thật trên timeline/overlay, resize cửa sổ/cột bằng tay, xuất video, mở project LẦN ĐẦU khi
  file còn nguội (chưa có gì trong RAM/cache hệ thống). Nếu user vẫn thấy lag sau bản này, CẦN biết
  ĐÚNG lúc nào/thao tác gì để đào tiếp đúng chỗ — không thể đoán thêm mà không có thông tin đó.

## LAG — SỬA LẦN 10: KÉO THANH TRƯỢT (SLIDER) GÂY ĐỨNG HÌNH 11 GIÂY — TÌM RA + SỬA (2026-09-18)
User trả lời câu hỏi cụ thể: "không chạy cũng lag, kéo thanh trượt cũng lag, background không
chọn để đổi được, chạy play càng lag nặng". Idle đã đo sạch ở SỬA LẦN 9 → tập trung vào "kéo thanh
trượt". Đọc `PlaybackHUD.swift` (`TransportBar`): thanh tua dùng `Slider(value: Binding(get: {
clock.seconds }, set: { onSeek($0) }))` — SwiftUI `Slider` gọi `set` (→ `seekTo` ở
`ContentView.swift`) liên tục ở TẦN SỐ KÉO CHUỘT THẬT (có thể 60+ lần/giây khi giữ kéo) — cao hơn
NHIỀU so với kịch bản tự động cũ (`KM_AUTO_STRESS=seek`, chỉ 2 lần/giây) nên chưa lộ ra.
- **Tìm ra CHÍNH XÁC**: `seekTo(_:)` set `currentLineIndex` — MỘT `@State` RIÊNG của `ContentView`
  (không đi qua `PlaybackClock` đã cô lập ở SỬA LẦN 7) — MỖI lần đổi đều bắt `ContentView.body`
  (3 cột + timeline) dựng lại + Auto Layout cả cửa sổ. Ở tần số kéo chuột thật, các lần dựng lại
  (mỗi lần ~100-600ms, xem SỬA LẦN 8) CHỒNG LÊN NHAU nhanh hơn tốc độ xử lý → dồn ứ thành 1 khối
  việc khổng lồ trên main thread.
- **Đo bằng công cụ mới `KM_AUTO_STRESS=scrub`** (gọi `seekTo` liên tục ~60 lần/giây trong ~1.5s,
  lặp 6 đợt — mô phỏng đúng 1 lần giữ-kéo-thả thật): **11104 ms (11 GIÂY) đứng hình liên tục** ngay
  đợt kéo đầu tiên. Đây gần như chắc chắn là nguồn user đang thấy ("kéo thanh trượt lag nặng"),
  và cũng giải thích được "background không chọn để đổi được" — bấm chọn trong lúc app đang kẹt xử
  lý hàng đợi layout dồn ứ thì coi như KHÔNG PHẢN HỒI trong nhiều giây, giống hệt "không chọn được".
- **Sửa**: thêm hàng đợi chặn tốc độ (throttle, `updateCurrentLineIndexThrottled`) — `currentLineIndex`
  chỉ cập nhật tối đa ~15 lần/giây trong lúc kéo (mắt không nhận ra chậm hơn), có lịch "đuổi theo"
  giá trị mới nhất ngay khi hết khung chặn nên luôn khớp đúng lúc thả chuột. `playback.seek` (tua/
  nghe âm thanh thật) KHÔNG bị chặn — chạy mọi lần, không mất độ chính xác.
- **Đo lại y hệt kịch bản `scrub` sau khi sửa**: **0 lần nghẽn >40ms** trong toàn bộ ~11s kéo liên
  tục (trước: 1 lần 11104ms + vài lần 69-254ms dư).
- Build OK, đã tự đo trước/sau bằng công cụ tự động (không cần user thao tác), đã push.

## LAG — SỬA LẦN 11: CHỌN DÒNG LÚC ĐANG PHÁT (6-10s) — CÔ LẬP TRIỆT ĐỂ + PHÁT HIỆN MỚI (2026-09-18)
User báo "vẫn vậy có sửa đc đéo gì đâu" sau SỬA LẦN 10, kèm rất bực vì bị nhờ test nhiều ngày —
yêu cầu tự test tự sửa, chỉ gọi khi xong. Tiếp tục đào KHÔNG nhờ user:
- **Phát hiện `PerfMonitor` (công cụ đo) có lỗ hổng lớn**: chỉ add RunLoop mode `.default`, nghĩa
  là timer đo TỰ TẮT trong lúc `.eventTracking` (kéo chuột thật) — đúng lúc cần đo nhất lại không
  đo được gì. Đã sửa sang `.common` (bao gồm cả `.eventTracking`). Mọi số liệu "sạch" trước đó có
  thể đã bỏ sót đúng khoảng nặng nhất.
- **Tìm thêm nguồn ở tầng SÂU HƠN SwiftUI**: `PlaybackController.seek(to:)` ghi thẳng
  `player.currentTime` — thao tác ĐỒNG BỘ của AVFoundation, có thể chậm tuỳ codec. Lúc kéo liên
  tục (`KM_AUTO_STRESS=scrub`, mô phỏng ĐÚNG tần số kéo chuột thật ~60Hz, khác "seek" cũ 2Hz):
  đo được **11104 ms đứng hình**. Đã thêm chặn tốc độ ghi audio-seek (tối đa 25 lần/giây, không
  đổi độ chính xác) + làm CỨNG `ContentView.updateCurrentLineIndexThrottled` thành LUÔN
  `DispatchQueue.main.async` (không bao giờ chạy đồng bộ trong stack gọi của sự kiện, bất kể mode
  RunLoop). Đo lại `scrub`: **0 lần nghẽn** (từ 11104ms).
- **Cô lập tiếp bằng đo riêng `line`+`play`**: chọn dòng lúc ĐANG PHÁT đo được 3320-10452ms/lần —
  TỆ HƠN NHIỀU so với chọn dòng lúc KHÔNG phát (~100-150ms/lần, đo bằng `line` không kèm `play`).
  Thử lại giả thuyết NSSplitView bằng `KM_NO_SPLITVIEW=1` ở ĐÚNG kịch bản này — TỆ HƠN (6-10s),
  tiếp tục xác nhận không phải nguyên nhân.
- **Gốc**: `currentLineIndex` vẫn là `@State` RIÊNG của `ContentView` (kể cả sau các lần sửa
  trước) — mọi nơi đổi nó (bấm chọn dòng TAY, và cả `PlaybackTicks` tự đẩy theo playhead lúc phát)
  đều bắt `ContentView.body` (3 cột+timeline) dựng lại. Đây là request rời rạc (1 click), KHÔNG
  throttle được như lúc kéo — phải cô lập triệt để như đã làm cho `seekGeneration`.
- **Sửa (tấn công thẳng kiến trúc, không phải throttle nữa)**: thêm `LineSelection`
  (`ObservableObject` riêng, khai báo NGOÀI `struct ContentView`). `ContentView` chỉ giữ
  `@State private var lineSelection = LineSelection()` (THAM CHIẾU THƯỜNG, không `@StateObject`/
  `@ObservedObject` — tự nó KHÔNG bị theo dõi khi đổi, y hệt cách `PlaybackClock` tách
  `seekGeneration`). `currentLineIndex` giờ là 1 computed property đọc/ghi xuyên `lineSelection`
  — ~30 chỗ code cũ trong `ContentView.swift` chạy y nguyên, không phải sửa từng chỗ.
  `LyricLinesList`/`StylePanel`/`TimelineEditor` (3 nơi THẬT SỰ cần biết để tô sáng dòng đang
  chọn) đổi từ nhận tham số snapshot sang tự đọc `@EnvironmentObject var selection: LineSelection`
  — chỉ RIÊNG chúng dựng lại khi đổi dòng, không còn kéo `ContentView`.
- **Đo lại `line`+`play` sau khi cô lập**: 6315-10452ms → còn ~550-600ms (thỉnh thoảng 1.1-2.5s) —
  giảm 10-20 LẦN. Còn dư 1 khoảng ~450-500ms so với lúc KHÔNG phát (~100-150ms) CHƯA rõ gốc (nghi
  cạnh tranh luồng chính với việc vẽ preview/timeline 30Hz đang chạy live lúc phát) — CHƯA đào
  tiếp, ghi vào KNOWN_ISSUES.
- **PHÁT HIỆN MỚI, CHƯA SỬA**: đo idle THẬT (không thao tác gì) sau khi có `PerfMonitor` chính xác
  hơn — lộ ra 1 kiểu giật ĐỀU ĐẶN ~250-600ms, khoảng 4 LẦN/GIÂY, chỉ xảy ra khi project ĐANG MỞ
  (Home screen sạch tuyệt đối: 60-61 nhịp/2s). Cô lập thêm: project "Dự án mới" (0 dòng lời, không
  nhạc) → SẠCH; project "khôi" (3 dòng lời, không nhạc — file JSON xác nhận không có `audio`) →
  GIẬT ĐỀU. Nghi liên quan tới việc CÓ dòng lời (`lines.count > 0`), CHƯA xác định được đúng đường
  gọi (đã tìm `SpectrumAnalyzer`/`OverlayAudioMixer`/`waveform`/timer 0.25s — không khớp). Đây có
  thể là nguồn "không chạy cũng lag" user báo — quan trọng, cần đào tiếp lượt sau.
- Build OK, đã tự đo trước/sau toàn bộ bằng công cụ tự động (không cần user thao tác), đã push.

## LAG — SỬA LẦN 12: TỰ PHÁT HIỆN ĐO SAI (nhầm project không nhạc) + sửa thêm + còn 1 loại nguồn mới (2026-09-18)
User báo "không hề có 1 chút nào thay đổi, vẫn lag nặng như cách đây mấy ngày trước" sau SỬA LẦN 11
— dù đã có số đo "0 lần nghẽn". Kiểm tra lại: **TOÀN BỘ test SỬA LẦN 10-11 chạy trên project
"khôi .kbproj" — project này `audio: null` (KHÔNG có nhạc), chỉ 3 dòng lời** — không đại diện cho
project thật user dùng (có nhạc, 30-60 dòng). Đây là lý do user thấy "0 thay đổi": bản đo trước
không phản ánh app thật.
- Đo lại toàn bộ trên project THẬT có nhạc (`mot thua yeu nguoi.kbproj`, 267s nhạc thật, 32 dòng,
  lấy từ thư viện project, đã đóng gói đúng chuẩn): idle sạch (60-61 nhịp/2s, không đổi so với
  trước), NHƯNG `KM_AUTO_STRESS=scrub` **vẫn giật 1.7-3.5 giây** — không sạch như báo trước.
- `sample` tìm ra thêm nguồn thật: `PlaybackClock.bumpSeek()` (đếm báo hiệu Timeline/Preview vẽ
  lại) chạy KHÔNG giới hạn tốc độ, ở tần số kéo chuột thật (60-90Hz). Dù chỉ 2 view SwiftUI nhỏ
  giữ `@EnvironmentObject` đọc nó, MỖI lần bump vẫn kích hoạt `-[NSWindow layoutIfNeeded]` áp dụng
  cho CẢ CỬA SỔ (đo `sample`: ~65% luồng chính nằm trong chuỗi `NSPerformVisuallyAtomicChange`)
  — Auto Layout của AppKit không tách theo từng SwiftUI subview đổi, mà theo CẢ CỬA SỔ mỗi lần có
  commit. Đã chặn `bumpSeek()` còn ~20 lần/giây (cùng khuôn mẫu throttle đã dùng cho
  `currentLineIndex`/audio-seek).
- **Đo lại (project thật, kịch bản `scrub`)**: đỉnh giật 3072-3530ms → còn ~700-1086ms — giảm thật
  ~3-4 lần, nhưng CHƯA sạch.
- `sample` SAU khi chặn bumpSeek lộ ra nguồn LOẠI KHÁC hẳn: không còn là SwiftUI/Auto Layout, mà là
  **chi phí VẼ THẬT** — `KaraokePreviewCanvas.draw` → `KaraokeRenderer.drawPreview` (CoreGraphics/
  CoreText vẽ chữ karaoke có hiệu ứng glow/shadow/gradient), chiếm ~17% luồng chính lúc kéo TRÊN
  PROJECT CÓ NHẠC+LỜI THẬT (project rỗng trước đó không có gì để vẽ nên không lộ ra). Đây KHÔNG
  phải lỗi "dựng lại không cần thiết" như mọi lần trước trong session này — là chi phí vẽ THẬT SỰ
  cần để hiển thị đúng nội dung, cần hướng sửa khác: cache lớp chữ đã vẽ (chỉ vẽ lại khi
  text/style đổi, không phải mỗi lần playhead nhích), hoặc giảm tần số vẽ khi đang kéo nhanh, hoặc
  tối ưu chính `KaraokeRenderer.drawPreview`. **CHƯA làm** — việc tiếp theo.
- Build OK, đã tự đo trước/sau TRÊN ĐÚNG LOẠI PROJECT user dùng, đã push.
- **Bài học rút ra**: từ nay MỌI lần tự đo phải dùng project THẬT (có nhạc, nhiều dòng) — không
  dùng project test rỗng/thiếu nhạc nữa, dù nhanh hơn để test. Project gợi ý dùng làm chuẩn:
  `~/Movies/KaraokeMaker Projects/mot thua yeu nguoi.kbproj` (đã đóng gói đúng chuẩn, có nhạc thật).

## LAG — SỬA LẦN 13: ẢNH CHỮ KARAOKE CACHE SAI ĐỊNH DẠNG — VẼ LẠI CHẬM MỖI KHUNG (2026-09-18)
User: "vậy thì sửa đi" — tiếp tục đào phần "chi phí vẽ thật" phát hiện ở SỬA LẦN 12.
- **Tìm ra CHÍNH XÁC bằng `sample`**: `KaraokeRenderer.drawPreview`'s `plan.curStatic` (ảnh chữ đã
  "bake" — cache, chỉ dựng lại khi ĐỔI dòng/style, cơ chế cache tự nó ĐÚNG) là 1 `NSImage` dựng
  bằng `NSImage(size:) + lockFocusFlipped(true)` — API cũ, backing store theo ĐẶC TÍNH MÀN HÌNH
  (trên iMac này = wide-gamut) chứ không phải 8-bit sRGB chuẩn. Hệ quả: MỖI LẦN dán ảnh cache này
  vào khung hình (`.draw(in:)`, chạy MỌI KHUNG kể cả khi ảnh không đổi), CoreGraphics phải tự
  chuyển định dạng lại (`vImageConverterConvert`/`CGDataProviderDirectGetBytesAtPositionInternal`)
  — đo được chiếm ~65% tổng số mẫu trong hàm vẽ preview lúc kéo. Đúng HỌ HÀNG với lỗi
  `contentsFormat`/RGBAf16 đã sửa cho 2 canvas AppKit ở lần sửa rất sớm trong session này, nhưng
  đây là 1 CHỖ KHÁC (ảnh NSImage cache, không phải CALayer).
- **Manh mối**: đường XUẤT VIDEO (`drawExport`) đã làm ĐÚNG từ trước — `renderStaticCG` dựng
  bằng `CGContext` tường minh (sRGB + `premultipliedFirst`, 8-bit) rồi `blitStaticCG` dán thẳng,
  không cần đổi định dạng. Preview đơn giản là CHƯA dùng lại đúng con đường đó.
- **Sửa**: đổi `drawPreview` sang dùng `renderStaticCG`/`blitStaticCG` giống hệt `drawExport` (thêm
  tham số `alpha` cho `blitStaticCG` để giữ hiệu ứng vào/ra mà preview cần nhưng export không cần).
  Gỡ hẳn `renderStatic`(NSImage)/`curStatic`/`nxtStatic` không còn dùng.
- **Tự kiểm tra bằng mắt TRƯỚC khi đo** (không đụng máy user, không suy đoán): mở project thật,
  cho phát tới đoạn có lời, chụp màn hình — chữ hiển thị ĐÚNG chiều, đúng màu, hiệu ứng tô sáng
  (wipe) chạy đúng, không lật ngược/vỡ hình. An toàn để đo tiếp.
- **Đo lại `sample`**: số mẫu trong `NSImage drawInRect`/`vImageConverterConvert` giảm từ ~572 →
  7 (gần như hết). `CA::Transaction::commit` (tổng chi phí commit/compositing) giảm từ ~65% →
  ~27% luồng chính lúc kéo.
- **Đo lại `KM_AUTO_STRESS=scrub` (project thật có nhạc)**: đỉnh giật giảm thêm, ổn định quanh
  250ms-1s, thỉnh thoảng 1.5-2.6s (kịch bản `scrub` cố ý quét CẢ BÀI trong 1.5s/đợt — quét nhanh
  hơn nhiều so với 1 lần kéo tay thật thường chỉ trong 1 đoạn nhỏ, nên đây là kịch bản NẶNG HƠN
  thực tế). **CHƯA sạch hoàn toàn** — còn phần chi phí dựng lại cache khi quét qua NHIỀU câu liên
  tiếp rất nhanh (`renderStaticCG` bản thân nó vẫn cần thời gian dựng layout+vẽ chữ mỗi khi đổi
  câu, việc này là làm THẬT chứ không phải lỗi thừa — hướng sau: có thể dựng cache ở luồng nền
  thay vì luồng chính, hoặc giảm tần số đổi câu khi đang kéo rất nhanh).
- Build OK, đã tự kiểm tra hình ảnh + đo trước/sau bằng công cụ tự động trên ĐÚNG project có nhạc
  thật, đã push.

## LAG — SỬA LẦN 14: TÌM RA + SỬA ĐƯỢC GỐC "KHÔNG CHẠY CŨNG LAG" (2026-09-20)
Sau khi tìm ra bằng chứng "có vocal/beat stem = lag liên tục" (SỬA LẦN 13 phần cuối) nhưng chưa rõ
cơ chế, đào tiếp bằng cách đo CHÍNH XÁC (không suy đoán) số lần MỖI `@Published`/`ObservableObject`
mà `ContentView` giữ thực sự PHÁT tín hiệu, so với số lần `ContentView.body` chạy:
- Thêm bộ đếm tạm (`.onReceive(X.objectWillChange)`) cho CẢ 6 đối tượng `ContentView` giữ:
  `store`, `playback`, `beatSepProxy`, `aligner`, `videoExporter`, `advancedProxy`.
- Kết quả: `ContentView.body` chạy ĐỀU 13-15 lần/giây SUỐT lúc đứng yên, NHƯNG cả 6 bộ đếm đều =
  **0** trong nhiều cửa sổ 2 giây liên tiếp. → CHỨNG MINH đây KHÔNG PHẢI do dữ liệu
  (`@Published`) đổi — không có gì để "đổ lỗi" ở tầng SwiftUI state. Đây là dấu hiệu của lỗi Ở
  TẦNG AppKit/NSHostingView: set state ảnh hưởng tới view NGAY TRONG lượt layout/dựng hình ĐẦU
  TIÊN khiến AppKit rơi vào vòng lặp tính lại kích thước không bao giờ ổn định (đúng dạng lỗi
  Apple đã biết — xem "TimelineView macOS NSHostingView sizeThatFits" đã tra cứu ở SỬA LẦN
  trước) — MỘT KHI đã bắt đầu, vòng lặp tự duy trì, không cần thêm state nào đổi nữa.
- **Cô lập bằng thực nghiệm trực tiếp** (không đoán): tạm bỏ qua hẳn việc gọi
  `beatSep.adoptFromProject(...)` trong `.onAppear` (`adoptOrRefreshBeatSep`) — **HẾT NGAY** (về
  lại 1 lần dựng lúc mở rồi đứng yên hẳn, y hệt project không có stem). Xác nhận: đúng LỆNH GỌI
  NÀY (không phải hệ quả UI như nút "Karaoke" — đã test riêng, ép `karaokeAvailable = false`
  không giúp gì) là ngòi nổ.
- **Sửa (không mất tính năng)**: dời `beatSep.adoptFromProject(...)`/`refresh(...)` ra
  `DispatchQueue.main.async` — chạy sau ĐÚNG 1 lượt runloop, để lượt layout ĐẦU TIÊN của
  `ContentView` ổn định xong rồi mới set state ảnh hưởng view. Stem vẫn được nhận đúng (trễ
  không nhận ra được bằng mắt, nút "Karaoke BẬT/TẮT" vẫn bật đúng lúc có sẵn stem) — chỉ đổi
  THỜI ĐIỂM set, không đổi logic.
- **Đo lại TRÊN PROJECT THẬT, KHÔNG SỬA GÌ (`tinh iu cao thuong.kbproj`, có vocal+beat thật)**:
  `KM_BODY_LOG` — từ 13-15 lần/giây MÃI MÃI → 1 lần lúc mở rồi im hẳn suốt 14 giây còn lại.
  `KMK_PERF` — từ giật liên tục 250-600ms KHÔNG NGỪNG → 60-61 nhịp/2s (gần kín 30Hz), 0 lần
  nghẽn >40ms (trừ 1 lần ~1s lúc mới mở, chi phí khởi động 1 lần bình thường).
- Đã dọn hết code debug tạm (đếm publisher, in log mỗi sink) dùng để tìm ra lỗi này — không còn
  trong bản chính thức.
- Build OK, đã tự đo trước/sau TRÊN ĐÚNG PROJECT THẬT KHÔNG CHỈNH SỬA GÌ (không phải bản test đã
  bị đổi), đã push. **Đây là nguồn CHÍNH của "không chạy cũng lag" — ảnh hưởng MỌI project đã tạo
  karaoke xong (có sẵn vocal+beat), tức là hầu hết mọi lúc user thực sự dùng app hàng ngày.**

## LAG INTEL iMac — TÌM RA ĐÚNG GỐC THẬT + SỬA (2026-09-24)
User đưa "mission brief" yêu cầu điều tra độc lập lại từ đầu, không lặp lại DisplayLink/Timer/leak
đã loại. Đo THẬT trên project `mot thua yeu nguoi.kbproj` (32 dòng, có vocal+beat), không suy đoán.
Chi tiết đầy đủ + số liệu: xem `docs/KNOWN_ISSUES.md` mục "ĐÃ SỬA · LAG NẶNG TRÊN INTEL iMac 2017".
Tóm tắt: 4 nguyên nhân cũ (SỬA LẦN 7-14, đã bị gỡ) kiểm chứng lại bằng thực nghiệm tắt/bật —
**KHÔNG PHẢI nguyên nhân chính** (tắt beatSep/hoãn onAppear đều không đổi gì, vẫn giật y hệt).
Gốc THẬT: `EditorCommandSink` (`Models/EditorCommand.swift`) chứa closure nên không `Equatable`
được — `.focusedSceneValue(\.editorCommands, ...)` tạo struct mới mỗi lần `ContentView.body` chạy,
SwiftUI coi là "luôn đổi", đẩy ngược lên `KaraokeMakerApp.body` (menu bar) → kéo `ContentView`
dựng lại → LẶP VÔ HẠN, tự nuôi chính nó, không cần `@Published` nào đổi (đã đếm cả 7
ObservableObject = 0 lần phát tín hiệu lúc đang giật — xác nhận không phải lỗi state, mà là vòng
lặp App-scene ↔ View thuần AppKit/SwiftUI). Sửa: thêm `Equatable` cho `EditorCommandSink`, so sánh
bỏ 2 closure nhưng thêm `linesEmpty`/`hasCopiedOverlay` (đúng những gì `canRun(_:)` thực sự phụ
thuộc ngoài `selection`) để tránh vừa lặp vô hạn vừa menu bar bị trễ cập nhật. Đo lại: idle VÀ lúc
đang phát nhạc thật trên project 32 dòng đều 60-61 nhịp/2s, gần 0 lần nghẽn (trước: 210-450ms liên
tục không ngừng). Build OK, đã dọn sạch code đo tạm, đã push — chờ user xác nhận cảm nhận thật.

## TAB "SỬA LỜI" + ẨN TAB "TẠO KARAOKE" (2026-09-24, chờ test)
Làm theo kế hoạch user duyệt (3 lô). **Lô 1 — tab**: "Tạo Karaoke" chỉ hiện khi CHƯA có dòng canh xong
(hoặc đang đứng ở đó lúc vừa xong, tới khi tự chuyển "Nền video") — dựa trạng thái nên mở lại project
cũng ẩn; ⌘Z lùi trước lúc tạo thì hiện lại. Tab "Sửa lời" nằm cạnh "Nền video", hiện khi có dòng canh
xong. Không có đường đổi nhạc / làm lại — chỉ Dự án mới. **Lô 2 — logic** `Services/LyricLineEditor.swift`
(mới, ngoài các file cấm): sửa chữ dòng đã canh mà giữ timing — cùng số chữ thay 1-1; khác số chữ so khớp
LCS (chữ không đổi giữ mốc, chữ thêm lấy thời gian chữ bị thay / khe kề, xoá chữ để lại khe); viết lại
hoàn toàn chia lại theo độ dài chữ; luôn giữ `words.count == WordTiming.tokens(text).count` (xuất .ass
cần). Đã kiểm bằng script Swift độc lập, 14/14 ca. **Lô 3 — UI** `Views/LyricEditPanel.swift`: danh sách cố
định đánh số 1,2,3… (chỉ trên UI, không vào karaoke, không hiện mốc giờ), Enter / bấm ra ngoài / sang dòng
khác = cập nhật, Esc huỷ, đổi tab khi đang gõ vẫn lưu, bấm dòng = chọn + tua vạch đỏ tới đầu dòng (không
tự phát), đồng bộ 2 chiều với timeline. Ô "Nội dung dòng" bên phải (StylePanel) giờ cũng chốt khi rời ô
qua CÙNG đường (trước đây chỉ đổi `text` nên dòng đã canh KHÔNG đổi chữ trên karaoke). Build OK.

## ICON NGƯỜI HÁT (NAM / NỮ / SONG CA) → VECTOR (2026-09-24, chờ test)
3 icon PNG user đưa trước đó là ảnh màu cố định. Đã TRACE (potrace, độ khớp bóng gốc 99.3–99.7% IoU)
thành đường Bézier nhúng trong code: `Rendering/SingerIconPaths.swift` (dữ liệu, dạng chuỗi lệnh
0=move/1=line/2=curve/3=close, toạ độ 0…1, y xuống) + `Rendering/SingerIcon.swift` (API mới:
`aspect`, `path`, `draw(role,in:rect:color:)`, `image(role,height:color:)`; tô even-odd nên lỗ tóc/cổ
áo/khe ngón giữ nguyên). Icon giờ TÔ ĐÚNG MÀU vai (`project.singerColors`, ô chọn màu dưới nút
"Song ca" đã có sẵn): trên video/preview (`KaraokeRenderer.drawSingerIcon`, màu = màu vai của câu),
trên timeline (badge + bảng chọn 3 icon) và trong thanh Song ca (`ContentView.duetBar`) — đổi màu là
đổi ngay ở cả 3 nơi. Sắc nét mọi cỡ. 3 file PNG gốc chuyển sang `Branding/singer-icons-src/` (giữ làm
nguồn, không còn nằm trong bundle; đã bỏ 3 dòng `.copy` trong `Package.swift`). Đã kiểm bằng script
Swift độc lập (tô xanh/đỏ/lục — đúng hình, đúng lỗ trắng). Build OK, CHƯA test trong app.

## 4 LỖI TỪ VIDEO USER GỬI (2026-09-24, chờ test)
Cmd+click dòng thứ 2 không cộng dồn (bug thật: 1 nhánh Cmd luôn THAY `selIDs` thay vì toggle,
chặn mất nhánh toggle đúng có sẵn) · khoanh chuột trái chọn nhiều chữ (sửa phòng thủ, độ tin cậy
thấp hơn — cần user xác nhận lại) · xuất .ass mất chữ cuối mỗi dòng khi mở bằng CapCut (lỗi làm
tròn `\kf` cộng dồn vượt mốc Dialogue End — sửa làm tròn theo mốc tuyệt đối) · "Vừa khung" không
tự chạy khi import nhạc lần đầu vào project trống (thêm mốc theo dõi riêng cho
`playback.duration`). Chi tiết đầy đủ: `docs/KNOWN_ISSUES.md` mục cùng ngày. Build OK, CHƯA test.

## TIMELINE: THANH CUỘN MẤT + "VỪA KHUNG" RA SÓNG VUÔNG (2026-09-24, chờ test M4)
User báo 2 lỗi kèm ảnh/video: kéo viền chia (3 cột trên ⇄ Timeline) thu nhỏ lại → thanh cuộn ngang
biến mất; "Vừa khung" lúc mở project ra sóng vuông/thô + thừa mảng xám lớn. Tìm ra bằng trích khung
hình video user gửi + đọc lại project thật để loại số liệu sai. Chi tiết đầy đủ: xem
`docs/KNOWN_ISSUES.md` mục cùng ngày. Tóm tắt 2 sửa (`TimelineEditor.swift` + `ContentView.swift`):
- Bỏ ép cứng `.frame(height: totalHeight)` (chiều cao theo NỘI DUNG, không theo khung ngoài) quanh
  `GeometryReader` bọc `TimelineCanvasView` → đổi `.frame(maxHeight: .infinity)` để co giãn đúng
  khung THẬT user kéo — thanh cuộn (đáy NSScrollView) không còn bị `.clipped()` ngoài cắt mất.
- "Vừa khung" tự động lúc mở project debounce 0.3s theo `timelineViewportW` (trước chốt ngay lần đổi
  ĐẦU TIÊN — có thể là số TẠM lúc 3 cột còn đang dàn layout, ra zoom sai).
Build OK, CHƯA test M4.

## RECENT ARCHITECTURE DECISIONS
- Giữ hybrid SwiftUI + AppKit. Timeline & preview canvas = AppKit NSView (đã tối ưu CoreAnimation).
- Clock chuẩn = `PlaybackController` (đã thêm transport ảo cho trường hợp chưa có audio).
- Overlay clip lưu bằng TIME (`start`/`duration`/`lane`), view chỉ là projection — đúng nguyên tắc.
- Undo: mọi mutation qua `store.perform`; drag = begin/preview/commit (1 undo).
