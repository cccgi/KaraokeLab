# KaraokeApp — mở lại 2026-09-08 (không còn standby)

**2026-09-08:** user quay lại KaraokeApp. Bug "không có tiếng" user báo ĐÃ SỬA (user xác nhận).
Đang làm: **đại tu UI cho giống CapCut** (dự án `future-ui-overhaul`), tham chiếu thêm app
**VocalCreationLab**. Đợt shell 1 xong (build OK): 1 thanh trên duy nhất + nút Xuất nổi bật +
rail icon panel trái + syncBar dịu. Chi tiết ở memory `future-ui-overhaul.md` mục "CapCut UI — ĐỢT SHELL".
Đợt sau: transport dưới preview, inspector icon-tabs, spacing toàn app, tách bớt ContentView.

---

# (cũ) STANDBY — KaraokeApp (tạm dừng 2026-09-07)

User chuyển sang project mới **Cham Music Box** (`~/ClaudeProjects/ChamMusicBox`).
KaraokeApp để **standby** — KHÔNG commit, file giữ nguyên trên đĩa. Mở lại khi user yêu cầu.

Build cuối: `swift build -c release` **OK** (2026-09-07). CHƯA push sang M4 buổi này
(khối `push-m4.sh` chưa chạy — code mới nhất chưa lên máy M4 để test).

## Đã làm buổi này — CHỜ TEST TRÊN M4
1. **Bỏ HEVC-alpha khi xuất video trong suốt** → luôn `.mov` ProRes 4444 (mã hoá nhanh).
   Gỡ enum `TransparentVideoQuality`, field `ExportSettings.videoCodec`, param `alphaCodec`,
   ô "Chất lượng" trong tab Xuất. → sửa lỗi "xuất rất chậm" user báo.
2. **Khôi phục tiến trình "Tạo Karaoke" 2 chặng** (phân tích nhạc → tick xanh → tạo karaoke)
   trong `ContentView.forcedAlignStep` bằng helper `phaseRow`. CHỈ sửa hiển thị, KHÔNG đụng
   `AdvancedKaraoke`/`LocalAligner`/`BeatSeparation`. Xem `KNOWN_ISSUES.md`.
3. **Tiếng clip VIDEO lớp đè** (`OverlayClip.videoAudioOn`, mặc định TẮT):
   - Preview: `Services/OverlayAudioMixer.swift` (AVPlayer chỉ-audio/clip, tách khỏi bài chính).
   - Xuất: `AudioMux.ExtraAudio` + `encodeAAC(extras:)` trộn AppleM4A.
4. **Preview overlay video 30fps** (`OverlayVideoFrameStore` grid 30 + prefetch).
5. **HDR policy màu** + **scopes cho khung video** (color engine).

## BUG CÒN MỞ — cần user
- **"Không có tiếng khi bấm play"** (bài nhạc chính). Chưa tái hiện được từ code; đã gate
  logic M-D sau `hasAudioTrim`. Cần user trả lời khi test lại: vạch đỏ có chạy? có thanh lỗi
  đỏ? icon track "Nhạc" là 🔊 hay 🔇? (Xem `KNOWN_ISSUES.md`.)

## HOÃN / KHÔNG LÀM
- M-G "karaoke thành track trên timeline" — dính karaoke, chờ user.
- M-D2 nhạc nhiều clip — ⛔ BỎ HẲN (user chốt).
- Tune hằng số kernel màu bằng ảnh test; unit/image test tự động.
- Slider âm lượng riêng cho tiếng clip video (giờ cố định 100%).

## KHI MỞ LẠI — đọc trước
`CLAUDE.md` + `docs/PROGRESS.md` + `docs/ROADMAP.md` + `docs/KNOWN_ISSUES.md` + file này.
Việc đầu tiên: push bản hiện tại sang M4, cho user test 5 mục ở trên + xác nhận bug "không có tiếng".
