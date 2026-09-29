import Foundation

/// Sửa CHỮ của 1 dòng lời đã canh xong (người dùng chỉnh tay, tab "Sửa lời") mà GIỮ mốc timing.
///
/// Vì sao không chỉ đổi `line.text`: khi dòng đã canh từng chữ, renderer + timeline vẽ theo
/// `line.words` (mỗi ô 1 chữ + mốc riêng) — đổi `text` suông thì karaoke KHÔNG đổi chữ. Ở đây
/// dựng lại `words` từ text mới theo 3 mức:
///  1. Cùng số chữ  → thay 1-1, MỌI mốc giữ nguyên (sửa chính tả / dấu).
///  2. Khác số chữ  → so khớp chữ cũ/mới (LCS): chữ không đổi giữ nguyên mốc; chữ thêm mới lấy
///     thời gian từ chỗ chữ bị thay hoặc khe trống kề bên (mượn tối đa 40% chữ kề nếu chật); chữ
///     bị xoá thuần tuý để lại khe trống — KHÔNG làm xê dịch các chữ còn lại.
///  3. Viết lại hoàn toàn (không chữ nào khớp) → chia lại theo độ dài chữ trong đúng khoảng cũ.
/// Đây là đường CHỈNH TAY — không đổi cách thuật toán canh lời tính timing.
enum LyricLineEditor {

    /// 1 dòng người dùng gõ → bỏ xuống dòng / tab, gộp khoảng trắng, NFC (giống `LyricsParser`).
    static func normalize(_ raw: String) -> String {
        var s = raw
        for sep in ["\r\n", "\n", "\r", "\t", "\u{2028}", "\u{2029}"] {
            s = s.replacingOccurrences(of: sep, with: " ")
        }
        s = s.replacingOccurrences(of: "[ \u{00A0}]+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// Dòng mới sau khi áp `raw`; `nil` = không đổi gì (giống hệt / rỗng → coi như huỷ, KHÔNG xoá dòng).
    static func apply(_ raw: String, to line: LyricLine) -> LyricLine? {
        let text = normalize(raw)
        guard !text.isEmpty, text != line.text else { return nil }
        let toks = WordTiming.tokens(text)
        guard !toks.isEmpty else { return nil }

        var out = line
        out.text = text
        let old = line.words
        if old.isEmpty { return out }                       // dòng chạy theo-dòng: chỉ đổi chữ

        if old.count == toks.count {                        // mức 1
            for k in old.indices { out.words[k].text = toks[k] }
            return out
        }

        let fullyTimed = old.allSatisfy { $0.start != nil && $0.end != nil }
        if !fullyTimed {
            let s = old.first?.start ?? line.start
            let e = old.last?.end ?? line.end
            if let s, let e, e > s { out.words = spread(toks, from: s, to: e) }
            else { out.words = [] }
            return out
        }
        out.words = remap(old: old, toks: toks)             // mức 2 / 3
        return out
    }

    // MARK: - Mức 2 / 3

    /// Khoá so khớp: bỏ hoa/thường, dấu, dấu câu đầu/cuối.
    private static func key(_ t: String) -> String {
        t.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    static func remap(old: [LyricWord], toks: [String]) -> [LyricWord] {
        let n = old.count, m = toks.count
        let ok = old.map { key($0.text) }, nk = toks.map(key)

        // LCS: dp[i][j] = độ dài chuỗi con chung của old[i...] và toks[j...].
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = ok[i] == nk[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var newToOld = Array<Int?>(repeating: nil, count: m)
        var i = 0, j = 0
        while i < n, j < m {
            if ok[i] == nk[j], dp[i][j] == dp[i + 1][j + 1] + 1 { newToOld[j] = i; i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 }
            else { j += 1 }
        }

        var res: [LyricWord?] = Array(repeating: nil, count: m)
        for j in 0..<m {
            if let o = newToOld[j] {
                res[j] = LyricWord(id: old[o].id, text: toks[j], start: old[o].start, end: old[o].end)
            }
        }

        // Duyệt từng CỤM chữ mới liên tiếp chưa có mốc.
        var a = 0
        while a < m {
            if res[a] != nil { a += 1; continue }
            var b = a
            while b < m, res[b] == nil { b += 1 }
            let prevNew = a - 1 >= 0 ? a - 1 : nil
            let nextNew = b < m ? b : nil
            let prevOld = prevNew.flatMap { newToOld[$0] }
            let nextOld = nextNew.flatMap { newToOld[$0] }
            let region = ((prevOld ?? -1) + 1)..<(nextOld ?? n)             // chữ cũ bị thay/xoá trong cụm
            let group = Array(toks[a..<b])

            if !region.isEmpty {
                let rs = old[region.lowerBound].start ?? 0
                let re = old[region.upperBound - 1].end ?? rs
                if re - rs >= 0.06 * Double(group.count) {                  // thay chữ: dùng đúng thời gian chữ bị thay
                    let ws = spread(group, from: rs, to: re)
                    for (k, w) in ws.enumerated() { res[a + k] = w }
                    a = b; continue
                }
            }
            insertPure(group: group, at: a, prevNew: prevNew, nextNew: nextNew,
                       line0: old.first?.start, lineEnd: old.last?.end, res: &res)
            a = b
        }
        return res.compactMap { $0 }
    }

    /// Chữ thêm mới KHÔNG có chữ cũ nào để thay: đặt vào khe kề bên, chật thì mượn tối đa 40% mỗi chữ kề.
    private static func insertPure(group: [String], at a: Int, prevNew: Int?, nextNew: Int?,
                                   line0: Double?, lineEnd: Double?, res: inout [LyricWord?]) {
        let chars = group.reduce(0) { $0 + max(1, $1.count) }
        let desired = 0.10 * Double(group.count) + 0.05 * Double(chars)
        let prevEnd = prevNew.flatMap { res[$0]?.end }
        let nextStart = nextNew.flatMap { res[$0]?.start }
        var spanStart = prevEnd ?? line0 ?? nextStart ?? 0
        var spanEnd = nextStart ?? lineEnd ?? (spanStart + desired)
        if spanEnd < spanStart { spanEnd = spanStart }

        let deficit = desired - (spanEnd - spanStart)
        if deficit > 0 {
            var bp = 0.0, bn = 0.0
            if let p = prevNew, let w = res[p], let s = w.start, let e = w.end { bp = min(deficit / 2, 0.4 * max(0, e - s)) }
            if let q = nextNew, let w = res[q], let s = w.start, let e = w.end { bn = min(deficit - bp, 0.4 * max(0, e - s)) }
            if bn < deficit - bp, let p = prevNew, let w = res[p], let s = w.start, let e = w.end {
                bp = min(deficit - bn, 0.4 * max(0, e - s))                  // bên kia không đủ → mượn thêm bên này
            }
            if bp > 0, let p = prevNew, let cur = res[p]?.end { res[p]?.end = cur - bp; spanStart -= bp }
            if bn > 0, let q = nextNew, let cur = res[q]?.start { res[q]?.start = cur + bn; spanEnd += bn }
        }
        let avail = spanEnd - spanStart
        let use = min(avail, desired)
        let start = spanStart + max(0, (avail - use) / 2)                     // đặt giữa khe
        let ws = spread(group, from: start, to: start + max(use, 0.02 * Double(group.count)))
        for (k, w) in ws.enumerated() { res[a + k] = w }
    }

    /// Chia `[from, to]` liền mạch cho các chữ theo độ dài ký tự.
    private static func spread(_ toks: [String], from: Double, to: Double) -> [LyricWord] {
        let w = toks.map { Double(max(1, $0.count)) }
        let total = w.reduce(0, +)
        let span = max(0, to - from)
        var cur = from
        var out: [LyricWord] = []
        for (k, t) in toks.enumerated() {
            let d = span * w[k] / total
            out.append(LyricWord(text: t, start: cur, end: cur + d))
            cur += d
        }
        return out
    }
}
