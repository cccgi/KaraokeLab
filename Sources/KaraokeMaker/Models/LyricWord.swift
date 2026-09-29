import Foundation

/// Một "từ" (hoặc âm tiết) trong một dòng lời, kèm timing riêng.
///
/// Phase 0-6 CHƯA dùng tới. Nó tồn tại từ đầu để sau này nâng lên
/// word-level karaoke mà KHÔNG phải đổi định dạng file:
/// - `LyricLine.words` rỗng  -> app chạy ở chế độ line-level.
/// - `LyricLine.words` có dữ liệu -> app tự chuyển sang word-level.
struct LyricWord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var text: String

    /// Thời điểm bắt đầu / kết thúc, tính bằng GIÂY từ đầu bài hát.
    /// `nil` = chưa gán timing.
    var start: TimeInterval?
    var end: TimeInterval?

    init(id: UUID = UUID(), text: String, start: TimeInterval? = nil, end: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.start = start
        self.end = end
    }
}
