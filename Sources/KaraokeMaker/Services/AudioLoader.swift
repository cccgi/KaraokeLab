import Foundation
import AVFoundation

/// Đọc metadata của file nhạc và tạo `AudioReference` để lưu vào project.
enum AudioLoader {

    /// Tạo tham chiếu audio từ URL người dùng chọn.
    /// Lấy thêm thời lượng + sample rate nếu đọc được.
    static func makeReference(for url: URL) -> AudioReference {
        var reference = AudioReference(
            lastKnownPath: url.path,
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        )

        if let file = try? AVAudioFile(forReading: url) {
            let sampleRate = file.processingFormat.sampleRate
            reference.sampleRate = sampleRate
            if sampleRate > 0 {
                reference.duration = Double(file.length) / sampleRate
            }
        }

        return reference
    }

    /// Từ một `AudioReference` đã lưu, tìm lại file thật trên đĩa.
    /// Ưu tiên bookmark (chịu được việc di chuyển/đổi tên thư mục),
    /// sau đó mới thử đường dẫn cũ.
    static func resolveURL(from reference: AudioReference) -> URL? {
        if let bookmark = reference.bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let fallback = URL(fileURLWithPath: reference.lastKnownPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}
