import Foundation

/// Tách văn bản lời bài hát thành từng dòng sạch.
enum LyricsParser {

    /// - Chuẩn hoá xuống dòng (\r\n, \r -> \n)
    /// - Cắt khoảng trắng thừa ở hai đầu mỗi dòng
    /// - Gộp nhiều dấu cách liên tiếp thành một
    /// - Bỏ các dòng trống
    /// - Chuẩn hoá Unicode về NFC để dấu tiếng Việt luôn hiển thị/định dạng đúng
    static func split(_ raw: String) -> [String] {
        let unified = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        return unified
            .components(separatedBy: "\n")
            .map { line in
                line
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
                    .precomposedStringWithCanonicalMapping
            }
            .filter { !$0.isEmpty }
    }
}
