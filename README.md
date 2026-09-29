# KaraokeMaker

Ứng dụng tạo karaoke chạy local trên macOS.

Luồng làm việc dự kiến:

```
Import Audio (MP3/WAV) + nhập Lyrics
        -> Đồng bộ timing (line-level, sau này word-level)
        -> Karaoke Editor (waveform + timeline)
        -> Preview
        -> Export: (1) SRT   (2) Transparent Karaoke Video (ProRes 4444, alpha)
        -> Lưu / mở lại project (.kbproj)
```

## Yêu cầu

- macOS 13 (Ventura) trở lên
- Xcode 15.2 trở lên

## Chạy thử

Mở bằng Xcode:

```bash
open -a Xcode Package.swift
```

Chọn scheme `KaraokeMaker` rồi bấm Run (nút ▶), hoặc phím `Cmd + R`.

Chạy bằng dòng lệnh:

```bash
swift run KaraokeMaker
```

## Trạng thái

- [x] Phase 0 – Khung dự án + data model + lưu/mở project
- [x] Phase 1 – Import audio + play/pause/seek/timeline
- [x] Phase 2 – Nhập lời + tách dòng
- [x] Phase 3 – Gán timing theo dòng ("gõ nhịp")
- [x] Phase 4 – Timeline editor trực quan (waveform, kéo thả khối)
- [x] Phase 5 – Preview có highlight quét chữ
- [x] Phase 6 – Export SRT  ← MVP
- [x] Phase 7 – Export Transparent Karaoke Video (ProRes 4444, alpha)
- [x] Phase 8 – Bảng Style (Inspector): font, màu, viền, bóng, bố cục
- [ ] Phase 9 – Word-level timing + export ASS + auto-timing
- [ ] Phase 10 – Mode C (video nền + chữ) + thêm tỉ lệ khung hình
- [ ] Phase 8 – Style Panel
- [ ] Phase 9 – Word-level timing + export ASS + auto-timing
- [ ] Phase 10 – Mode C (render kèm video nền) + thêm tỉ lệ khung hình
