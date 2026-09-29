import Foundation

/// Đọc file phụ đề .ass / .ssa → `[LyricLine]`.
/// Nếu dòng Dialogue có tag karaoke `{\k..}` / `{\kf..}` thì lấy luôn MỐC TỪNG CHỮ.
enum AssParser {

    static func parse(_ content: String) -> [LyricLine] {
        var out: [LyricLine] = []
        // `\.isNewline` xử lý cả CRLF (\r\n là 1 Character trong Swift).
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("dialogue:") else { continue }

            // Dialogue: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            let body = line.drop(while: { $0 != ":" }).dropFirst()
            let fields = body.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count == 10,
                  let start = time(fields[1]), let end = time(fields[2]), end > start else { continue }

            let (text, words) = karaoke(String(fields[9]), lineStart: start, lineEnd: end)
            let clean = text.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }

            var l = LyricLine(text: clean, start: start, end: end, source: .auto)
            if words.count > 1 { l.words = words }
            out.append(l)
        }
        out.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        return out
    }

    /// "H:MM:SS.cc" → giây.
    private static func time(_ s: Substring) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private static let tokenRE = try! NSRegularExpression(pattern: #"(\{[^}]*\})|([^{}]+)"#)
    private static let kRE = try! NSRegularExpression(pattern: #"\\k[fo]?(\d+)"#, options: .caseInsensitive)

    /// Trả (text sạch, [words] nếu có \k).
    private static func karaoke(_ raw0: String, lineStart: Double, lineEnd: Double)
        -> (String, [LyricWord]) {
        let raw = raw0.replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
        let ns = raw as NSString

        var words: [LyricWord] = []
        var plain = ""
        var cursor = lineStart
        var pendingDur: Double?
        var hadK = false

        tokenRE.enumerateMatches(in: raw, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let seg = ns.substring(with: m.range)
            if seg.hasPrefix("{") {
                if let km = kRE.firstMatch(in: seg, range: NSRange(location: 0, length: (seg as NSString).length)),
                   let r = Range(km.range(at: 1), in: seg), let cs = Double(seg[r]) {
                    // 2 tag \k liền nhau (không chữ ở giữa) = âm tiết RỖNG → đẩy con trỏ.
                    if let prev = pendingDur { cursor += prev }
                    pendingDur = cs / 100.0
                    hadK = true
                }
            } else {
                let txt = seg.trimmingCharacters(in: .whitespaces)
                if let d = pendingDur {
                    if !txt.isEmpty {
                        words.append(LyricWord(text: txt, start: cursor, end: cursor + d))
                        plain += (plain.isEmpty ? "" : " ") + txt
                    }
                    cursor += d
                    pendingDur = nil
                } else if !txt.isEmpty {
                    plain += (plain.isEmpty ? "" : " ") + txt
                }
            }
        }

        if hadK, var last = words.last, last.end ?? 0 < lineEnd {
            last.end = lineEnd
            words[words.count - 1] = last
        }
        return (hadK ? plain : stripTags(raw), hadK ? words : [])
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    }
}
