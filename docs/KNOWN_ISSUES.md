## WHISPER LỜI HÁT (lab 2026-09-26): giúp giảm lỗi rõ nhưng (1) giấy phép thương mại chưa rõ (huấn luyện trên nhạc Zing MP3), (2) đã "học thuộc"
lời một số bài phổ biến (bài có trong danh sách huấn luyện của nó đạt ~1,6 % lỗi), (3) nặng thêm 3,2 GB + ~2 lượt nghe. Chưa đưa vào app.

## RERANKER (lab, 2026-09-26): lab đạt ~8,8% lỗi thật nhưng CHƯA vào app; cần thêm ~1 lượt nhận dạng 1.7B + chấm câu (M4 +~50 s/bài, Intel +~7 phút/bài).

## ĐỘ CHÍNH XÁC LỜI "KHÔNG CẦN LỜI" (đo 2026-09-25, 21 bài, chia DEV/TEST theo bài) — CHƯA ĐẠT MỤC TIÊU
- Production hiện tại sai ~22–25% từ (thô) / ~15% (LOCAL, bỏ khối lệch cấu trúc lời mẫu) trên bài mới. Lỗi chính: sai dấu (sắc/huyền↔ngang),
  từ gần âm, phụ âm miền Nam (ch/tr, s/x, d/gi/r, au/ao, n/ng), và CẢ HAI mô hình cùng nghe sai (~30% lỗi).
- Thiết kế "0.6B chính" là sai trên bài mới (1.7B tốt hơn rõ) — sửa rẻ nhất (không tốn thêm thời gian) nhưng CHƯA áp vào app (chờ user đồng ý).
- Cờ "chưa chắc" bắt được ~50% lỗi; nhiều lỗi mô hình rất tự tin → người dùng không thấy.
- Lời mẫu trong project user KHÔNG đáng tin tuyệt đối (thiếu/thừa câu, điệp khúc sai chỗ; bài `vong_tay` thiếu hơn nửa lời) → cần bộ lời đã NGHE LẠI để đo chuẩn và để huấn luyện.
- Chi tiết + số liệu: `~/viet_lyrics_lab/` (README, FINETUNE_PLAN.md, analysis/out/*.json).

## TẠO KARAOKE 2 ĐƯỜNG + ĐÓNG GÓI TỰ CHỨA (2026-09-25 đêm) — GIỚI HẠN ĐÃ BIẾT
- **Tách nhạc chạy 2 lần** ở đường "Không cần lời": 1 lần ở bước "Phân tích nhạc" (cấp bản giọng để dò đoạn có giọng cho ASR), 1 lần nữa BÊN TRONG `AdvancedKaraoke.run` (nó tự tách tươi). Lý do: `BeatSeparation`/`AdvancedKaraoke` là file cấm. Ý tưởng (KHÔNG code): cho `run` nhận stem có sẵn để bỏ lần 2. Tốn ~20 s (clip 31 s) tới ~1–2 phút (bài 267 s trên Intel).
- Bước "Phân tích nhạc" và bước canh giờ sẵn có KHÔNG dừng giữa chừng được → Huỷ chỉ BỎ kết quả (chúng tự chạy nốt ngầm, đã kiểm: kết quả về muộn không được áp, luồng không sống lại).
- Từ chưa chắc chỉ nằm trong bộ nhớ (không lưu vào `.kbproj`): đóng/mở lại project thì mất danh sách gợi ý (lời + timing vẫn còn).
- Khi project đã có lời/karaoke, tab "Tạo Karaoke" ẩn (hành vi có sẵn) → muốn chạy lại "Không cần lời" phải xoá lời / tạo project mới.
- **Dung lượng**: gói x86_64 8,0 GB, arm64 7,9 GB (2 mô hình Qwen 6,3 GB là phần chính; luật dự án cấm lượng tử hoá/đổi mô hình). Là 2 bản RIÊNG theo kiến trúc.
- **Lần mở đầu tiên** của 1 bản chép mới rất chậm: đo trên iMac 58 s (lần sau 0,5 s). Nghi macOS quét gói 8 GB lần đầu (CHƯA xác định chắc). Khi có quarantine + notarization dự kiến còn hộp "Verifying…" lâu hơn → cần cân nhắc khi bán (vd tải mô hình lần đầu / cài đặt vào Application Support).
- **Ký Developer ID sau này**: ~250 file Mach-O trong `Contents/Resources/AutoLyricsRuntime` phải ký RIÊNG từng file (Resources không nằm trong `--deep`); Python/PyTorch có thể cần entitlement (`allow-unsigned-executable-memory`, `disable-library-validation`) — dự đoán, CHƯA thử.
- Intel (CPU fp32) và M4 (MPS bf16) lệch vài từ: song1 đầy đủ qua app — Intel WER 7,0%, M4 6,4%; clip 31 s cho lời giống hệt nhau.
- Timing của engine sẵn có lệch chút giữa Intel và M4 (vd dòng đầu clip: 0,30–6,52 s trên Intel, 0,30–5,90 s trên M4 — cùng lời, cùng đường thủ công) — do số học ONNX/tách giọng khác kiến trúc, không phải do luồng mới.
- Kiểm thử "máy sạch + offline" là MÔ PHỎNG (env -i, ẩn thư mục dev, sandbox-exec chặn mạng IP), KHÔNG phải một máy Mac khác thật; M4 chạy app bằng exec trực tiếp dưới sandbox-exec.
- **M4 — 1 lần app biến mất + phân tích rất chậm (CHƯA rõ nguyên nhân)**: trong chuỗi test tự động, đúng lúc phân tích bài 267 s (bước tách nhạc CoreML sẵn có, file cấm), app bản THỬ tự thoát ở ~57 s (log hệ thống chỉ ghi "QUITTING", KHÔNG có báo cáo crash/jetsam; cùng thời điểm Spotlight `mds/mdworker` đang quét các bản chép 8 GB mới tạo). Chạy lại: 2 lần thành công nhưng thời gian phân tích của CÙNG bài chênh nhau rất lớn (42 s vs 554 s); 4 lần lặp thêm (150 s mỗi lần) app không biến mất. Chưa thể kết luận đây là lỗi của luồng mới hay của bước tách nhạc/CoreML/áp lực bộ nhớ (M4 16 GB, nhiều app khác đang mở). THEO DÕI khi có máy khách chạy bài dài.
- **Lần mở đầu tiên trên máy có "Gần đây"**: bản đóng gói mở bằng `open` bị chặn bởi hộp thoại quyền macOS (Desktop) vì danh sách "Gần đây" trong prefs của máy dev có dự án nằm trên Desktop (`HomeView.reload` → `ProjectLibrary.listAll` → `open()` chờ TCC). Máy khách mới (danh sách trống) sẽ không gặp ngay; khi mở dự án từ Desktop/Documents mới hiện hộp thoại chuẩn của macOS. Có thể thêm `NS*FolderUsageDescription` vào Info.plist cho dễ hiểu (chưa làm).
- Không chụp được khung xem trước (preview) bằng bộ điều khiển GUI (ảnh chụp view luôn đen với cả 2 đường) — đã xác nhận phát nhạc chạy (đồng hồ 0 → 3,6 s, Pause dừng đúng) nhưng chưa nhìn tận mắt chữ chạy trong preview ở ảnh chụp.
- Cmd+Q lúc đang chạy: xác nhận bằng Apple Event quit — app + helper dừng < 1 s; thư mục tạm job nay được xoá ngay lúc thoát.
- Đã xác nhận bằng GUI: bấm phương án cho từ chưa chắc (thay chữ, giữ cửa sổ thời gian), bật Karaoke(beat) vẫn đưa audio GỐC cho ASR.
- `LocalAligner.read16kMono` (bộ canh giờ sẵn có) dùng `AVAudioConverter` → có thể chỉ lấy kênh TRÁI khi đổi mono. KHÔNG sửa (file cấm) — chỉ ghi lại.

## TỰ ĐỘNG LẤY LỜI (thử nghiệm, 2026-09-24) — GIỚI HẠN ĐÃ BIẾT
- Mới kiểm chứng trên 2 bài ballad tiếng Việt; chưa thử rap/nhạc ồn/nhiều giọng/ngôn ngữ khác.
- Vẫn còn từ nghe SAI mà cả 2 mô hình đồng ý (vd "chi"→"chỉ", "kề"→"kể", "cám"→"cảm") — không nguồn bằng chứng nào sửa được; được đánh dấu chỉ khi có bất đồng.
- Từ chỉ 1.7B nghe thấy: giữ như ứng viên chưa chắc (chỉ khi vùng VOCAL + hàng xóm khớp mạnh, không ở mép chunk). Từ ở mép chunk vẫn có thể bị bỏ.
- Context rerun từng gây hại 1 ca → giờ chỉ dùng cho đoạn đã UNCERTAIN, không ghi đè đoạn đã chắc; vẫn là rủi ro nếu context lệch.
- Ngắt dòng bản nháp là ƯỚC LƯỢNG (dấu câu ASR + khoảng lặng giọng hát; ~50% khớp dòng gốc) — user sửa dòng trước khi "Tạo Karaoke".
- Thiếu bản tách giọng → phải chạy "Phân tích nhạc" (bước tách sẵn có) trước; không có đường dự phòng chưa kiểm chứng.
- Runtime (Python + qwen-asr + model 0.6B/1.7B ≈ 6 GB) CHƯA đóng gói; đang dò thư mục thử nghiệm sẵn có. Intel: cả bài ~7–9 phút (đo thật ở báo cáo tích hợp).
- Chưa có UI bấm từ chưa chắc để chọn phương án (chỉ danh sách xem). Bản nháp chỉ tạm trong bộ nhớ.

## ĐÃ SỬA (chờ test) · 4 LỖI TỪ VIDEO USER GỬI: KHOANH VÙNG CHỌN CHỮ, CMD+CLICK DÒNG, XUẤT .ASS MẤT CHỮ CUỐI, VỪA KHUNG LÚC IMPORT NHẠC (2026-09-24)
Trích khung hình từ video quay màn hình user gửi (`Recording at 2026-09-24 13.12.57.mp4`) để soi
chính xác pixel — không suy đoán. Tìm ra + sửa 4 lỗi:

1. **Cmd+click dòng thứ 2 không cộng dồn vào nhóm chọn nhiều dòng** (`TimelineEditor.swift`,
   nhánh `if cmd {...}` trong `mouseDown`): có sẵn 1 nhánh xử lý ĐÚNG việc cộng dồn
   (`case .blockBody` ở switch chung bên dưới, `if cmd||shift { selIDs.insert/remove }`) —
   nhưng nhánh Cmd RIÊNG phía trên (`if let target = firstHit.lineIdx`) LUÔN chặn trước và làm
   `selIDs = [lines[target].id]` (THAY HẲN thành 1 dòng), nên nhánh đúng không bao giờ chạy tới.
   Xác nhận qua khung hình: Cmd+click dòng 2 làm dòng 1 MẤT border chọn (đổi từ "chọn+active,
   chữ hiện dạng ô" sang "không chọn, chữ hiện dạng chữ thường có gạch chia"), đúng kiểu THAY chứ
   không CỘNG. Sửa: nhánh đó giờ TOGGLE `selIDs` (insert/remove) y hệt cách lớp đè hoạt động,
   chỉ còn giữ hành vi cũ (activate cục bộ cho Cmd+click 1 CHỮ) khi dòng ĐÃ active sẵn.
2. **Khoanh vùng chuột trái (không Cmd) chọn nhiều chữ** — quan sát khung hình: đã đúng là
   `wordMarqueeRect` (không phải marquee DÒNG) tăng dần đúng chỗ nhưng KHÔNG chữ nào hiện viền
   trắng "đã chọn". Không tìm được bug cụ thể trong phép giao `CGRect.intersects` (đọc lại nhiều
   lần, logic đúng) — nghi vấn hàng đầu: điểm bấm xuống rơi ra ngoài dung sai Y hẹp (16px) của
   khối dòng đang active (54px cao, hàng chữ chiếm gần hết, dễ trật), rơi về nhánh
   marquee-DÒNG (trông giống hệt vì DÙNG CHUNG code vẽ hình chữ nhật) — không đổi gì thấy được
   vì marquee-dòng chỉ có 1 dòng, không giao dòng nào khác. **Sửa PHÒNG THỦ 2 lớp** (chưa chắc
   trúng gốc thật, cần user test lại xác nhận): (a) nới dung sai nhánh chính 16→50px; (b) thêm
   hẳn 1 lưới an toàn giống hệt ở `case .none:` (nhánh rơi-về-marquee-dòng) — thử lại 1 lần nữa
   với dung sai rộng trước khi coi là marquee dòng/tua. Nếu user test vẫn còn lỗi → cần thêm log
   tạm (`NSLog`) để bắt đúng toạ độ thật lúc bấm, không đoán tiếp bằng mắt qua video nữa.
3. **Xuất .ass: CapCut mất đúng chữ cuối mỗi dòng** (app khác/preview trong app vẫn hiện đủ) —
   `AssExporter.karaokeText`: mỗi tag `\kf` làm tròn xen-ti-giây RIÊNG LẺ rồi cộng dồn
   (`cursor += dur/100.0`), sai số làm tròn dồn qua nhiều chữ có thể khiến TỔNG vượt quá mốc kết
   thúc Dialogue đã khai (`assTime(e)`, làm tròn theo đường khác hẳn) — app này/VLC hiển thị dư
   ra sau khi hết giờ dòng nên không thấy gì lạ, CapCut tính chặt hơn nên cắt bỏ phần vượt (rơi
   đúng chữ cuối, nơi lỗi dồn nhiều nhất). Sửa: đổi hẳn sang làm tròn theo MỐC TUYỆT ĐỐI (cùng
   cách `assTime()` làm tròn `s`/`e`) rồi lấy HIỆU 2 mốc liền nhau ra thời lượng từng đoạn — tổng
   luôn khớp CHÍNH XÁC khoảng đã khai, không bao giờ vượt.
4. **"Vừa khung" không tự chạy khi import nhạc lần đầu vào project TRỐNG** — cơ chế tự "Vừa
   khung" (thêm hôm nay, mục dưới) chỉ theo dõi `timelineViewportW` đổi — với project MỚI/TRỐNG,
   bề rộng khung đã "chốt" (dùng 1 lần) ngay lúc mở, TRƯỚC KHI có nhạc, nên lúc audio thật import
   vào (đổi `playback.duration` từ 0 → có giá trị) không còn gì gọi lại "Vừa khung" nữa. Thêm mốc
   theo dõi riêng cho `playback.duration` (debounce y hệt), độc lập với mốc bề rộng — cái nào tới
   sau tự sửa lại đúng vì `timelineFitToWindow()` luôn tính lại từ số MỚI NHẤT.

5. **Kéo NHIỀU DÒNG cùng lúc bị mất nhóm** (user báo sau khi Cmd+click cộng dồn đã chạy): `mouseDown`
   `case .blockBody` với bấm THƯỜNG luôn `selIDs = [id]` → nhóm bị thu về 1 dòng TRƯỚC khi kéo,
   dù `promote` đã sẵn logic kéo cả nhóm. Sửa: bấm thường vào dòng ĐANG trong nhóm (>1) thì GIỮ
   nhóm (`dragKeptLineGroup`); `mouseUp` mà không kéo (`.pending`) mới thu về đúng dòng đó.

   **Lần 2 (user báo vẫn lỗi)**: dòng ACTIVE (Cmd+click cuối) là dòng tách thanh mảnh + hàng ô
   chữ, gần hết chiều cao là hàng chữ → bấm vào đó rơi nhánh `.wordBody` làm `selIDs = [1 dòng]`.
   Giờ: đang chọn >1 dòng + bấm THÂN ô chữ của dòng trong nhóm → coi là kéo NHÓM DÒNG. Đồng thời
   2 nhánh khoanh-chọn-chữ chỉ chạy khi `selIDs.count <= 1` (không cướp click lúc có nhóm dòng).

Cả 4 build OK (`swift build -c release`), CHƯA test thật. Riêng mục 2 (khoanh chữ) độ tin cậy THẤP
NHẤT trong 4 — cần user xác nhận rõ ràng, nếu vẫn lỗi thì bước tiếp theo là thêm log tạm thay vì
sửa mù thêm lần nữa.

## ĐÃ SỬA (chờ test M4) · "VỪA KHUNG" RA SÓNG VUÔNG + THỪA MẢNG XÁM, THANH CUỘN NGANG BIẾN MẤT KHI KÉO VIỀN CHIA (2026-09-24)
2 lỗi user báo cùng lúc kèm video/ảnh, cả 2 đều nằm ở `TimelineEditor.swift` (khung bọc ngoài
`TimelineCanvasView`), tìm ra bằng cách trích khung hình từ video quay màn hình user gửi + đọc lại
project thật (`tinh iu cao thuong.kbproj`: 293s nhạc, 49 dòng, dòng cuối kết thúc 267.6s) để loại trừ
khả năng lệch số liệu.

- **Thanh cuộn ngang biến mất khi kéo viền chia (giữa 3 cột trên và khung Timeline) thu nhỏ lại**:
  `TimelineEditor.body` bọc `TimelineCanvasView` trong `GeometryReader` rồi ép CỨNG
  `.frame(height: totalHeight)` — `totalHeight` là chiều cao tính theo NỘI DUNG (số làn lớp đè…),
  KHÔNG liên quan khung ngoài user kéo to/nhỏ. Kéo khung Timeline nhỏ hơn `totalHeight` → bên trong
  vẫn đòi đúng `totalHeight`, phần dư (gồm cả thanh cuộn nằm ở đáy) bị `.clipped()` bên ContentView
  cắt mất. Thử sửa `autohidesScrollers = false` (SỬA LẦN trước) KHÔNG đủ — xác nhận qua so khung hình
  video trước/sau khi kéo, thanh cuộn vẫn biến mất hoàn toàn.
  **Sửa**: đổi `.frame(height: totalHeight)` → `.frame(maxHeight: .infinity)` — để co giãn đúng theo
  khung THẬT được cấp (đã có `minHeight: 300` chặn dưới từ `ContentView.mainLayout`), NSScrollView tự
  đủ chỗ/cắt bên trong chính nó, thanh cuộn luôn nằm trong khung nhìn thấy được.
- **"Vừa khung" ra sóng vuông/thô + thừa mảng xám lớn sau vạch ruler ~240**: `timelineFitToWindow()`
  tự chạy 1 lần khi `timelineViewportW` đổi khỏi giá trị mặc định 800 (`ContentView.onChange`) —
  nhưng lúc mới mở project, `timelineViewportW` (từ `geo.size.width` của GeometryReader) có thể đổi
  NHIỀU LẦN liên tiếp trong lúc panel 3 cột còn đang dàn layout, và lần ĐỔI ĐẦU TIÊN có thể đang là số
  TẠM (nhỏ hơn thật). Chốt "Vừa khung" ngay ở lần đổi đầu → `timelineZoom` tính theo `(vw-6)/dur` ra
  quá thấp (chạm sàn 1.5, khớp sóng bị vuông) — rồi khung nhìn THẬT (rộng hơn) thừa cả mảng xám.
  **Sửa**: debounce — mỗi lần `timelineViewportW` đổi, dời việc chốt "Vừa khung" ra sau 0.3s; nếu
  trong lúc chờ có thêm thay đổi khác thì huỷ lần chờ cũ, đợi tiếp — chỉ thực sự "Vừa khung" khi bề
  rộng đã ĐỨNG YÊN, dùng đúng con số cuối cùng.

Cả 2 build OK (`swift build -c release`, chỉ warning cũ không liên quan). CHƯA test M4.

## ĐÃ SỬA · LAG NẶNG TRÊN INTEL iMac 2017 — GỐC THẬT LÀ `EditorCommandSink` KHÔNG EQUATABLE (2026-09-24)
User đưa 1 "mission brief" chi tiết yêu cầu điều tra độc lập lại lag Intel từ đầu (không lặp lại
DisplayLink/Timer/memory leak đã loại trừ trước đó). Điều tra bằng đo THẬT trên chính máy iMac Intel
(project thật `mot thua yeu nguoi.kbproj` — 267s nhạc, 32 dòng, có vocal+beat stem), KHÔNG suy đoán:

- **Đo lại TOÀN BỘ 4 thủ phạm cũ trong lịch sử (SỬA LẦN 7-14, xem mục "ĐÃ GỠ HẾT" bên dưới)**: cả 4
  ĐỀU VẪN Ở TRẠNG THÁI CŨ (đúng như đã gỡ) — `adoptOrRefreshBeatSep` đồng bộ, `bumpSeek` không
  throttle, preview vẫn `NSImage`/`lockFocus`, `currentLineIndex` vẫn `@State` trần.
- **Đo idle THẬT bằng bộ đếm `ContentView.body` tự viết**: dựng lại LIÊN TỤC 37-38 lần/giây dù đứng
  yên tuyệt đối. `PerfMonitor`: nghẽn luồng chính 210-250ms KHÔNG NGỪNG (lúc phát nhạc: 440-453ms).
- **`sample` (profiler hệ thống)**: ~29% mẫu luồng chính (lúc HOÀN TOÀN RẢNH) nằm trong chuỗi
  `CATransaction commit → NSWindow layoutIfNeeded → NSPerformVisuallyAtomicChange` (lồng 4-5 lớp) →
  SwiftUI AttributeGraph — đúng dạng "AppKit tự quay vòng tính lại layout" đã biết, NHƯNG…
- **Thực nghiệm A/B kiểm chứng nhân quả (KHÔNG suy đoán, tắt/hoãn từng nghi phạm rồi đo lại)**:
  - Tắt hẳn `beatSep.adoptFromProject(...)` ("SỬA LẦN 14" cũ) → **KHÔNG đổi gì**, vẫn giật y hệt.
  - Hoãn TOÀN BỘ `.onAppear` ra sau 1 nhịp runloop → **KHÔNG đổi gì**, vẫn giật y hệt.
  - **Tắt hẳn `.focusedSceneValue(\.editorCommands, EditorCommandSink(...))` → SẠCH TUYỆT ĐỐI NGAY
    LẬP TỨC** (60-61 nhịp/2s, 0 lần nghẽn, đỉnh 34ms — kể cả lúc đang phát nhạc thật).
  - Đếm trực tiếp `objectWillChange` của cả 7 `ObservableObject` `ContentView` giữ → **0 lần phát
    tín hiệu** suốt nhiều cửa sổ 2 giây liên tiếp lúc đang giật → chứng minh không phải do
    `@Published` nào đổi, đây là vòng lặp THUẦN AppKit/SwiftUI-scene, không liên quan dữ liệu.
- **Gốc**: `EditorCommandSink` (`Models/EditorCommand.swift`) chứa 2 closure (`run`, `canRun`) nên
  KHÔNG thể `Equatable`. `ContentView.body` chạy lại (dù không đổi gì) → tạo struct MỚI (closure
  mới = identity mới) → gán qua `.focusedSceneValue` → SwiftUI không so sánh được, LUÔN coi là "đã
  đổi" → đẩy ngược lên `KaraokeMakerApp.body` (cấp App, dựng lại menu bar `.commands`) → kéo
  `ContentView` dựng lại → tạo `EditorCommandSink` mới → LẶP VÔ HẠN, tự nuôi chính nó không cần
  thêm dữ liệu nào đổi. Trên M4 vòng lặp này đủ nhanh để lọt trong 16ms/khung nên không thấy giật;
  trên Intel i7-7700K (2017) mất 210-250ms/lần → giật rõ rệt, cộng dồn nặng hơn lúc đang phát nhạc.
- **Sửa** (không xoá tính năng — menu bar Sửa/Xoá/Copy/Dán vẫn cần cầu nối này): thêm `Equatable`
  cho `EditorCommandSink`, SO SÁNH bỏ qua 2 closure (hành vi luôn giống nhau) nhưng thêm 2 trường
  CHỈ-ĐỂ-SO-SÁNH phản ánh ĐÚNG những gì `ContentView.canRun(_:)` thực sự phụ thuộc NGOÀI
  `selection` (`store.project.lines.isEmpty`, `copiedOverlay != nil`) — so sánh ĐỦ để tránh vừa lặp
  vô hạn vừa menu bar bị "trễ" (không so `selection` không thôi vì `canRun` còn đọc 2 thứ kia).
- **Đo lại SAU khi sửa (bản build thật, không phải thực nghiệm tắt tính năng)**: idle 60-61 nhịp/2s
  0 lần nghẽn; ĐANG PHÁT NHẠC THẬT trên project 32 dòng: 60-61 nhịp/2s, gần như 0 lần nghẽn (thỉnh
  thoảng 1 lần 40-80ms, bình thường) — mượt hoàn toàn, khác hẳn 440-453ms liên tục trước đó.
- Build OK, đã dọn sạch toàn bộ code đo tạm (không còn biến môi trường `KM_*` nào sau khi xong),
  chỉ giữ lại đúng 2 chỗ sửa (`EditorCommand.swift` + `ContentView.swift` nơi khởi tạo). Đã push,
  **CHỜ USER XÁC NHẬN TRÊN MÁY THẬT** (đo trên chính iMac Intel đang chạy Claude Code, nhưng vẫn
  cần user tự cảm nhận lúc dùng thật, đặc biệt lúc phát nhạc dài + tương tác timeline).
- **Bài học**: 4 nguyên nhân cũ (SỬA LẦN 7-14) là CÓ THẬT nhưng KHÔNG PHẢI nguyên nhân CHÍNH — đã
  kiểm chứng lại bằng thực nghiệm tắt/bật, không phải chỉ đọc lại doc cũ rồi tin theo. Nếu sau này
  lag quay lại, ĐỪNG quay lại sửa beatSep/onAppear trước — thứ TỰ ưu tiên đúng là kiểm tra bất kỳ
  giá trị nào đi qua `.focusedSceneValue`/`@FocusedValue`/`@SceneStorage` có chứa closure hoặc
  thiếu `Equatable` hay không trước, vì lớp lỗi này (App-scene ↔ View đẩy qua đẩy lại) không hề
  đụng tới `@Published`/DisplayLink/Timer nên các công cụ đo cũ (đếm publisher, đếm Timer) không tự
  lộ ra — phải cô lập bằng cách tắt/hoãn TỪNG NGHI PHẠM MỘT rồi đo lại mới thấy.

## ĐÃ SỬA · Xuất .ass bị thiếu vài từ mỗi dòng (2026-09-23)
User báo: file `.ass` xuất ra thỉnh thoảng thiếu vài từ mỗi dòng. Tìm ra 2 lỗi trong
`AssExporter.karaokeText` (file xuất, KHÔNG đụng thuật toán canh lời):
1. Nhánh dùng timing từng-chữ (`line.words`) lọc bằng `compactMap { guard start, end else nil }`
   — từ nào thiếu 1 trong 2 mốc (canh chưa xong hết, hoặc dở dang) bị ÂM THẦM bỏ qua, mất hẳn khỏi
   phụ đề dù dòng vẫn có timing hợp lệ.
2. `line.words` có thể CŨ hơn `line.text` — sửa lời tay ở danh sách dòng (`setLineText`) chỉ đổi
   `text`, không cập nhật `words[]` (mảng do thuật toán canh lời dựng). Gõ thêm chữ sau khi đã canh
   xong → file xuất vẫn dùng mảng từ CŨ, thiếu đúng phần vừa thêm.
Sửa: chỉ dùng nhánh timing từng-chữ khi (a) MỌI từ đều đủ cả 2 mốc, VÀ (b) số từ trong `words[]`
khớp đúng số từ tách được từ `text` hiện tại (phát hiện `words[]` bị lệch/cũ). Không khớp 1 trong 2
điều kiện → rơi về nhánh chia đều theo `text` hiện tại (đã có sẵn, dùng cho dòng không có
word-timing) — luôn đủ chữ, chỉ mất độ chính xác quét sáng `\kf` cho riêng dòng đó. Build OK.

# KNOWN ISSUES / ROOT PROBLEMS — 2026-09-06

## OPEN? · User báo KHÔNG CÓ TIẾNG khi bấm play (nhạc import hoặc kéo vào) — 2026-09-06
Nghi M-D slice 1 (`PlaybackController` playHi/playLo auto-pause + reseek). ĐÃ SỬA: toàn bộ logic
giới hạn vùng phát + auto-pause + reseek giờ CHỈ chạy khi `hasAudioTrim` (audioTrimStart/End > 0.05).
Bài KHÔNG cắt → hành vi y hệt trước M-D (`didFinishPlaying` lo điểm cuối). `effectiveVolume` hardened
`max(0,min(1,gain))`. Chờ user xác nhận. Nếu vẫn im: KHÁC nguyên nhân — hỏi user: vạch đỏ có chạy
không? có thanh lỗi đỏ? icon "Nhạc" trên timeline là 🔊 hay 🔇?

## ROOT-1 · Selection không có nguồn sự thật  — ĐÃ XỬ (M-A, 2026-09-06)
`EditorSelection` (computed trong ContentView) = nguồn ĐỌC duy nhất; `select(_:)` = 1 mutator.
Storage vẫn là `currentLineIndex` + `selectedOverlayID` (không đổi để tránh regression), nhưng
giờ có quan hệ chính thức. Canvas `selIDs/selWord/selOverlayID` vẫn là bản sao đồng bộ 1 chiều
qua `applyState` — chấp nhận (word-level là micro-op nội bộ canvas).

## ROOT-2 · Business logic rải trong View action  — ĐÃ XỬ (M-A + M-B, 2026-09-06)
`EditorCommand` + `ContentView.runCommand/canRun` = điểm vào chung. Phím tắt (`handleKeyDown`)
+ timeline toolbar (`run:`) + menu bar (`focusedSceneValue` → `editor?.run`) + context menu
(`TimelineCanvasView.menu(for:)`) đều đi qua 1 đường. Canvas keyDown word-ops (S/M/⌘C/⌘V/⌘D
trên `selWord`) cố ý GIỮ canvas-local (micro-op). Zoom chưa vào command (M-C).

## ROOT-3 · Công thức toạ độ timeline lặp lại  — XỬ MỘT PHẦN (M-C, 2026-09-06)
Zoom control (đang là phần "scattered" thật sự: `TimelineEditor.setZoom` + toolbar + canvas
`onZoom` + không có menu/shortcut) → đã gom: `pointsPerSecond` lift lên ContentView,
`EditorCommand.zoom*`, menu Xem ⌘=/⌘−/⌘0.
`x = t * pps` bên trong `TimelineCanvasView` KHÔNG rip thành `TimelineMetrics` struct — canvas
là 1 view, 1 `pps` stored, toạ độ đang ĐÚNG (playhead/drag/zoom verified). Rip 50+ call site
= rủi ro cao, lợi ít. Để nguyên; nếu sau này cần track-header width / nhiều timeline view thì
mới tách. Coi như CLOSED ở mức chấp nhận được.

## ~~OPEN · Overlay video luôn phát từ 0~~ — XONG (M-E, 2026-09-06)
`OverlayClip.trimStart` + `sourceDuration`. `vt = trimStart + (time - clip.start)`. Kéo mép trái
= dời trimStart. Preview + export + split đều theo.

## ~~OPEN · Cắt bài chưa vào XUẤT + chưa có fade~~ — XONG (M-D 1b, 2026-09-06)
`VideoFrameWriter.write(timeOffset:)` + `AudioMux.encodeAAC(start:maxLen:gain:fadeIn:fadeOut:)`
(AVMutableAudioMix). Không đụng aligner — chỉ render-time offset trong vòng xuất.

## ~~REGRESSION · Tiến trình "Tạo Karaoke" gộp 2 chặng thành 1~~ — XONG (2026-09-07)
User: trước hiện "Đang phân tích nhạc" → chữ xanh "xong" → rồi mới "Đang tạo karaoke". Bản gần đây
gộp thành 1 spinner "Đang tạo karaoke…". ĐÃ KHÔI PHỤC 2 chặng trong `ContentView.forcedAlignStep`
bằng helper `phaseRow` sẵn có: chặng 1 `advanced.phase == .separating` (%= `beatSep.localProgress`),
chặng 2 `rank 2…5` (%= `advanced.listenProgress`), xong mỗi chặng = tick xanh.
⚠️ CHỈ sửa phần HIỂN THỊ — KHÔNG đụng `AdvancedKaraoke` / `LocalAligner` / `BeatSeparation` / `ForcedAligner`.

## ~~REGRESSION · Xuất video trong suốt RẤT CHẬM~~ — XONG (2026-09-07)
User: 2K/30 trước < 1 phút, giờ 1080p/25 hơn 10 phút chưa xong. Nguyên nhân: đợt trước thêm codec
`AVVideoCodecType.hevcWithAlpha` + **đặt làm mặc định** (`ExportSettings.videoCodec = hevcAlpha`).
`hevcWithAlpha` mã hoá ~7–10 fps ở máy này (không có đường phần cứng + chạy x86_64 qua Rosetta trên M4),
chậm ~10× so với ProRes 4444 (intra-only, gần realtime). Đã GỠ HẲN: bỏ `TransparentVideoQuality`,
bỏ field `videoCodec`, bỏ nhánh HEVC + `alphaCodec` param trong `TransparentVideoExporter`, bỏ ô
"Chất lượng" trong tab Xuất. Video trong suốt = luôn `.mov` ProRes 4444 (như trước khi thêm HEVC).

## ~~OPEN · Preview overlay video giật (4fps)~~ — XONG (2026-09-07)
`OverlayVideoFrameStore` nâng lên grid 30fps + prefetch 12 khung + queue concurrent
`.userInitiated`, tolerance 1/60s. Mượt hơn rõ.

## ~~OPEN · Overlay video LỚP ĐÈ câm~~ — XONG (M-E, 2026-09-07)
Toggle "Bật tiếng của clip video" (mặc định TẮT → project cũ + hành vi cũ không đổi).
- PREVIEW: `Services/OverlayAudioMixer.swift` — mỗi clip 1 `AVPlayer` dựng từ `AVMutableComposition`
  chỉ có track audio; ticker 12Hz bám `playback.renderTime`; seek khi lệch > 0.3s; volume theo
  `fadeIn/fadeOut`. KHÔNG đụng `PlaybackController`/`AVAudioPlayer` bài chính → không liên quan bug
  "không có tiếng" bên dưới. Chỉ chạy khi có ≥1 clip bật tiếng (`activate()`/`deactivate()`).
- XUẤT: `AudioMux.ExtraAudio` + `encodeAAC(extras:)` — mỗi clip 1 track riêng + `AVMutableAudioMixInputParameters`
  (gain + 2 volume ramp), preset `AppleM4A` trộn phẳng thành 1 track AAC cùng bài hát chính.
  `TransparentVideoExporter` tự dựng list: bỏ clip nằm ngoài vùng cắt bài, `srcStart = trimStart + headCut`,
  `at = clip.start − timeOffset`. `merge(audio:)` nay nhận `URL?` (cho phép CHỈ tiếng lớp đè, không bài chính).

## ~~OPEN · Track header thiếu: mute nhạc chính~~ — XONG
`TimelineEditor.musicHeadRow` 🔊/🔇 (toggle `project.audioMuted`) + menu Xem ⇧⌘M. Ẩn track
"Lời" 👁 (M-F: `lyricsHidden`).

## ~~OPEN · Cursor trên timeline canvas sơ sài~~ — XONG (M-C, 2026-09-06)
`cursorFor(_:)` trong `mouseMoved`: mép = resizeLeftRight, thân = openHand, kéo = closedHand.

## OPEN · KẾT HỢP NHIỀU THAO TÁC CÙNG LÚC (đổi tab + chọn dòng + tua + đang phát) VẪN GIẬT VỪA (2026-09-21)
Đo `KM_AUTO_STRESS=all` + `KM_AUTO_PLAY=1` trên project nặng nhất ("tinh iu cao thuong", có stem,
49 dòng) — SAU khi đã có mọi fix (SỬA LẦN 7-14 + chặn crash): 24-35 nhịp/2s (còn ~50-58% khung hình
lý tưởng), 7-14 lần giật 40-360ms MỖI cửa sổ 2 giây, ĐỀU ĐẶN suốt — không còn giật NHIỀU GIÂY như
trước, nhưng KHÔNG mượt hoàn toàn. `sample` lúc này: ~24% luồng chính vẫn nằm trong
`CA::Transaction`/vẽ layer (không phải 1 vòng lặp lỗi — legitimate work: đổi tab/chọn dòng mỗi
500ms + DisplayLink vẽ preview+timeline ~30Hz lúc phát, CÙNG LÚC).
- **Chưa rõ đây là bug hay giới hạn phần cứng**: kịch bản `all` cố ý dồn 4 việc (tua+đổi tab+chọn
  dòng+phát nhạc) xảy ra MỖI 500ms — nặng hơn cách dùng thật (người dùng thường làm 1 việc 1 lúc,
  không đổi tab VÀ chọn dòng VÀ tua CÙNG 1 lúc liên tục). Có khả năng đây là chi phí THẬT (dựng lại
  view khi đổi tab + vẽ preview live) cộng dồn trên CPU 2017 Intel, không phải lỗi cụ thể còn sót.
- **CHƯA đào sâu thêm** vì thời gian — nếu user thấy giật rõ trong lúc chỉ làm ĐÚNG 1 việc (không
  phải kết hợp nhiều việc cùng lúc), đó là dấu hiệu còn bug cụ thể; nếu chỉ giật khi làm NHIỀU việc
  dồn dập, nhiều khả năng đây là giới hạn CPU máy 2017 so với M4, khó xoá hết bằng code.

## ĐÃ SỬA (phòng ngừa) · BẮT ĐƯỢC APP CRASH THẬT LÚC TUA NHANH — KHÔNG PHẢI CHỈ LÀ LAG (2026-09-21)
Rà log crash hệ thống (`~/Library/Logs/DiagnosticReports/`) — tìm thấy 1 crash THẬT
(`KaraokeMaker-2026-09-21-121009.ips`, bản build 20260920.1950): `EXC_BAD_INSTRUCTION`/`SIGILL`,
CoreText ném ObjC exception (`TAttributes::ApplyFont`) lúc `TimelineCanvasView.draw()` gọi
`NSString.draw(at:withAttributes:)` — AppKit coi exception không bắt được là crash CHẾT HẲN APP
(khác lag: đây là app tự THOÁT, không phải đứng hình). Xảy ra lúc tua rất nhanh (kịch bản
`KM_AUTO_STRESS=scrub`) ngay sau khi vừa mở project nặng (có stem, nhạc dài).
- **CHƯA lần ra đúng 1 dòng cụ thể** trong ~15 chỗ `.draw(at:/with:)` của file — build lúc crash
  đã bị ghi đè (đang liên tục rebuild để đào lỗi khác) nên không dịch ngược đúng dòng bằng địa chỉ
  được nữa.
- **Đã thêm phòng ngừa** (`TimelineCanvasView.draw`, `TimelineEditor.swift`): chặn đầu hàm nếu
  `pps`/`duration`/`contentWidth` không phải số hữu hạn (NaN/vô cực) — bỏ qua khung hình đó thay
  vì để crash cả app. Rẻ, không đổi hành vi bình thường.
- **Lặp lại đúng kịch bản đã crash 3 lần sau khi thêm chặn — không crash lại lần nào.** Không chắc
  chắn 100% đây là ĐÚNG NGUYÊN NHÂN gốc (chưa dịch ngược được đúng dòng) — nhưng là phòng ngừa hợp
  lý, không rủi ro gì thêm.
- **CHƯA rõ đây có phải là thứ user đang gặp hay không** — chỉ tái hiện được qua kịch bản test tự
  động (tua rất nhanh, 60 lần/giây, ngay lúc vừa mở). Nếu user thật sự gặp app ĐÓNG ĐỘT NGỘT (không
  phải đứng hình/giật) lúc đang kéo timeline — đây rất có thể là lý do, và giờ đã có 1 lớp chặn.

## ĐÃ SỬA · "KHÔNG CHẠY CŨNG LAG" — GỐC LÀ SET STEM ĐỒNG BỘ TRONG LƯỢT LAYOUT ĐẦU (2026-09-20)
Tiếp mục dưới đây (2026-09-19). Đo chính xác bằng bộ đếm `.onReceive(objectWillChange)` cho cả 6
object `ContentView` giữ (`store`/`playback`/`beatSepProxy`/`aligner`/`videoExporter`/
`advancedProxy`) — cả 6 đều = 0 lần phát tín hiệu trong khi `ContentView.body` vẫn chạy 13-15
lần/giây liên tục → chứng minh KHÔNG phải do dữ liệu, mà do AppKit/NSHostingView rơi vào vòng lặp
tính lại kích thước sau khi `beatSep.adoptFromProject(...)` chạy ĐỒNG BỘ ngay trong `.onAppear`
(lượt layout đầu tiên). Cô lập bằng thực nghiệm (bỏ hẳn lệnh gọi → hết ngay; ép `karaokeAvailable`
= false không giúp gì → không liên quan tới UI nút "Karaoke"). **Đã sửa**: dời lệnh gọi qua
`DispatchQueue.main.async` (`ContentView.adoptOrRefreshBeatSep`, `ContentView.swift`) — chạy sau
1 lượt runloop, không mất tính năng. Đo lại TRÊN PROJECT THẬT KHÔNG SỬA GÌ (`tinh iu cao thuong.
kbproj`, vocal+beat thật): `KM_BODY_LOG` 13-15Hz mãi mãi → 1 lần lúc mở rồi im hẳn;
`KMK_PERF` giật liên tục 250-600ms → 0 lần nghẽn (trừ khởi động). Xem `PROGRESS.md` "SỬA LẦN 14".
Đây là nguồn CHÍNH của "không chạy cũng lag" — xảy ra ở MỌI project đã tạo karaoke xong (có sẵn
vocal+beat), tức hầu hết lúc user thực sự dùng app.
**Đã tự kiểm tra lại nhiều lần** (build lại từ đầu, đóng gói lại, mở project thật KHÔNG sửa gì —
4 lần độc lập) — kết quả NHẤT QUÁN: sạch hoàn toàn sau ~4s khởi động ban đầu.
**Đã kiểm tra thêm, không phải hồi quy**: kéo thanh trượt NGAY LÚC VỪA MỞ (trong vòng 1 giây đầu)
trên ĐÚNG project nặng này (có stem, 49 dòng, nhạc dài) vẫn có thể giật vài giây — đo thử: giật
~3.5-11s tuỳ có "nghỉ" trước khi kéo hay không. Đã xác nhận đây KHÔNG PHẢI lỗi mới: (1) project
KHÔNG stem kéo ngay lúc mở vẫn hoàn toàn sạch (loại trừ hồi quy chung); (2) đây là kịch bản CHƯA
từng đo trước đây (mọi lần đo "scrub" trước giờ dùng project không stem) — thực chất là cùng loại
với "còn dư ~3-4 lần giật lúc kéo nhanh qua nhiều câu liên tiếp" đã ghi nhận ở SỬA LẦN 12/13, chỉ
lộ rõ hơn trên project nặng hơn (nhạc dài hơn, 49 câu). Không phải trường hợp thực tế điển hình
(người dùng thật không kéo đúng trong 1 giây đầu tiên vừa mở app).

## ⛔ ĐÃ GỠ HẾT (theo yêu cầu user) · TOÀN BỘ SỬA LAG SESSION 09-17 → 09-21 (2026-09-22)
User: "quay về bản đang nằm trong M4 (chưa update lại), bỏ những sửa đổi lâu nay" — sau nhiều ngày
sửa lag mà user báo "không thấy thay đổi", quyết định dừng hẳn hướng này. Git repo KHÔNG hề commit
suốt mấy tuần (commit gần nhất 1/9, trước cả Home screen/thư viện/đa ngôn ngữ/color engine) nên
KHÔNG dùng `git reset`/`git checkout` được (sẽ mất luôn 3 tuần tính năng khác) — đã tự tay gỡ TỪNG
thay đổi liên quan lag, giữ nguyên mọi tính năng khác, build lại OK, xác nhận app mở/chạy bình
thường.

**Đã gỡ** (trả lại đúng hành vi trước khi bắt đầu sửa lag):
- `PlaybackController.swift`: throttle audio-seek + throttle `bumpSeek` (SỬA LẦN 10, 12).
  `seekGeneration`/`PlaybackClock` GIỮ NGUYÊN (SỬA LẦN 7 — nền tảng, không throttle).
- `PlaybackHUD.swift`: trả `TimelineView(.periodic)` lại (bỏ bản thay bằng Combine Timer).
- `KaraokeRenderer.swift`: trả preview về vẽ bằng `NSImage`/`lockFocus` (bỏ `renderStaticCG`/
  `blitStaticCG` CHO PREVIEW — đường xuất video vẫn dùng CGImage như cũ, không đổi).
- `KaraokePreview.swift`: bỏ dirty-checking trong `updateNSView` (trả về set thẳng +
  `needsDisplay = true` vô điều kiện), bỏ `contentsFormat = .RGBA8Uint`, bỏ `KM_DRAW_LOG`.
- `TimelineEditor.swift`: bỏ `contentsFormat`, bỏ `KM_DRAW_LOG`, bỏ chặn NaN phòng crash, bỏ
  `LineSelection` (trả `currentLineIndex` về tham số truyền tay).
- `HomeView.swift`: bỏ `HomeThumbCache`, trả về `NSImage(contentsOf:)` trực tiếp không cache.
- `StylePanel.swift`/`LyricLinesList.swift`: bỏ `LineSelection`, trả `currentLineIndex` về tham số.
- `ContentView.swift`: bỏ `LineSelection` (lớp + inject), bỏ throttle `seekTo`/
  `updateCurrentLineIndexThrottled`/`ScrubThrottleBox` (trả seekTo về gán thẳng), bỏ
  `mediaThumbCache`/`loadMediaThumb` (trả `mediaPoolThumb` về `NSImage(contentsOf:)` trực tiếp),
  bỏ defer `adoptOrRefreshBeatSep` qua `DispatchQueue.main.async` (trả về gọi đồng bộ — **LƯU Ý:
  đây là chỗ đo được rõ nhất là gốc "không chạy cũng lag", xem mục SỬA LẦN 14 bên dưới — nếu chỉ
  muốn giữ lại ĐÚNG 1 chỗ, đây là ứng viên tốt nhất**), bỏ `threeColumns`/`timelineBlock`/
  `columnsAndTimeline`/`KM_NO_SPLITVIEW` (trả `mainLayout` về `VSplitView{HSplitView{...}}` thẳng),
  bỏ `.transaction{disablesAnimations}`, bỏ toàn bộ `KM_BODY_LOG`/`KM_AUTO_STRESS` harness.
- `RootView.swift`: bỏ `KM_AUTO_OPEN`/`KM_AUTO_PLAY` self-test harness.
- `PerfMonitor.swift`: trả RunLoop mode về `.default` (từ `.common`).

**KHÔNG đụng** (không phải "sửa lag", giữ nguyên): `BeatSepProxy`/`AdvancedKaraokeProxy` (throttle
tiến độ tách nhạc, ở đầu `ContentView.swift`) — rủi ro gỡ nhầm cao (dính ~40 chỗ gọi cơ học) so với
lợi ích, ĐÃ CÓ TỪ TRƯỚC lúc bắt đầu leo thang lần này, chưa từng bị nghi là nguồn gây lag. Cũng
không đụng `ProjectPackage.swift`/`ProjectStore.swift`/`KaraokeProject.swift` (sửa lỗi mất media
lúc lưu — khác chủ đề, không phải lag) và mọi tính năng khác (Home, thư viện, đa ngôn ngữ, color
engine, timeline chuyên nghiệp, keyframe...).

Toàn bộ chi tiết đo đạc/lý do của từng lần sửa vẫn giữ nguyên bên dưới (SỬA LẦN 7-14) để tham khảo
nếu sau này muốn thử lại — nhưng CODE ĐÃ KHÔNG CÒN áp dụng những mục đó nữa.

## ~~OPEN~~ · TÌM RA NGUỒN "KHÔNG CHẠY CŨNG LAG" THẬT — CÓ VOCAL/BEAT STEM LÀ NGUYÊN NHÂN — XÁC NHẬN ĐÃ HẾT (2026-09-29)
**Kiểm chứng lại hôm nay (kiến trúc sư trưởng mới), KHÔNG còn tái hiện được**: mở đúng project
`Gánh Mẹ...kbproj` đã lưu SẴN vocal+beat stem trên đĩa (tách xong, ⌘S, quit hẳn app, mở lại từ Home
— đúng kịch bản mục này mô tả), đo idle thật 18 giây liên tục (`ps -o pcpu`, lấy mẫu mỗi 3s): 0,0–0,5%
CPU suốt, không có mẫu nào cao. Nhiều khả năng đã được sửa "ăn theo" bởi lần sửa `EditorCommandSink`
không-`Equatable` (2026-09-24, xem mục bên dưới) — lần sửa đó xảy ra SAU note này nhưng chưa từng
quay lại đóng mục này. Bộ harness đo cũ (`KM_BODY_LOG`/`KM_AUTO_STRESS`/`KM_AUTO_OPEN`) đã bị gỡ
hẳn khỏi code trong đợt "ĐÃ GỠ HẾT" 2026-09-22 nên không dùng lại y hệt cách đo cũ được — đo thay
bằng `ps`/`sample` trực tiếp trên bản release đóng gói thật (`dist/KaraokeMaker.app`). Để mở lại nếu
user vẫn báo lag đứng yên: nghi trước tiên `EditorCommandSink`/bất kỳ giá trị nào đi qua
`.focusedSceneValue` thiếu `Equatable` (bài học ghi ở mục 2026-09-24), KHÔNG quay lại nghi
`adoptOrRefreshBeatSep`/`beatSepProxy` trước — đã đo sạch nhiều lần với đúng loại project có stem.

<details><summary>Ghi chép gốc (2026-09-19, lúc còn là OPEN) — giữ lại để tham khảo phương pháp đo</summary>

## OPEN · TÌM RA NGUỒN "KHÔNG CHẠY CŨNG LAG" THẬT — CÓ VOCAL/BEAT STEM LÀ NGUYÊN NHÂN, CHƯA TÌM RA CƠ CHẾ CHÍNH XÁC (2026-09-19)
Sau nhiều lần user báo "chạy không chạy gì cũng lag" mà đo trên project TEST (nhẹ, không stem) lại
sạch — phát hiện ra lỗi PHƯƠNG PHÁP: mọi lần đo trước đó (SỬA LẦN 7-13) đều dùng project test nhẹ,
KHÔNG đại diện cho project THẬT user dùng hàng ngày (project thật luôn có vocal+beat stem sau khi
"Tạo Karaoke", vì `BeatSeparation` tách xong LUÔN lưu kèm vào project — xem `karaoke-progress-2-
stage`).
- Lấy đúng project user đang mở trên Home (`tinh iu cao thuong.kbproj`, 159MB, nhạc thật + vocal +
  beat stem thật, 49 dòng lời đã canh xong) — đo idle THẬT (không thao tác, không phát): **giật
  đều đặn 250-600ms, LIÊN TỤC KHÔNG NGỪNG**, hoàn toàn khác các project test trước đó (sạch tuyệt
  đối). `KM_BODY_LOG` xác nhận `ContentView.body` chạy 5-15 LẦN/GIÂY suốt lúc đứng yên.
- **Cô lập bằng A/B trực tiếp**: tạo bản sao project.json xoá `vocalStem`/`beatStem` (giữ nguyên
  49 dòng lời + audio + mọi thứ khác), đóng gói lại, mở — **SẠCH HOÀN TOÀN** (60-61 nhịp/2s như
  project test). Xác nhận bằng ảnh chụp: project vẫn mở đúng, đủ 49 dòng, sóng âm hiện đúng — không
  phải do file hỏng lúc đóng gói lại. → **CÓ vocal/beat stem trong project = nguyên nhân trực tiếp
  của lag liên tục lúc đứng yên.**
- **Đã LOẠI, không phải nguyên nhân** (đo trực tiếp bằng debug log, không phải suy đoán):
  - `BeatSepProxy`/`source.$vocalURL`/`source.$beatURL` — chỉ phát 1 LẦN lúc mở (nhận stem từ
    project), không lặp lại.
  - `AdvancedKaraokeProxy` (`phase`/`resultNote`/`listenProgress`) — đứng yên hoàn toàn.
  - `aligner` (`ForcedAligner`, giữ trực tiếp bằng `@StateObject` không qua proxy) —
    `isRunning`/`status`/`progress` đứng yên.
  - `videoExporter` (`TransparentVideoExporter`) — đứng yên.
  - `.onAppear` của `ContentView` — chỉ chạy ĐÚNG 1 lần (không bị gọi lặp).
  - `SpectrumStore`/"sóng nhạc" — project này `visualizer.enabled = false`, không kích hoạt.
  - `playback.isPlaying` — xác nhận `false` suốt (không tự phát ngầm).
- **CHƯA tìm ra cơ chế chính xác** nối "có stem" → "ContentView.body chạy liên tục" — đã loại hết
  các nghi phạm rõ ràng nhất. Còn nghi vấn CHƯA kiểm tra hết: chuỗi `.onChange(of: beatSepProxy.
  beatURL/vocalURL)` → `syncStemRefsIntoProject()` → `store.markDirty()` → `store.hasUnsavedChanges
  = true` (đổi 1 LẦN, xác nhận qua log, NHƯNG chưa loại khả năng việc `hasUnsavedChanges` đổi
  sang `true` tự nó kéo theo điều gì đó khác lặp lại); hoặc 1 hiệu ứng nào đó của việc nút
  "Karaoke" chuyển từ disabled→enabled (`karaokeAvailable = beatSepProxy.beatURL != nil`) mà chưa
  rà hết.
- **CÁCH TÁI HIỆN cho lần đào tiếp** (không cần user thao tác gì):
  ```
  KM_BODY_LOG=1 KM_AUTO_OPEN="/Users/khoile/Downloads/tinh iu cao thuong.kbproj" \
    ./dist/KaraokeMaker.app/Contents/MacOS/KaraokeMaker
  ```
  Để yên 10-20s, xem `[body] ContentView.body: N lần/giây` trong log — N cao (>2-3) dù đứng yên
  hoàn toàn là dấu hiệu bug này. Đã để lại debug log tạm (gated `KM_DEBUG_STEM=1`) in ra mỗi lần
  `syncStemRefsIntoProject`/sink của `beatURL`/`vocalURL`/`.onAppear` chạy — hữu ích cho lần đào
  tiếp, có thể gỡ sau khi tìm ra gốc.
- **Đây rất có thể là nguồn CHÍNH của "không chạy cũng lag"** — ảnh hưởng MỌI project thật đã tạo
  karaoke xong (tức là hầu hết mọi lúc user thực sự dùng app), giải thích tại sao user thấy
  "không hề thay đổi" dù các lần sửa trước (SỬA LẦN 7-13) đều đo sạch — vì toàn đo nhầm loại
  project không có stem.

</details>

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 13, ẢNH CHỮ CACHE SAI ĐỊNH DẠNG — ĐÃ SỬA, VẪN CÒN GIẬT NHẸ HƠN KHI KÉO NHANH QUA NHIỀU CÂU (2026-09-18)
User: "vậy thì sửa đi" (tiếp SỬA LẦN 12). Tìm ra: ảnh chữ karaoke đã CACHE ĐÚNG (không dựng lại
mỗi khung) nhưng chính cái CACHE đó là `NSImage` dựng bằng API cũ (`lockFocusFlipped`) mang định
dạng theo màn hình (wide-gamut) — nên MỖI LẦN dán ảnh cache vào khung hình, CoreGraphics phải tự
đổi định dạng lại (`vImageConverterConvert`), đo ~65% luồng chính lúc kéo. Đường xuất video vốn đã
làm đúng (CGContext tường minh sRGB 8-bit) — cho Preview dùng lại đúng con đường đó. ĐÃ TỰ KIỂM TRA
BẰNG MẮT (chụp màn hình lúc có lời đang hát) trước khi báo — chữ đúng chiều, đúng màu, hiệu ứng tô
sáng chạy đúng, không vỡ hình. Đo lại: số mẫu trong đường chậm đó giảm 572→7, tổng chi phí
compositing giảm 65%→27% luồng chính. Xem `PROGRESS.md` "SỬA LẦN 13".
- **CHƯA sạch hoàn toàn**: kịch bản kéo quét CẢ BÀI trong ~1.5s (nặng hơn 1 lần kéo tay thật) vẫn
  còn giật 250ms-1s, thỉnh thoảng 1.5-2.6s — do CHI PHÍ THẬT của việc dựng lại ảnh chữ mỗi khi
  playhead nhảy qua câu khác (không phải lỗi thừa, là việc cần làm) khi đổi câu quá nhanh liên
  tiếp. Hướng sau nếu cần đào tiếp: dựng cache ở luồng nền thay vì luồng chính, hoặc giảm tần số
  đổi câu khi đang kéo rất nhanh.

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 12, LỖI ĐO SAI (test nhầm project KHÔNG nhạc) + tìm thêm 1 nguồn + CHƯA HẾT (2026-09-18)
**Tự phát hiện lỗi của chính mình**: toàn bộ số liệu "0 lần nghẽn" báo cho user ở SỬA LẦN 10/11 đo
trên project "khôi" — project này KHÔNG CÓ NHẠC (`audio: null` trong file), chỉ 3 dòng lời. Không
đại diện cho project thật của user (có nhạc thật, 30-60 dòng). User báo "không hề có 1 chút nào
thay đổi" — ĐÚNG, vì bản đo trước đó không phản ánh app thật user dùng.
- Đo lại TOÀN BỘ trên project thật có nhạc (`mot thua yeu nguoi.kbproj`, nhạc thật 267s, 32 dòng):
  `KM_AUTO_STRESS=scrub` (kéo liên tục) → **vẫn giật nặng 1.7-3.5 GIÂY**, KHÔNG sạch như báo trước.
- Tìm thêm 1 nguồn thật bằng `sample`: `PlaybackClock.bumpSeek()` (đếm mỗi lần tua, dùng để báo
  2 view Timeline/Preview vẽ lại) chạy KHÔNG giới hạn tốc độ — ở tần số kéo chuột thật (60-90Hz),
  MỖI lần bump vẫn kích hoạt `-[NSWindow layoutIfNeeded]` CẢ CỬA SỔ (đo ~65% luồng chính lúc kéo)
  dù chỉ 2 view nhỏ thật sự cần biết — Auto Layout của AppKit áp dụng theo CẢ CỬA SỔ, không tách
  theo từng view SwiftUI nào đổi. Đã chặn còn ~20 lần/giây.
- Đo lại: đỉnh giật giảm 3072-3530ms → còn ~700-1086ms — cải thiện thật (~3-4 lần) nhưng
  **CHƯA sạch**, vẫn còn lag thấy rõ.
- `sample` sau khi chặn bumpSeek lộ ra nguồn KHÁC LOẠI: không còn là SwiftUI/Auto Layout nữa, mà
  là chi phí VẼ THẬT (`KaraokePreviewCanvas.draw`/`KaraokeRenderer.drawPreview`, CoreGraphics/
  CoreText vẽ chữ karaoke có hiệu ứng) — chiếm ~17% luồng chính lúc kéo trên project có nhạc+lời
  thật. Đây KHÔNG phải lỗi "vô tình dựng lại" như các lần trước — là chi phí vẽ thật, cần hướng sửa
  khác hẳn (cache lớp chữ đã vẽ, giảm tần số vẽ khi kéo nhanh, hoặc tối ưu chính hàm vẽ) — CHƯA làm.
- **Kết luận trung thực**: đã giảm được thật (đo trên đúng loại project user dùng), nhưng CHƯA hết
  lag. User có lý khi nói "vẫn lag nặng" — bản trước đó tôi báo "0 lần nghẽn" là SAI vì đo nhầm
  project. Xem `PROGRESS.md` "SỬA LẦN 12" cho chi tiết đầy đủ + hướng đào tiếp.

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 11, CHỌN DÒNG LÚC PHÁT GIẢM 10-20 LẦN + PHÁT HIỆN MỚI CHƯA SỬA (2026-09-18)
Tiếp SỬA LẦN 10, user báo "vẫn vậy". Sửa lỗ hổng đo (`PerfMonitor` giờ đo được cả lúc kéo chuột
thật `.eventTracking`, xem `PerfMonitor.swift`) + cô lập triệt để `currentLineIndex` (dòng lời
đang chọn) ra khỏi `@State` của `ContentView` sang `LineSelection` riêng (y hệt cách đã làm cho
`seekGeneration` ở SỬA LẦN 7) — vì `PlaybackTicks` tự đẩy dòng theo playhead lúc phát, và bấm chọn
dòng tay, ĐỀU kéo `ContentView.body` dựng lại + Auto Layout cả cửa sổ. Đo `line`+`play`:
3320-10452ms → còn ~550-600ms (giảm 10-20 lần). Xem `PROGRESS.md` "SỬA LẦN 11" cho chi tiết đo
đạc đầy đủ (gồm cả việc loại tiếp giả thuyết NSSplitView, và chặn tốc độ ghi audio-seek riêng vì
`player.currentTime` là thao tác đồng bộ của AVFoundation, có thể chậm).

**PHÁT HIỆN MỚI, CHƯA SỬA** — quan trọng, đọc trước khi làm tiếp: đo idle THẬT (không thao tác gì)
sau khi `PerfMonitor` đã chính xác hơn, lộ ra giật ĐỀU ĐẶN ~250-600ms, ~4 lần/giây, CHỈ xảy ra khi
đang MỞ 1 project có `lines.count > 0` (project rỗng 0 dòng thì sạch tuyệt đối, Home screen cũng
sạch tuyệt đối). Đã loại: không phải `SpectrumAnalyzer`/`OverlayAudioMixer`/`waveform`/timer đã
biết. Chưa tìm ra đúng đường gọi. **Đây rất có thể là nguồn "không chạy cũng lag" user báo** —
cách tái hiện: `KMK_PERF=1 KM_AUTO_OPEN="<project có vài dòng lời, KHÔNG audio>"
./dist/KaraokeMaker.app/Contents/MacOS/KaraokeMaker`, để yên 10-20s, xem log `[perf] nghẽn`.

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 10, KÉO THANH TRƯỢT GÂY ĐỨNG HÌNH 11s — ĐÃ SỬA (2026-09-18)
User trả lời câu hỏi cụ thể (không chạy cũng lag / kéo thanh trượt cũng lag / background không
chọn được / chạy play càng lag nặng). Cô lập bằng kịch bản tự động MỚI `KM_AUTO_STRESS=scrub` (gọi
`seekTo` ở đúng tần số kéo chuột thật ~60 lần/giây, khác "seek" cũ chỉ 2 lần/giây). Kết quả: **11
GIÂY đứng hình liên tục** ngay đợt đầu. Gốc: `Slider` thanh tua (`PlaybackHUD.swift`) gọi `seekTo`
liên tục lúc kéo, mỗi lần set `currentLineIndex` (`@State` riêng của `ContentView`, KHÔNG qua
`PlaybackClock` đã cô lập) → bắt `ContentView.body` (3 cột+timeline) dựng lại + Auto Layout cả cửa
sổ MỖI LẦN, các lần dồn ứ chồng lên nhau vì xử lý không kịp tốc độ sự kiện kéo chuột. Đã sửa: chặn
tốc độ cập nhật `currentLineIndex` còn ~15 lần/giây trong lúc kéo (không đổi độ chính xác âm
thanh/tua, chỉ dòng tô sáng cập nhật chậm hơn 1 chút, mắt không nhận ra, luôn khớp đúng lúc thả
chuột). Đo lại: 0 lần nghẽn >40ms trong toàn kịch bản kéo liên tục 11s (trước: 1 lần 11104ms).
**Đây rất có thể cũng là nguyên nhân "background không chọn để đổi được"** — bấm chọn trong lúc app
đang kẹt xử lý hàng đợi dồn ứ (nhiều giây) thì coi như không phản hồi. Xem `PROGRESS.md` "SỬA LẦN
10". Build OK, đã tự đo trước/sau, đã push. **User cần xác nhận lại cả 4 ý đã báo** (đứng yên / kéo
thanh trượt / chọn nền / lúc đang phát) sau bản này.

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 9, ĐÃ SẠCH MỌI KỊCH BẢN TỰ ĐỘNG ĐO ĐƯỢC (2026-09-18)
User báo "chẳng có gì thay đổi vẫn lag nặng" ngay sau SỬA LẦN 8 — đã xác nhận tiến trình đang chạy
ĐÚNG bản mới (không phải lỗi build/process cũ). Rà toàn bộ code tìm thêm cùng loại lỗi
(`NSImage(contentsOf:)` đồng bộ không cache) — thấy thêm màn HOME (lưới project, `ProjectCard`
trong `HomeView.swift`) bị y hệt lỗi vừa sửa ở tab Media. Đã sửa (cache + giải mã ngoài luồng
chính, xem `PROGRESS.md` "SỬA LẦN 9"). Đo idle thật 20s sau khi sửa: PerfMonitor 60-61 nhịp/2s (gần
kín), hầu hết cửa sổ 0 lần nghẽn. Đo tua/đổi tab/kết hợp cũng sạch (xem SỬA LẦN 7, 8).
- **QUAN TRỌNG**: mọi kịch bản công cụ tự động dựng được (không cần user thao tác) giờ đều đo sạch.
  Công cụ KHÔNG giả lập được: kéo chuột thật (không có quyền Accessibility để phát sự kiện chuột/
  bàn phím), resize cửa sổ/cột bằng tay, xuất video, mở project lần đầu lúc máy còn "nguội". Nếu
  vẫn lag sau bản này, **BẮT BUỘC cần biết cụ thể đang làm gì lúc lag** (mở app? đổi tab? kéo
  timeline/overlay bằng chuột? phát nhạc? xuất video? hay lúc nào cũng vậy kể cả đứng yên?) —
  không có thông tin này thì không còn hướng nào khác để đào tiếp bằng công cụ tự động.

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 8, ĐỔI TAB CỘT TRÁI HẾT GIẬT NẶNG (2026-09-18)
Điều tra tiếp mục "~4 lần giật/2s dư lại" của SỬA LẦN 7. Cô lập bằng `KM_AUTO_STRESS=tab` (chỉ đổi
tab, không tua): giật NẶNG HƠN cả tua — 6-8 nghẽn/2s, đỉnh 500-600ms, PerfMonitor chỉ bắt được
2-8 nhịp/2s (tối đa 60). Gốc: `mediaPoolThumb` (tab "Media") gọi `NSImage(contentsOf:)` — đọc +
giải mã ảnh gốc full độ phân giải THẲNG trong SwiftUI body, main thread, KHÔNG cache — chạy lại
cho MỌI ảnh trong kho mỗi lần tab dựng lại. Ảnh nền đã làm đúng (giải mã ngoài luồng + cache) từ
trước, chỉ ảnh thu nhỏ trong kho bị bỏ sót. Đã sửa: thêm cache `[UUID: NSImage]` + giải mã bằng
`Task.detached` ngoài main thread, giới hạn 240px. Đo bằng `KM_AUTO_STRESS=tab`: đỉnh giật
500-600ms → 85-190ms, nhịp/2s từ 2-8 → 54-58 (gần kín 60). Đo kịch bản tổng hợp `all` (tua+đổi
tab+chọn dòng+đang phát): 34-55 nhịp/2s, đỉnh 100-260ms. Build OK, đã tự đo (không cần user), đã
push. Xem `PROGRESS.md` "SỬA LẦN 8" cho chi tiết. **Nếu user vẫn thấy lag sau bản này** — hầu hết
các nguồn đã biết đều đã sửa + đo xác nhận; cần user mô tả CỤ THỂ thao tác nào đang lag (mở project
mới? kéo overlay? xuất video? mở app?) để đào tiếp đúng chỗ, vì công cụ tự động không thể giả lập
được mọi loại thao tác (vd. kéo chuột thật, mở file lớn lần đầu).

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 7, GIẢM ~40-50% ĐO ĐƯỢC, CHƯA HẾT (2026-09-17)
Xây được bộ công cụ tự tái hiện lag KHÔNG CẦN USER thao tác (`KM_AUTO_OPEN`/`KM_AUTO_STRESS`/
`KM_BODY_LOG`/`KM_DRAW_LOG`, xem `PROGRESS.md` "SỬA LẦN 7"). Cô lập được: TUA TIMELINE (không cần
đổi tab/chọn dòng) một mình đã gây giật nặng ngang mức trước. Gốc: `PlaybackController.
seekGeneration` (@Published) tăng mỗi lần tua, `ContentView` giữ `PlaybackController` qua
`@EnvironmentObject` (cần cho việc khác) nên MỌI publish trên đó — kể cả cái `ContentView` không
đọc — đều kéo cả `ContentView` (cây 3 cột+timeline) dựng lại → Auto Layout cả cửa sổ. Đã dời
`seekGeneration` sang `PlaybackClock` (đã tách riêng từ trước, `ContentView` không giữ). Đo bằng
`KM_AUTO_STRESS=seek`: đỉnh giật 990ms→240ms, số nhịp bắt được/2s 33-38→44-53. Đã LOẠI giả thuyết
"NSSplitView là thủ phạm" (`KM_NO_SPLITVIEW=1` không cải thiện). Còn dư ~4 lần giật/2s — nghi do
đổi tab (`leftPanelTab`) cần dựng lại panel thật, hoặc còn @Published khác chưa cô lập — CHƯA hết
hẳn, cần đào tiếp nếu user vẫn thấy nặng.

## OPEN · Lag toàn app trên iMac 2017 Intel — SỬA LẦN 6, CHƯA XÁC NHẬN VỚI PROJECT THẬT (2026-09-16)
Lần 5 (bỏ `@Published` khỏi `clock.seconds`, chuyển 3 view trong `PlaybackHUD.swift` sang
`TimelineView(.periodic)`) user báo VẪN lag, kể cả KHÔNG phát nhạc. Bật `PerfMonitor`
(`KMK_PERF=1`, có sẵn trong code) khi user dùng project thật → log cho thấy đứng hình LẶP LẠI mỗi
lần ~4–10 GIÂY. Bắt bằng `sample` đúng lúc: lộ ra chính `TimelineView` (lần 5) là thủ phạm — nó
chạy VÔ ĐIỀU KIỆN (không kiểm tra `playback.isPlaying`), nên tự polling 3 lần/giây MÃI MÃI kể cả
lúc không phát, TỆ HƠN bản gốc (ticker cũ chỉ chạy lúc `play()`). Lần 6: gated cả 3 view lại bằng
`playback.isPlaying` — lúc dừng phát, `body` là view TĨNH, không polling. Tự test Home screen
(chưa mở project) sau sửa: luồng chính về lại ~100% `mach_msg2_trap` (idle thật). **CHƯA test được
với project thật đang mở + không phát** (không có quyền Accessibility để tự thao tác GUI thay
user) — cần user xác nhận. Nếu VẪN còn lag lúc không phát sau bản này: nghi `MusicVisualizer`/
`SpectrumAnalyzer` tự chạy không cần phát, hoặc 1 `ProgressView()` (spinner) bị kẹt hiện
(`phaseRow`/`progressRow` trong `ContentView.swift`) dù không có việc gì đang chạy thật. Xem
`PROGRESS.md` "LAG — SỬA LẦN 6". **Công cụ chẩn đoán tốt nhất đã có sẵn**: chạy app với
`KMK_PERF=1` (in ra Terminal mỗi lần nghẽn >40ms + tóm tắt 2s) — nên dùng ngay lần đầu cho các báo
cáo lag sau này, đỡ phải đoán kiến trúc.

## OPEN · Package format (.kbproj zip) từng mất media ÊM, không báo — ĐANG THEO DÕI (2026-09-15)
User báo: lưu project rồi mở ở máy khác → "không có gì", "không chọn được nền". Đọc lại code
`materializeMedia`/`rehomeMediaIfNeeded` (2026-09-13): logic tự nó có vẻ đúng (copy media vào
`Media/`, đổi path, rehome theo tên lúc mở) — NHƯNG NẾU nguồn không resolve được lúc lưu (file gốc
đã bị xoá/di chuyển khỏi đường dẫn/bookmark) thì `materializeMedia` BỎ QUA ÊM, không copy được, và
project lưu ra vẫn còn trỏ đường dẫn NGOÀI máy — mở ở máy khác chắc chắn mất, không có cách nào biết
trước. Đây có thể là nguyên nhân (nếu user test bằng project ĐÃ LƯU TRƯỚC 2026-09-13, project đó
chưa từng gói media — quy luật cũ ghi rõ "chỉ LƯU LẠI mới chuyển đổi").
- **Đã sửa** (chưa xác nhận hết bug, chỉ tăng khả năng CHẨN ĐOÁN): `materializeMedia` giờ trả về
  danh sách tên món KHÔNG copy được → `ProjectStore.write` hiện banner lỗi ngay lúc LƯU nếu có món
  bị bỏ lại. Thêm `KaraokeProject.missingMediaLabels()` — `ProjectStore.open` hiện banner nếu sau
  khi mở (đã rehome) vẫn còn món trỏ ra file không tồn tại. Trước đây cả 2 chỗ này ÂM THẦM, giờ
  người dùng thấy ngay tên món thiếu (nhạc / nền / kho / lớp đè) thay vì đoán mò.
- **CHƯA xác nhận** gốc rễ thật — cần user trả lời: project test là project LƯU TỪ TRƯỚC hay mới
  "Lưu thành…" lại sau bản vá 13/9? Copy sang máy kia bằng cách nào (AirDrop/USB/khác)? Bấm nút
  "Đổi" (khi nền báo lỗi cam) có phản ứng gì không?
- Build OK 2026-09-15, CHƯA test qua UI thật/M4.

## OPEN · Chưa có model clip audio → không edit nhạc trên timeline
1 file nhạc chính duy nhất. → M-D (cần model mới, làm cẩn thận, không phá luồng nạp nhạc hiện tại).

## WARNINGS Swift 6 (không chặn build, không trong scope trừ khi đụng)
- `SpectrumAnalyzer.swift`: `NSLock.lock()/unlock()` trong async context.
- `ProjectStore.swift`: từng có captured var `snapshot` — đã sửa thành `let forThumb`.
- `MDXSeparator.swift`: `vDSP.DFT` deprecated (Float conformance).

## ⛔ Ý tưởng dính "tạo karaoke" — GHI LẠI, KHÔNG CODE
(để đây cho có chỗ; hiện chưa có mục nào. Nếu user nêu ý tưởng về thuật toán canh lời,
ghi vào đây và chờ user mở riêng.)
