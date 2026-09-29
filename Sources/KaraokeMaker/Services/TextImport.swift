import Foundation
import AppKit

/// Nhận diện định dạng file lời và rút nội dung ra.
enum TextImport {

    enum Outcome {
        /// Văn bản thuần: đưa vào ô nhập lời, người dùng bấm "Tách thành dòng".
        case plainText(String)
        /// Đã có sẵn timing (file .srt): tạo luôn danh sách dòng.
        case timedLines(lines: [LyricLine], joinedText: String)
    }

    enum ImportError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let name): return L("Không đọc được nội dung file:") + " \(name)"
            }
        }
    }

    static func load(from url: URL) throws -> Outcome {
        let ext = url.pathExtension.lowercased()

        // --- SRT: lấy cả timing ---
        if ext == "srt" {
            let raw = try readPlainString(url)
            let lines = SrtParser.parse(raw)
            let joined = lines.map(\.text).joined(separator: "\n")
            return .timedLines(lines: lines, joinedText: joined)
        }

        // --- Text thuần ---
        if ext == "txt" || ext == "text" || ext.isEmpty {
            return .plainText(normalize(try readPlainString(url)))
        }

        // --- RTF / RTFD / DOC / DOCX / ODT / HTML: dùng bộ đọc của macOS ---
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return .plainText(normalize(attributed.string))
        }

        // --- Phương án cuối: thử đọc như text thuần ---
        if let raw = try? readPlainString(url) {
            return .plainText(normalize(raw))
        }

        throw ImportError.unreadable(url.lastPathComponent)
    }

    // MARK: - Riêng tư

    private static func readPlainString(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        // Để hệ thống tự đoán bảng mã (một số file .txt cũ không phải UTF-8).
        return try String(contentsOf: url)
    }

    private static func normalize(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }
}
