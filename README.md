*Tiếng Việt · [English](README.en.md)*

# KaraokeMaker

Ứng dụng dựng video karaoke chạy trên macOS — kiểu CapCut/Final Cut nhưng làm riêng cho việc biến
1 bài hát thành video karaoke hoàn chỉnh. Đưa file nhạc vào, có lời canh nhịp theo từng chữ (tự gõ
tay hoặc để máy tự nghe rồi viết ra), chỉnh kiểu chữ, thêm nền + lớp đè, chỉnh màu, rồi xuất ra file
phụ đề hoặc video hoàn chỉnh có sẵn hiệu ứng quét sáng chữ theo nhịp hát.

Mọi thứ chạy **ngay trên máy Mac của bạn** — không qua máy chủ, không cần tài khoản, không tốn phí
mỗi lần xuất. App chỉ ra mạng đúng 1 lần để tải mô hình cho tính năng AI viết lời (tuỳ chọn, xem
mục [Tự động tạo Karaoke](#tự-động-tạo-karaoke-ai-không-cần-lời) bên dưới).

- **Swift Package** (không phải `.xcodeproj`), SwiftUI + AppKit lai, macOS 13 (Ventura) trở lên.
- Chạy NATIVE trên cả Apple Silicon lẫn Intel.
- Tách giọng hát (MDX-Net / MDX23C, ONNX Runtime) và canh giờ chữ (MMS, ONNX CTC) đều chạy ngay
  trên máy — bộ máy canh giờ không cần gọi ra ngoài.
- Tự động nhận dạng lời bằng AI (Qwen3-ASR, qua 1 runtime Python tự chứa) cho bài chưa có sẵn lời —
  tính năng tuỳ chọn.

---

## Mục lục

- [Ứng dụng làm gì](#ứng-dụng-làm-gì)
- [Yêu cầu hệ thống](#yêu-cầu-hệ-thống)
- [Cài đặt lần đầu trên máy Mac mới](#cài-đặt-lần-đầu-trên-máy-mac-mới)
- [Hướng dẫn sử dụng](#hướng-dẫn-sử-dụng)
  - [Màn hình Home](#màn-hình-home)
  - [Bắt đầu 1 project](#bắt-đầu-1-project)
  - [Lấy lời bài hát: 2 cách](#lấy-lời-bài-hát-2-cách)
  - [Màn hình chỉnh sửa (Editor)](#màn-hình-chỉnh-sửa-editor)
  - [Cơ bản về Timeline](#cơ-bản-về-timeline)
  - [Chỉnh kiểu chữ karaoke](#chỉnh-kiểu-chữ-karaoke)
  - [Nền, lớp đè, và sóng nhạc](#nền-lớp-đè-và-sóng-nhạc)
  - [Chỉnh màu](#chỉnh-màu)
  - [Xuất file](#xuất-file)
  - [Lưu và file project](#lưu-và-file-project)
- [Cấu trúc dự án (cho lập trình viên)](#cấu-trúc-dự-án-cho-lập-trình-viên)
- [Giới hạn đã biết](#giới-hạn-đã-biết)

---

## Ứng dụng làm gì

| Khu vực | Làm được gì |
|---|---|
| **Nhập liệu** | Đưa file nhạc (MP3/WAV/…), ảnh, video vào kho media của project. |
| **Lời & canh giờ** | Dán lời vào rồi để app tự canh khớp giọng hát, *hoặc* để app tự nghe bài hát và viết lời giúp (AI, chạy ngay trên máy). Canh giờ tới từng chữ, chỉnh tay lại được trên timeline. |
| **Timeline** | Nhiều track cùng lúc (nhạc, lời, karaoke, tối đa 3 lớp đè) — cắt/tách/kéo/nhân đôi, hít dính (snap), zoom, hoàn tác/làm lại, phím tắt, sóng âm vẽ thật. |
| **Kiểu chữ** | Font, cỡ chữ, độ đậm, hoa/thường, khoảng cách chữ, màu chữ đã hát/chưa hát, viền, đổ bóng, bố cục — lưu thành preset riêng hoặc dùng preset có sẵn. |
| **Nền & lớp đè** | Nền ảnh tĩnh hoặc video (có hiệu ứng Ken Burns), tối đa 3 lớp đè (ảnh/video/chữ) — kéo, đổi cỡ, xoay, chỉnh độ mờ, chế độ hoà trộn (blend), mờ dần vào/ra, chuyển cảnh mờ. |
| **Bộ máy chỉnh màu** | Bảng màu thật theo từng vùng tông màu (phơi sáng, tương phản, vùng sáng/tối/điểm trắng/điểm đen, nhiệt độ màu/sắc, độ rực/bão hoà, đường cong tông màu, HSL, LUT, tối góc, biểu đồ histogram/scope) — preview và video xuất ra LUÔN giống nhau. |
| **Sóng nhạc** | 7 kiểu hiệu ứng sóng/phổ nhạc chạy theo FFT thật của bài hát. |
| **Xuất file** | SRT và ASS (phụ đề kiểu karaoke quét sáng `\kf`), hoặc video dựng sẵn: nền trong suốt (ProRes 4444, có kênh alpha — để ghép vào phần mềm dựng khác) hoặc nền đục (H.264/MP4 hoặc ProRes). Có sẵn các cỡ khung hình từ 720p tới 4K, kể cả dọc (9:16) và vuông (1:1). |
| **Project** | Mọi thứ (nhạc, lời, canh giờ, kiểu chữ, màu, kho media, tuỳ chọn xuất) lưu chung vào 1 file `.kbproj` — mở lại sửa tiếp được, kể cả trên máy Mac khác. |

### Tự động tạo Karaoke (AI, "Không cần lời")

Nếu chưa có sẵn lời gõ ra, KaraokeMaker có thể tự nghe bài hát: tách giọng hát ra riêng, nhận dạng
thành chữ (Qwen3-ASR, chạy ngay trên máy qua 1 runtime Python đóng gói sẵn — không có gì gửi ra
ngoài), đánh dấu những chữ máy nghe chưa chắc, rồi canh giờ bằng ĐÚNG bộ máy canh giờ dùng chung với
đường "Tôi có lời". Bạn xem lại / sửa lời trước khi áp vào project.

Đây là tính năng DUY NHẤT cần cài thêm khi dựng trên máy mới — xem phần dưới.

---

## Yêu cầu hệ thống

- macOS 13 (Ventura) trở lên
- Xcode 15 trở lên (hoặc chỉ cần Xcode Command Line Tools — đây là Swift Package chứ không phải
  `.xcodeproj`, nên không bắt buộc cài nguyên bộ Xcode mới build được)
- ~600 MB dung lượng trống cho 3 mô hình ONNX đóng gói sẵn, cộng thêm (CHỈ nếu muốn dùng tính năng
  AI "Không cần lời") khoảng 6 GB nữa cho runtime Python/PyTorch + bộ trọng số Qwen3-ASR 0.6B + 1.7B

---

## Cài đặt lần đầu trên máy Mac mới

### 1. Cài Xcode Command Line Tools (nếu máy chưa có)

```bash
xcode-select --install
```

### 2. Tải mã nguồn về

```bash
git clone https://github.com/cccgi/KaraokeLab.git
cd KaraokeLab/KaraokeApp
```

### 3. Lấy lại 3 mô hình ONNX

3 file mô hình phục vụ tách giọng hát + canh giờ chữ (~580 MB gộp lại) **KHÔNG** nằm trong git repo
này — vượt trần 100 MB của GitHub. `Package.swift` cần các file này tồn tại THẬT trên đĩa ở
`Sources/KaraokeMaker/Resources/` thì mới build được, nên phải lấy về trước khi build lần đầu. Có
sẵn 1 script lo việc này:

```bash
./Scripts/setup-client-runtime.sh --skip-runtime
```

1 trong 3 mô hình (`UVR-MDX-NET-Voc_FT.onnx`) có nguồn tải công khai đã kiểm chứng, script tự tải
về. 2 mô hình còn lại (`mdx23c-vocinst.onnx`, `mms-aligner-uint8.onnx`) do lập trình viên gốc tự
chuyển đổi tay, không có nơi tải công khai — nếu chưa có sẵn 1 bản của project này chứa 2 file đó,
trỏ script tới nguồn:

```bash
./Scripts/setup-client-runtime.sh --skip-runtime --models-source "/đường/dẫn/5_KaraokeApp_source_with_git.zip"
# hoặc trỏ tới 1 thư mục chứa sẵn 3 file .onnx:
./Scripts/setup-client-runtime.sh --skip-runtime --models-source "/đường/dẫn/thư_mục"
```

Mọi file đều được kiểm tra mã băm (sha256) trước khi chấp nhận, bất kể lấy từ nguồn nào.

### 4. (Tuỳ chọn) Cài runtime cho tính năng AI "Không cần lời"

Chỉ cần bước này nếu muốn dùng thử Auto Karaoke lúc phát triển. Bỏ qua nếu chỉ quan tâm đường "Tôi
có lời" thủ công, hoặc nếu đang đóng gói bản phát hành (bản phát hành tự mang theo runtime riêng —
xem `Scripts/package-release.sh`).

```bash
./Scripts/setup-client-runtime.sh --skip-models
```

Script sẽ dựng 1 virtualenv Python ĐÚNG đường dẫn mà bản build dev của app tìm tới
(`~/qwen3_asr_m4_test/venv_official` trên Apple Silicon, `~/qwen3_asr_intel_test/venv_qwenasr` trên
Intel), cài đúng phiên bản PyTorch/transformers/qwen-asr đã ghim sẵn, và tải trước bộ trọng số
Qwen3-ASR 0.6B + 1.7B từ Hugging Face (vài GB, cần mạng đúng 1 lần).

Chạy script không kèm tham số nào (`./Scripts/setup-client-runtime.sh`) để làm cả 2 bước (mô hình +
runtime) trong 1 lần. Xem toàn bộ tuỳ chọn bằng `./Scripts/setup-client-runtime.sh --help`.

### 5. Build và chạy thử

```bash
./Scripts/pack-local.sh
open dist/KaraokeMaker.app
```

`pack-local.sh` build bản release, đóng thành `.app` hoàn chỉnh trong `dist/`, rồi ký ad-hoc. Sau
MỖI lần sửa code, chạy lại đúng lệnh này — đây là vòng lặp dev chuẩn của dự án. Chạy riêng
`swift build -c release` cũng được nếu chỉ cần kiểm tra code có biên dịch không, nhưng chỉ
`pack-local.sh` mới ra được app chạy được thật sự (icon, tài nguyên đi kèm, cờ bật runtime dev cho
Auto Karaoke…).

Lần mở đầu tiên có thể chậm hơn vài giây vì macOS quét app mới — các lần sau mở nhanh bình thường.

---

## Hướng dẫn sử dụng

### Màn hình Home

App mở ra là 1 thư viện project: lưới các project đã có (ảnh thu nhỏ, thời lượng, dung lượng file,
sửa lần cuối) kèm ô tìm kiếm, nút **Create project** (Tạo project), **Open another project…** (Mở
project khác — mở 1 file `.kbproj` bất kỳ trên đĩa), và Trash (Thùng rác). Đổi ngôn ngữ (Việt/Anh)
ở góc trên bên phải.

### Bắt đầu 1 project

**Create project** → nhập file nhạc vào. Chỉ cần đúng bước này là đủ để bắt đầu; mọi thứ khác (nền,
lớp đè, kiểu chữ) thêm sau cũng được.

### Lấy lời bài hát: 2 cách

Sau khi nhập nhạc xong, chọn 1 trong 2 cách lấy lời:

- **Tôi có lời bài hát** — dán hoặc gõ lời vào, app tự canh khớp với nhạc (kèm canh giờ tới từng
  chữ).
- **Không cần lời — Tự động tạo Karaoke** — app tự phân tích bài hát (tách giọng), nhận dạng bằng
  AI, rồi cho xem bản nháp kèm đánh dấu những chữ chưa chắc trước khi đưa qua ĐÚNG bộ máy canh giờ
  dùng chung với đường thủ công. Huỷ được bất cứ lúc nào, hoặc chuyển sang đường thủ công với lời
  máy nhận dạng đã điền sẵn.

Cả 2 đường đều ra cùng 1 kết quả: các dòng lời có mốc bắt đầu/kết thúc tới từng chữ, chỉnh tay lại
được sau đó.

### Màn hình chỉnh sửa (Editor)

Khi project đã có nhạc, app mở vào màn hình chỉnh sửa chính:

- **Cột trái** — chia tab: Create Karaoke (đường AI/thủ công ở trên), Video Background (nền), Add
  Text (thêm chữ), Audio Waveform (sóng âm), Media (kho file đã nhập).
- **Giữa** — xem trước video karaoke trực tiếp, kèm nút điều khiển phát (play/pause, tua, thanh
  kéo, giờ hiện tại/tổng), và công tắc bật/tắt Karaoke để xem có hoặc không có track chỉ-beat.
- **Cột phải** — Inspector: chỉnh kiểu chữ khi đang chọn 1 dòng lời, hoặc thuộc tính clip/lớp đè
  (vị trí, hoà trộn, mờ dần, màu) khi đang chọn thứ gì đó trên timeline.
- **Dưới cùng** — Timeline: track Nhạc / Lời / Karaoke cộng tối đa 3 làn Lớp đè, mỗi làn có công
  tắc tắt tiếng/ẩn/khoá riêng.

### Cơ bản về Timeline

- Bấm vào thước đo hoặc chỗ trống trên timeline để dời vạch phát (playhead).
- Kéo thân clip để dời; kéo mép clip để cắt (với clip lớp đè, mép trái cắt điểm VÀO của nguồn, chứ
  không chỉ dời vị trí trên timeline).
- ✂️ / ⌘K tách tại vạch đỏ. ⌘C/⌘V chép/dán. Delete xoá. Duplicate nhân đôi.
- Tự hít dính (snap) vào mép clip kế bên, vạch đỏ, mốc 0, và biên dòng lời (giữ ⌘ để tắt tạm thời).
- Zoom bằng nút trên thanh công cụ, ⌘=/⌘−/⌘0, ⌘+cuộn chuột, hoặc chụm 2 ngón. **Fit to window** (Vừa
  khung) zoom vừa đúng hết cả bài.
- Hoàn tác/làm lại (⌘Z/⌘⇧Z) đầy đủ cho mọi thao tác — kéo 1 clip tính là 1 bước hoàn tác, không
  phải từng khung hình lúc đang kéo.

### Chỉnh kiểu chữ karaoke

Chọn 1 dòng lời (hoặc không chọn gì để chỉnh kiểu mặc định) trong bảng **Karaoke Text Style** ở
Inspector: font, cỡ chữ, đậm/nghiêng/gạch chân, hoa/thường/viết hoa đầu từ, khoảng cách chữ, và màu
riêng cho chữ đã hát/chưa hát. Lưu tổ hợp của riêng bạn thành preset dùng lại được, hoặc bắt đầu từ
1 preset có sẵn.

### Nền, lớp đè, và sóng nhạc

- **Tab Video Background** — đặt ảnh tĩnh hoặc video làm nền, có hiệu ứng Ken Burns (lia + phóng)
  cho ảnh tĩnh.
- **Lớp đè** — kéo file từ kho Media thả xuống 1 làn lớp đè trên timeline. Mỗi clip lớp đè chỉnh
  được vị trí/tỉ lệ/xoay (kéo trực tiếp trên khung xem trước), độ mờ, chế độ hoà trộn (nhân, chồng
  sáng…), mờ dần vào/ra, và chuyển cảnh mờ sang clip trước. Lớp đè video có thể kèm tiếng riêng
  (mặc định tắt).
- **Sóng nhạc** — 7 kiểu sóng/phổ chạy theo nhạc thật, bật/tắt từ khu Add Text/sóng nhạc.

### Chỉnh màu

Bảng màu ở Inspector áp dụng đúng kiểu bộ máy chỉnh màu theo vùng tông màu thật — Phơi sáng, Tương
phản, Vùng sáng, Vùng tối, Điểm trắng, Điểm đen, Nhiệt độ màu, Sắc, Độ rực, Bão hoà, cộng thêm
Đường cong tông màu (kéo tay theo từng kênh màu), HSL (8 dải màu), LUT `.cube`, và tối góc — kèm
biểu đồ histogram/waveform/vectorscope. Áp dụng GIỐNG HỆT nhau cho nền và lớp đè, cả lúc xem trước
lẫn lúc xuất video — thấy sao thì ra vậy.

### Xuất file

Bấm **Export** (góc trên phải) rồi chọn:

- **SRT** — file phụ đề thuần.
- **ASS** — phụ đề kiểu karaoke có quét sáng theo từng chữ (thẻ `\kf`) cho phần mềm/trình phát hỗ
  trợ (ví dụ nhập vào CapCut).
- **Video nền trong suốt** — `.mov`, ProRes 4444 kèm kênh alpha, để ghép chữ/lớp đè karaoke lên
  đoạn phim khác trong phần mềm dựng khác.
- **Video nền đục** — `.mp4` (H.264) hoặc ProRes `.mov`, video hoàn chỉnh đã có sẵn nền bạn chọn.

Có sẵn nhiều cỡ khung hình từ 720p tới 4K, kể cả dọc (9:16, hợp Shorts/Reels) và vuông (1:1). Mọi
chỗ cắt/mờ dần đã chỉnh trên track nhạc chính đều được giữ nguyên lúc xuất.

### Lưu và file project

**Save** / **Save as** ghi ra 1 file `.kbproj` (JSON) chứa toàn bộ trạng thái project — nhạc, lời,
canh giờ, kiểu chữ, màu, kho media, tuỳ chọn xuất. Mở lại file `.kbproj` là khôi phục ĐÚNG y như lúc
lưu, kể cả trên máy Mac khác (media được đóng gói kèm project lúc lưu). Lịch sử hoàn tác không giữ
lại qua lần lưu/mở lại, nhưng mọi thứ khác của project thì có.

---

## Cấu trúc dự án (cho lập trình viên)

Nếu định sửa code của app, đọc `CLAUDE.md` trước — có ghi luật của dự án (đáng chú ý nhất: 1 danh
sách ngắn các file canh giờ/canh lời TUYỆT ĐỐI không được sửa, vì từng bị "cải thiện" làm hỏng nhiều
lần). Sau đó:

- `docs/ARCHITECTURE.md` — kiến trúc thật của app (ai giữ state gì, đồng hồ phát nhạc, hệ toạ độ
  timeline, mô hình concurrency).
- `docs/FEATURE_MATRIX.md` — từng tính năng kèm trạng thái (đã chạy/đã xác nhận/hỏng/…).
- `docs/PROGRESS.md` — nhật ký các việc đã làm, kèm bài phân tích gốc rễ cho những lỗi khó.
- `docs/KNOWN_ISSUES.md` — các lỗi còn mở + lịch sử điều tra.
- `docs/ROADMAP.md` / `docs/COLOR_ENGINE.md` / `docs/COLOR_ENGINE_AUDIT.md` — kế hoạch sắp tới và
  thiết kế chi tiết bộ máy chỉnh màu.
- `Scripts/` — `pack-local.sh` (vòng lặp build/chạy khi dev), `package-release.sh` (đóng gói bản
  phát hành tự chứa, kèm sẵn runtime AI trong `.app`), `setup-client-runtime.sh` (script cài đặt
  nói ở trên), `audit-release.sh`.

## Giới hạn đã biết

- Tính năng AI "Không cần lời" hiện đạt khoảng 75-80% độ chính xác từng chữ trên bài tiếng Việt
  chưa từng nghe qua (~22-25% tỉ lệ lỗi từ) — là điểm khởi đầu tốt để bạn xem lại/sửa qua giao diện
  đánh dấu-chữ-chưa-chắc, chứ chưa phải bản chép lời hoàn chỉnh. Xem `docs/KNOWN_ISSUES.md` để có
  số liệu chi tiết + những gì đã thử để cải thiện.
- Chưa ký Developer ID hay notarize — macOS Gatekeeper sẽ cảnh báo khi mở bản build chuyển giữa các
  máy cho tới khi việc này được làm (đã có kế hoạch, chưa bắt đầu).
- Chỉ 1 track nhạc chính duy nhất (không chỉnh nhạc nhiều clip) — đây là quyết định phạm vi có chủ
  đích, không phải thiếu tính năng.
