import Foundation

/// Timing này do người dùng tự làm hay do máy đề xuất (auto-timing sau này).
enum TimingSource: String, Codable {
    case manual
    case auto
}

/// Một dòng / câu lời bài hát, kèm timing.
///
/// Thời gian LUÔN tính bằng GIÂY (số thực) từ đầu bài hát — đây là
/// nguồn sự thật duy nhất. SRT, frame video, preview đều suy ra từ đây.
struct LyricLine: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// Toàn bộ nội dung dòng, giữ nguyên Unicode tiếng Việt (chuẩn hóa NFC).
    var text: String

    /// Thời điểm dòng xuất hiện / biến mất, bằng giây. `nil` = chưa gán timing.
    var start: TimeInterval?
    var end: TimeInterval?

    var source: TimingSource = .manual

    /// Timing theo từng từ. RỖNG = dòng này chạy ở chế độ line-level.
    var words: [LyricWord] = []

    /// Đánh dấu người hát (nil = không đánh dấu, dùng màu chung).
    var singer: SingerRole?
    /// Màu RIÊNG cho câu này (chỉ áp khi `singer != nil`) — đổi màu chữ ĐANG hát.
    var lineColor: RGBAColor?

    init(
        id: UUID = UUID(),
        text: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        source: TimingSource = .manual,
        words: [LyricWord] = [],
        singer: SingerRole? = nil,
        lineColor: RGBAColor? = nil
    ) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
        self.source = source
        self.words = words
        self.singer = singer
        self.lineColor = lineColor
    }

    /// Đã có đủ mốc bắt đầu và kết thúc chưa.
    var isTimed: Bool { start != nil && end != nil }

    /// Có timing chi tiết theo từng từ hay không.
    var hasWordTiming: Bool { !words.isEmpty }

    /// Thời lượng dòng (giây), nil nếu chưa gán đủ timing.
    var duration: TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end - start)
    }
}
