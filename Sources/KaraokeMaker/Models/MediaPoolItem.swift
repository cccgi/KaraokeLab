import Foundation

/// (U6) 1 món ảnh đã NHẬP vào "kho media" của project — CHƯA CHẮC đã đặt lên timeline.
/// Kéo từ kho thả xuống timeline mới thật sự tạo ra 1 `OverlayClip` (đặt ở mốc phát hiện tại).
/// Giai đoạn đầu: CHỈ ẢNH — nhất quán với `OverlayClip` hiện chỉ hỗ trợ ảnh tĩnh.
struct MediaPoolItem: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case image, audio, video }

    var id = UUID()
    var name: String = ""
    var kind: Kind = .image
    var lastKnownPath: String = ""
    var bookmark: Data?

    init(url: URL) {
        self.name = url.lastPathComponent
        self.lastKnownPath = url.path
        self.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let ext = url.pathExtension.lowercased()
        if ["mp3", "wav", "aiff", "aif", "m4a", "flac", "aac", "ogg"].contains(ext) { self.kind = .audio }
        else if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) { self.kind = .video }
        else { self.kind = .image }
    }

    // Codable "khoan dung": file cũ thiếu `kind` → mặc định .image.
    enum CodingKeys: String, CodingKey { case id, name, kind, lastKnownPath, bookmark }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .image
        lastKnownPath = try c.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? ""
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
    }

    /// Tìm lại file thật trên đĩa: ưu tiên bookmark, rồi đường dẫn cũ.
    func resolveURL() -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: lastKnownPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
