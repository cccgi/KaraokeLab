import Foundation

/// Preset style — bấm 1 phát áp cả bộ màu/viền/bóng/glow/nền.
struct StylePreset: Identifiable {
    let id = UUID()
    let name: String
    /// Màu chữ + màu nền ô xem trước "Aa".
    let previewText: RGBAColor
    let previewBackground: RGBAColor
    /// Áp vào style câu chính.
    let apply: (inout KaraokeStyle) -> Void
    /// (Tuỳ chọn) áp luôn cho style câu nhắc.
    var applyNext: ((inout KaraokeStyle) -> Void)? = nil

    /// 2 preset MẶC ĐỊNH — do người dùng lưu, promote thành built-in (2026-09-09). Preset cũ bỏ hết.
    /// Tên hiển thị: "Karaoke" (mine0 — mặc định, luôn 2 dòng) & "Lyric" (mine1).
    static let all: [StylePreset] = [
        StylePreset(
            name: "Karaoke",
            previewText: RGBAColor(r: 1, g: 1, b: 1, a: 1),
            previewBackground: RGBAColor(r: 0.08, g: 0.08, b: 0.08, a: 1),
            apply: { $0 = .mine0 },
            applyNext: { $0 = .mine0Next }
        ),
        StylePreset(
            name: "Lyric",
            previewText: RGBAColor(r: 1, g: 1, b: 1, a: 1),
            previewBackground: RGBAColor(r: 0.10, g: 0.12, b: 0.16, a: 1),
            apply: { $0 = .mine1 },
            applyNext: { $0 = .mine1Next }
        )
    ]
}
