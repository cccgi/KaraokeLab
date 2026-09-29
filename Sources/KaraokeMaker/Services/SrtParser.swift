import Foundation

/// Đọc file phụ đề `.srt` thành danh sách `LyricLine` kèm timing.
///
/// Định dạng SRT một khối:
/// ```
/// 1
/// 00:00:01,000 --> 00:00:04,000
/// Dòng lời thứ nhất
/// (có thể nhiều dòng)
/// ```
enum SrtParser {

    static func parse(_ raw: String) -> [LyricLine] {
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let blocks = text.components(separatedBy: "\n\n")
        var result: [LyricLine] = []

        for block in blocks {
            let rows = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let tcIndex = rows.firstIndex(where: { $0.contains("-->") }) else { continue }

            let tcParts = rows[tcIndex].components(separatedBy: "-->")
            guard tcParts.count == 2,
                  let start = timecode(tcParts[0]),
                  let end = timecode(tcParts[1]) else { continue }

            let bodyRows = rows[(tcIndex + 1)...]
            let joined = bodyRows.joined(separator: " ")
            let clean = stripMarkup(joined)
                .trimmingCharacters(in: .whitespaces)
                .precomposedStringWithCanonicalMapping
            guard !clean.isEmpty else { continue }

            result.append(LyricLine(text: clean, start: start, end: max(end, start), source: .manual))
        }

        return result
    }

    /// "00:01:02,500" (hoặc dấu chấm) -> giây. Bỏ qua thông tin toạ độ phía sau nếu có.
    private static func timecode(_ string: String) -> TimeInterval? {
        let firstToken = string
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: " ")
            .first
            .map(String.init) ?? ""

        let parts = firstToken.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Bỏ thẻ `<i> </i>` và `{\anX}` thường gặp trong phụ đề.
    private static func stripMarkup(_ string: String) -> String {
        string
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
    }
}
