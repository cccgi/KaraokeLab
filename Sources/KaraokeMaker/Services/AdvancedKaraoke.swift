import Foundation
import AVFoundation

/// Ngôn ngữ (giữ cho tương thích UI — bước canh giờ mới không cần nghe‑chép nên không dùng tới).
enum AdvancedLang: String, CaseIterable, Identifiable {
    case vi, en, auto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vi:   return "Tiếng Việt"
        case .en:   return "Tiếng Anh"
        case .auto: return "Tự động"
        }
    }
    var localeID: String {
        switch self {
        case .vi:   return "vi-VN"
        case .en:   return "en-US"
        case .auto: return Locale.current.identifier
        }
    }
}

/// Điều phối phần "Tạo Karaoke" từ lời người dùng dán:
///   tách giọng → ĐI TÌM từng đoạn lời trong bài (kể cả đoạn hát lại) → ráp theo thời gian → `[LyricLine]`.
///
/// TƯ DUY: lời người dùng là GỐC — không nghe‑chép, không đoán chữ, không rớt dòng.
/// Máy chỉ đi tìm mỗi đoạn được hát ở những lúc nào.
@MainActor
final class AdvancedKaraoke: ObservableObject {

    enum Phase: Equatable {
        case idle, separating, downloadingModel, listening, matching, aligning, done
        case failed(String)

        /// Thứ tự để so "đã qua bước này chưa" (UI đọc `.rank`).
        var rank: Int {
            switch self {
            case .idle:             return 0
            case .separating:       return 1
            case .downloadingModel: return 2
            case .listening:        return 3
            case .matching:         return 4
            case .aligning:         return 5
            case .done:             return 6
            case .failed:           return -1
            }
        }
    }

    struct Outcome {
        var lines: [LyricLine]
        var fullLyrics: String?   // lời đã bung đủ đoạn lặp
        var note: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var listenProgress: Double = 0
    @Published private(set) var resultNote: String = ""

    var isBusy: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    func reset() {
        phase = .idle
        listenProgress = 0
        resultNote = ""
    }

    /// Dán lời (ĐỦ hoặc chỉ viết đoạn lặp MỘT lần đều được) + audio → canh giờ từng chữ.
    /// Trả `nil` nếu lỗi (đọc `phase` để lấy thông báo).
    func run(audio: URL,
             pastedLyrics: String,
             lang: AdvancedLang = .vi,
             quality: BeatSeparation.Quality = .fast,
             beatSep: BeatSeparation,
             aligner: ForcedAligner) async -> Outcome? {

        guard !isBusy else { return nil }
        _ = lang
        listenProgress = 0
        resultNote = ""

        let blocks = Self.parseBlocks(pastedLyrics)
        let flatCount = blocks.reduce(0) { $0 + $1.count }
        guard flatCount >= 1 else {
            phase = .failed("Chưa dán lời.")
            return nil
        }

        // 1) Tách giọng (dùng lại cache nếu có).
        phase = .separating
        let sep = await beatSep.separateLocal(source: audio, quality: quality)
        let vocal = sep?.vocal ?? audio

        // 2) ĐI TÌM từng đoạn lời trong bài (kể cả đoạn hát lại) — thuần forced-alignment, offline.
        phase = .matching
        let onProg: @Sendable (Double) -> Void = { p in
            Task { @MainActor [weak self] in self?.listenProgress = p }
        }
        let searched: [AlignResponse.Line] = (try? await Task.detached(priority: .userInitiated) {
            try LocalAligner.alignBySearch(vocalURL: vocal, mixURL: audio, blocks: blocks, progress: onProg)
        }.value) ?? []

        // 3) Dựng dòng + làm sạch nhẹ.
        phase = .aligning
        var lines: [LyricLine] = []
        var weak = 0
        if !searched.isEmpty {
            let built = ForcedAligner.buildLines(from: searched, preroll: 2.0)
            lines = built.0
            weak = built.1
        }
        if lines.isEmpty {
            // dự phòng: canh cả bài với lời ghép "một lượt"
            let full = blocks.flatMap { $0 }.joined(separator: "\n")
            guard let r = await aligner.run(vocalURL: vocal, lyrics: full), !r.lines.isEmpty else {
                phase = .failed("Canh giờ không ra kết quả — kiểm tra lại lời / nhạc.")
                return nil
            }
            lines = r.lines
            weak = r.weakLines
        }

        lines = Self.capRunaway(lines)
        lines = Self.smoothWordGaps(lines)
        lines = Self.borrowRepeatRhythm(lines)          // câu lặp loạn nhịp → mượn nhịp lần hát đầu
        let songDur = (try? await AVURLAsset(url: audio).load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 1e9
        lines = Self.tidyOverlaps(lines, songDur: songDur)

        phase = .done
        let weakNote = weak > 0 ? " · \(weak) dòng nên nghe lại" : ""
        resultNote = "✅ \(lines.count) dòng\(weakNote)"
        let full = lines.map(\.text).joined(separator: "\n")
        return Outcome(lines: lines, fullLyrics: full, note: resultNote)
    }

    /// Tách lời dán thành KHỐI: ngăn bởi DÒNG TRỐNG hoặc DÒNG NHÃN ([Verse], (Chorus)…).
    /// Nhãn bị bỏ. Mỗi khối = một đoạn hát; đoạn lặp chỉ cần gõ một lần.
    static func parseBlocks(_ raw: String) -> [[String]] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
                      .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = []
        var cur: [String] = []
        func flush() { if !cur.isEmpty { blocks.append(cur); cur = [] } }
        for rl in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rl.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let f = line.first, let l = line.last,
               ((f == "[" && l == "]") || (f == "(" && l == ")")), line.count <= 40 {
                flush(); continue
            }
            cur.append(line)
        }
        flush()
        return blocks
    }

    /// Câu là BẢN LẶP (cùng chữ) của một câu HÁT TRƯỚC ĐÓ, mà mốc chữ trong câu bị LOẠN NHỊP
    /// (MMS canh bản lặp hay dồn gấp âm tiết đầu + để 1 âm tiết nuốt phần dư) → CHÉP TỈ LỆ nhịp
    /// chữ từ lần hát ĐẦU (bản mốc sạch), co giãn cho vừa cửa sổ câu này. Mốc ĐẦU/CUỐI câu giữ
    /// nguyên — chỉ nắn nhịp chữ bên trong.
    nonisolated static func borrowRepeatRhythm(_ lines: [LyricLine]) -> [LyricLine] {
        func norm(_ s: String) -> String {
            s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
                .lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func wdur(_ w: LyricWord) -> Double { max(0, (w.end ?? 0) - (w.start ?? 0)) }
        // "sạch": ≥3 chữ, đơn điệu, không chữ nào < 0.10s hay > 2.2s.
        func isClean(_ l: LyricLine) -> Bool {
            guard l.words.count >= 3 else { return false }
            var prev = -1.0
            for w in l.words {
                guard let s = w.start, let e = w.end, e >= s, e - s >= 0.10, e - s <= 2.2 else { return false }
                if s < prev - 0.02 { return false }
                prev = s
            }
            return true
        }
        var out = lines
        // khuôn: chữ-chuẩn-hoá -> (mảng TỈ LỆ độ dài chữ, TỔNG thời lượng) từ lần "sạch" ĐẦU TIÊN.
        var tplFrac: [String: [Double]] = [:]
        var tplDur: [String: Double] = [:]
        for l in out where isClean(l) {
            let key = norm(l.text)
            guard tplFrac[key] == nil else { continue }
            let ds = l.words.map { max(0.05, wdur($0)) }
            let tot = ds.reduce(0, +)
            if tot > 0 { tplFrac[key] = ds.map { $0 / tot }; tplDur[key] = tot }
        }
        // Với MỌI câu là bản LẶP (có khuôn từ lần hát đầu) → áp NHỊP CHỮ của khuôn.
        // Câu lặp mà timing vốn đã tốt thì nhịp ~ trùng khuôn ⇒ gần như không đổi;
        // câu lặp bị lệch (lướt/ngân sai ở mấy chữ đầu) ⇒ được nắn theo lần hát chuẩn.
        for i in out.indices {
            let l = out[i]
            let key = norm(l.text)
            guard l.words.count >= 3,
                  let frac = tplFrac[key], let tdur = tplDur[key], frac.count == l.words.count,
                  let S0 = l.words.first?.start ?? l.start,
                  let E0 = l.words.last?.end ?? l.end, E0 > S0 + 0.3 else { continue }
            let S = S0
            // Cửa sổ quá rộng (MMS kéo giãn mốc CÂU) → siết, tối đa gấp đôi lần hát đầu.
            var E = E0
            if E - S > tdur * 2.0 { E = S + tdur * 2.0 }
            let win = E - S
            var ws = l.words
            let n = ws.count

            // NHỊP THÂN CÂU (n-1 chữ đầu) THEO KHUÔN, chỉ giãn NHẸ (≤20%). Phần bài hát
            // lặp bị KÉO DÀI thêm (thường ở CÂU CHÓT) → DỒN VÀO CHỮ CUỐI (nốt ngân), không
            // rải đều ra mọi âm tiết. Nếu câu lặp hát NHANH hơn khuôn → co thân câu cho vừa.
            let fracBody = Array(frac.prefix(n - 1))
            let sumBody = max(1e-6, fracBody.reduce(0, +))
            let bodyTpl = sumBody * tdur
            let extra = max(0, win - tdur)
            var bodyDur = bodyTpl * (1.0 + min(0.20, extra / max(0.5, tdur)))
            let minLast = 0.20
            if bodyDur > win - minLast { bodyDur = max(0.3, win - minLast) }   // hát nhanh → co thân
            var acc = S
            for k in 0..<(n - 1) {
                ws[k].start = acc
                ws[k].end = acc + max(0.06, bodyDur * fracBody[k] / sumBody)
                acc = ws[k].end ?? acc
            }
            ws[n - 1].start = acc
            ws[n - 1].end = max(acc + minLast, E)

            out[i].words = ws
            out[i].start = min(out[i].start ?? S, S)
            out[i].end = E
        }
        return out
    }

    /// DỌN CUỐI CÙNG — bảo đảm: (a) KHÔNG câu nào đè câu trước; (b) không câu nào dài quá
    /// ~0.9s/chữ (chữ ngân hoặc nuốt khoảng im); (c) KHÔNG bỏ câu nào (user gõ đủ → mọi câu
    /// phải hiện, kể cả điệp khúc lặp gõ liền nhau ở cuối bài). Đè/dài → đẩy về sau + co lại,
    /// dồn dần trong phạm vi bài. Sửa lỗi "2 dòng cuối lặp lại bị rối / mất 1 câu lặp".
    nonisolated static func tidyOverlaps(_ lines: [LyricLine], songDur: Double) -> [LyricLine] {
        func key(_ l: LyricLine) -> Double {
            if let w = l.words.first?.start { return w }
            return l.start ?? 0
        }
        var out = lines.sorted { key($0) < key($1) }
        var prevEnd = 0.0
        for i in out.indices {
            var ws = out[i].words
            if ws.isEmpty {
                out[i].start = prevEnd + 0.05
                out[i].end = prevEnd + 0.35
                prevEnd = out[i].end ?? prevEnd
                continue
            }
            var s = ws.first?.start ?? prevEnd
            var e = ws.last?.end ?? s
            // (a) đẩy khỏi vùng đè câu trước
            if s < prevEnd + 0.03 {
                let sh = prevEnd + 0.03 - s
                for k in ws.indices {
                    if let a = ws[k].start { ws[k].start = a + sh }
                    if let b = ws[k].end { ws[k].end = b + sh }
                }
                s += sh; e += sh
            }
            // (b) co độ dài quá mức — tỉ lệ đều, giữ start
            let cap = max(3.0, 0.9 * Double(ws.count))
            if e - s > cap, e > s {
                let k = cap / (e - s)
                for idx in ws.indices {
                    if let a = ws[idx].start { ws[idx].start = s + (a - s) * k }
                    let base = ws[idx].start ?? s
                    if let b = ws[idx].end { ws[idx].end = max(base + 0.05, s + (b - s) * k) }
                }
                e = s + cap
            }
            // (c) kẹp trong bài
            if e > songDur {
                let sh = songDur - e
                for k in ws.indices {
                    if let a = ws[k].start { ws[k].start = max(0, a + sh) }
                    if let b = ws[k].end { ws[k].end = max(0.05, b + sh) }
                }
                s = max(0, s + sh); e = songDur
            }
            out[i].words = ws
            out[i].start = min(out[i].start ?? s, s)
            out[i].end = e
            prevEnd = e
        }
        return out
    }

    /// Chặn "chữ chạy 30 giây" (bộ canh CTC đôi khi để 1 chữ nuốt cả đoạn nhạc dạo):
    /// chữ nào dài quá ngưỡng → kẹp lại, chừa khoảng trống.
    nonisolated static func capRunaway(_ lines: [LyricLine]) -> [LyricLine] {
        var durs: [Double] = []
        for l in lines { for w in l.words { if let s = w.start, let e = w.end, e > s { durs.append(e - s) } } }
        guard durs.count >= 4 else { return lines }
        durs.sort()
        let med = durs[durs.count / 2]
        let cap = max(5.0, med * 6)
        var out = lines
        for li in out.indices {
            var ws = out[li].words
            for i in ws.indices {
                guard let s = ws[i].start, let e = ws[i].end, e - s > cap else { continue }
                ws[i].end = s + cap
            }
            out[li].words = ws
            if let e = ws.last?.end, let s = out[li].start { out[li].end = max(s + 0.1, e) }
        }
        return out
    }

    /// Kéo mỗi chữ dài tới sát chữ kế (trong cùng 1 dòng) để vệt karaoke chạy LIỀN MẠCH,
    /// nhưng không quá 5s sau chỗ bộ canh nghe thấy chữ đó hết.
    nonisolated static func smoothWordGaps(_ lines: [LyricLine]) -> [LyricLine] {
        var out = lines
        for li in out.indices {
            var ws = out[li].words
            guard ws.count >= 1 else { continue }
            for i in 0..<ws.count - 1 {
                guard let cs = ws[i].start, let ns = ws[i + 1].start else { continue }
                let origEnd = ws[i].end ?? cs
                ws[i].end = min(max(cs + 0.05, ns), origEnd + 5.0)
            }
            if let lastStart = ws[ws.count - 1].start {
                let lineEnd = out[li].end ?? ws[ws.count - 1].end ?? lastStart
                ws[ws.count - 1].end = max(lastStart + 0.08,
                                           min(lineEnd, (ws[ws.count - 1].end ?? lastStart) + 2.5))
            }
            out[li].words = ws
            if let f = ws.first?.start { out[li].start = min(out[li].start ?? f, f) }
            if let e = ws.last?.end   { out[li].end   = max(out[li].end ?? e, e) }
        }
        return out
    }
}
