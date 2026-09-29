import Foundation

/// Tách dòng thành từng "chữ" (âm tiết) và gán timing cho mỗi chữ.
/// 9.1: chia đều tự động theo độ dài chữ. Sau này có thể cắm provider dò audio.
enum WordTiming {

    /// Tách theo khoảng trắng + xuống dòng. Tiếng Việt viết rời từng âm tiết nên
    /// mỗi token ≈ một chữ hát.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\u{00A0}" })
            .map(String.init)
    }

    /// Chia đều khoảng `start…end` của dòng cho từng chữ, trọng số = số ký tự.
    /// Rỗng nếu dòng chưa gán đủ timing hoặc không có chữ nào.
    static func distribute(_ line: LyricLine) -> [LyricWord] {
        guard let start = line.start, let end = line.end, end > start else { return [] }
        let toks = tokens(line.text)
        guard !toks.isEmpty else { return [] }
        if toks.count == 1 {
            return [LyricWord(text: toks[0], start: start, end: end)]
        }

        let weights = toks.map { Double(max(1, $0.count)) }
        let totalWeight = weights.reduce(0, +)
        let span = end - start

        var cursor = start
        var out: [LyricWord] = []
        out.reserveCapacity(toks.count)
        for (i, tok) in toks.enumerated() {
            let wStart = cursor
            let wEnd: TimeInterval = (i == toks.count - 1)
                ? end
                : min(end, cursor + span * weights[i] / totalWeight)
            out.append(LyricWord(text: tok, start: wStart, end: wEnd))
            cursor = wEnd
        }
        return out
    }
}
