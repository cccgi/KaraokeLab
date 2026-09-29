import Foundation
import AVFoundation
import Accelerate
import MDXOnnx

/// Kết quả canh mốc theo dòng / theo chữ (dùng nội bộ, `ForcedAligner` xử tiếp).
enum AlignResponse {
    struct Line {
        let line_index: Int
        let text: String
        let words: [Word]
    }
    struct Word {
        let text: String
        let start: Double
        let end: Double
        let score: Double?
    }
}

enum LocalAlignerError: LocalizedError {
    case noModel, cannotOpen, sessionFailed, runFailed(Int32), badOutput
    var errorDescription: String? {
        switch self {
        case .noModel:       return "Không tìm thấy model canh lời trong app."
        case .cannotOpen:    return "Không đọc được file giọng."
        case .sessionFailed: return "Không nạp được model canh lời."
        case .runFailed(let c): return "Chạy model canh lời lỗi (mã \(c))."
        case .badOutput:     return "Model canh lời trả kết quả rỗng."
        }
    }
}

/// Canh mốc TỪNG CHỮ vào audio — CHẠY TRONG APP (ONNX MMS forced aligner, offline).
/// Thay cho việc gọi Colab `/align`. Nhận lời ĐẦY ĐỦ (đã bung điệp khúc), trả `[AlignResponse.Line]`
/// để `ForcedAligner.buildLines` xử tiếp (lead-in, làm sạch).
enum LocalAligner {

    // vocab.json của MahmoudAshraf/mms-300m-1130-forced-aligner (31 lớp)
    private static let vocab: [Character: Int] = [
        "'": 28, "a": 4, "b": 20, "c": 23, "d": 16, "e": 6, "f": 27, "g": 17, "h": 18,
        "i": 5, "j": 25, "k": 14, "l": 15, "m": 13, "n": 7, "o": 8, "p": 21, "q": 29,
        "r": 12, "s": 11, "t": 10, "u": 9, "v": 24, "w": 22, "x": 30, "y": 19, "z": 26
    ]
    private static let blankID = 0
    private static let unkID = 3
    private static let vocabSize = 31
    private static let starID = 31          // cột <star> nối thêm (logp = 0 = "đậu tự do")
    private static let sr = 16_000

    static var modelURL: URL? { KMBundle.url(forResource: "mms-aligner-uint8", withExtension: "onnx") }

    /// `progress` 0…1. Nặng — LUÔN gọi trong `Task.detached`.
    static func align(vocalURL: URL, lyrics: String,
                      progress: @escaping @Sendable (Double) -> Void) throws -> [AlignResponse.Line] {
        guard let model = modelURL else { throw LocalAlignerError.noModel }
        let samples = try read16kMono(vocalURL)
        guard samples.count > sr / 10 else { throw LocalAlignerError.cannotOpen }
        guard let sess = mdx_open(model.path, 0) else { throw LocalAlignerError.sessionFailed }
        defer { mdx_close(sess) }
        return try alignCore(samples: samples, sess: sess, lyrics: lyrics, progress: progress)
    }

    /// Canh giờ THEO TỪNG CỬA SỔ: mỗi dòng lời chỉ canh trong đoạn audio của nó
    /// → bộ canh KHÔNG thể "trôi" sang đoạn nhạc dạo / nuốt cả khúc.
    /// `windows`: (text 1 dòng, start giây, end giây) theo đúng thứ tự hát.
    static func alignWindows(vocalURL: URL,
                             windows: [(text: String, start: Double, end: Double)],
                             progress: @escaping @Sendable (Double) -> Void) throws -> [AlignResponse.Line] {
        guard let model = modelURL else { throw LocalAlignerError.noModel }
        let samples = try read16kMono(vocalURL)
        guard samples.count > sr / 10, !windows.isEmpty else { throw LocalAlignerError.cannotOpen }
        guard let sess = mdx_open(model.path, 0) else { throw LocalAlignerError.sessionFailed }
        defer { mdx_close(sess) }

        let total = samples.count
        var out: [AlignResponse.Line] = []
        for (i, w) in windows.enumerated() {
            let a = max(0, min(total - 1, Int(w.start * Double(sr))))
            let b = max(a + sr / 5, min(total, Int(w.end * Double(sr))))
            let slice = Array(samples[a..<b])
            let off = Double(a) / Double(sr)
            let sub = (try? alignCore(samples: slice, sess: sess, lyrics: w.text, progress: { _ in })) ?? []
            var words = sub.first?.words ?? []
            words = words.map {
                AlignResponse.Word(text: $0.text,
                                   start: (($0.start + off) * 1000).rounded() / 1000,
                                   end: (($0.end + off) * 1000).rounded() / 1000,
                                   score: $0.score)
            }
            out.append(AlignResponse.Line(line_index: i, text: w.text, words: words))
            progress(min(0.99, Double(i + 1) / Double(windows.count)))
        }
        progress(1)
        return out
    }

    /// Tính "emission" (log-prob ký tự theo khung thời gian) cho TOÀN BỘ đoạn audio.
    /// Cửa sổ 20 s, chồng 2 s mỗi bên. Trả `[T][vocabSize]` đã log-softmax + số giây / khung.
    private static func buildEmission(samples: [Float], sess: OpaquePointer,
                                      progress: @escaping @Sendable (Double) -> Void,
                                      progressCap: Double = 0.7) throws -> (emission: [[Float]], secPerFrame: Double) {
        let win = 20 * sr, ctx = 2 * sr
        let step = max(sr, win - 2 * ctx)
        var emission: [[Float]] = []
        var fps = 0.0
        var pos = 0
        while pos < samples.count {
            let end = min(pos + win, samples.count)
            let chunk = Array(samples[pos..<end])
            let (logits, nf) = try runModel(sess, chunk)
            guard nf > 0 else { throw LocalAlignerError.badOutput }
            if fps == 0 { fps = Double(nf) / Double(chunk.count) }

            let dropF = pos == 0 ? 0 : Int(Double(ctx) * fps)
            let dropB = end == samples.count ? 0 : Int(Double(ctx) * fps)
            let lo = min(dropF, nf), hi = max(lo, nf - dropB)
            for f in lo..<hi {
                var row = Array(logits[f * vocabSize ..< (f + 1) * vocabSize])
                logSoftmax(&row)
                emission.append(row)
            }
            if end == samples.count { break }
            pos += step
            progress(min(progressCap, Double(pos) / Double(samples.count) * progressCap))
        }
        let T = emission.count
        guard T > 0 else { throw LocalAlignerError.badOutput }
        let secPerFrame = Double(samples.count) / Double(T) / Double(sr)
        return (emission, secPerFrame)
    }

    private static func alignCore(samples: [Float], sess: OpaquePointer, lyrics: String,
                                  progress: @escaping @Sendable (Double) -> Void) throws -> [AlignResponse.Line] {
        let (emission, secPerFrame) = try buildEmission(samples: samples, sess: sess, progress: progress)

        // ---- targets: chữ (bỏ dấu) + <star> quanh mỗi chữ ----
        let rawLines = lyrics.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var words: [String] = []
        var wordLine: [Int] = []
        for (li, ln) in rawLines.enumerated() {
            for w in ln.split(separator: " ") { words.append(String(w)); wordLine.append(li) }
        }
        guard !words.isEmpty else { throw LocalAlignerError.cannotOpen }

        let tokLists: [[Int]] = words.map { w in
            let ids = normWord(w)
            return ids.isEmpty ? [unkID] : ids
        }
        var flat: [Int] = []
        var segLen: [Int] = []
        for ids in tokLists {
            flat.append(starID); segLen.append(1)
            flat.append(contentsOf: ids); segLen.append(ids.count)
        }
        flat.append(starID); segLen.append(1)

        progress(0.8)
        let spans = forcedAlign(emission: emission, targets: flat)   // spans.count == flat.count
        progress(0.97)

        // gộp span theo segLen → nhóm [star, w0, star, w1, ...]; chữ = nhóm lẻ
        var groups: [[Span]] = []
        var idx = 0
        for L in segLen {
            groups.append(Array(spans[idx..<idx + L]))
            idx += L
        }

        var out: [AlignResponse.Line] = []
        var cur: (li: Int, ws: [AlignResponse.Word])?
        for wi in 0..<tokLists.count {
            let g = groups[2 * wi + 1]
            guard let f0 = g.first, let f1 = g.last else { continue }
            let st = Double(f0.start) * secPerFrame
            let en = Double(f1.end) * secPerFrame
            let sc = g.map { $0.score }.reduce(0, +) / Double(max(1, g.count))
            let li = wordLine[wi]
            if cur == nil || cur!.li != li {
                if let c = cur {
                    out.append(AlignResponse.Line(line_index: out.count, text: rawLines[c.li], words: c.ws))
                }
                cur = (li, [])
            }
            cur!.ws.append(AlignResponse.Word(text: words[wi],
                                              start: (st * 1000).rounded() / 1000,
                                              end: (max(en, st) * 1000).rounded() / 1000,
                                              score: (sc * 1000).rounded() / 1000))
        }
        if let c = cur {
            out.append(AlignResponse.Line(line_index: out.count, text: rawLines[c.li], words: c.ws))
        }
        progress(1)
        return out
    }

    // MARK: - Canh giờ bằng CÁCH ĐI TÌM (không whisper)

    /// TƯ DUY:
    ///  (1) Đọc chỗ nào TRONG BÀI có tiếng hát từ chính dữ liệu bộ canh (khung "im"
    ///      = xác suất blank cao = nhạc dạo) → danh sách "câu hát" cố định.
    ///  (2) Một câu hát ⇄ đúng MỘT dòng lời → không thể 2 dòng chồng một lúc, và
    ///      không thể nhiều dòng hơn số câu bài thật sự hát.
    ///  (3) Đi từ đầu lời xuống: ướm CHỮ ĐÚNG từng dòng vào từng câu hát, chấm điểm;
    ///      quy hoạch động chọn đường (dòng kế / lặp lại khối / sang khối sau).
    /// Chữ 100% của user; điệp khúc nhân đúng số lần thật; không rớt dòng.
    static func alignBySearch(vocalURL: URL,
                              mixURL: URL? = nil,
                              blocks: [[String]],
                              progress: @escaping @Sendable (Double) -> Void) throws -> [AlignResponse.Line] {
        guard let model = modelURL else { throw LocalAlignerError.noModel }
        let clean = blocks
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        guard !clean.isEmpty else { throw LocalAlignerError.cannotOpen }

        let samples = try read16kMono(vocalURL)
        guard samples.count > sr / 2 else { throw LocalAlignerError.cannotOpen }
        guard let sess = mdx_open(model.path, 0) else { throw LocalAlignerError.sessionFailed }
        defer { mdx_close(sess) }

        let (emission, spf) = try buildEmission(samples: samples, sess: sess,
                                               progress: { progress(min(0.6, $0 * 0.6 / 0.7)) },
                                               progressCap: 0.7)

        let dbg = ProcessInfo.processInfo.environment["KM_ALIGN_DEBUG"] != nil
        func derr(_ s: String) { if dbg { FileHandle.standardError.write(Data((s + "\n").utf8)) } }

        // ---- dàn phẳng lời user ----
        var uLines: [String] = [], uWords: [[String]] = []
        for blk in clean {
            for ln in blk {
                let w = splitWords(ln); guard !w.isEmpty else { continue }
                uLines.append(ln); uWords.append(w)
            }
        }
        let U = uLines.count
        guard U >= 2 else { throw LocalAlignerError.cannotOpen }
        let sfs = uWords.map { starFlat($0) }
        let T = emission.count
        derr("emission T=\(T) spf=\(String(format: "%.4f", spf)) U=\(U)")
        if dbg {
            let sec = LocalAligner.sectionize(uLines)
            derr("M1 sectionize: \(sec.count) khối")
            for s in sec {
                let preview = uLines[s.lo].count > 22 ? String(uLines[s.lo].prefix(22)) + "…" : uLines[s.lo]
                derr("  [\(s.lo)-\(s.hi)] cụm=\(s.cluster)  “\(preview)”")
            }
        }

        func charCount(_ u: Int) -> Int { uWords[u].reduce(0) { $0 + $1.count } }
        let allWords = uWords.flatMap { $0 }
        let allSF = starFlat(allWords)

        // Canh `copies` bản lời (XOAY để bắt đầu ở dòng `rot`) vào [from, to).
        func alignRot(_ from: Int, to: Int? = nil, rot: Int, copies: Int = 2)
            -> [(u: Int, sF: Int, eF: Int, score: Double)] {
            let hi = min(T, to ?? T)
            guard hi - from > 4 else { return [] }
            var flat: [Int] = []
            var ranges: [(s: Int, e: Int)] = []
            var oidx: [Int] = []
            for _ in 0..<copies {
                for k in 0..<U {
                    let u = (rot + k) % U
                    flat.append(starID)
                    let s = flat.count
                    for tok in uWords[u] {
                        let ids = normWord(tok)
                        flat.append(contentsOf: ids.isEmpty ? [unkID] : ids)
                    }
                    ranges.append((s, flat.count)); oidx.append(u)
                }
            }
            flat.append(starID)
            let sp = forcedAlign(emission: Array(emission[from..<hi]), targets: flat)
            var res: [(u: Int, sF: Int, eF: Int, score: Double)] = []
            for (li, rg) in ranges.enumerated() {
                guard rg.e > rg.s, rg.e <= sp.count else { continue }
                let g = sp[rg.s..<rg.e]
                guard let a = g.first, let b = g.last else { continue }
                let sc = g.map(\.score).reduce(0, +) / Double(max(1, g.count))
                res.append((oidx[li], a.start + from, max(b.end + from, a.start + from + 1), sc))
            }
            return res
        }

        // đoạn 'ok' (k tăng dần) chất lượng cao nhất trong 1 kết quả canh
        func bestRun(_ al: [(u: Int, sF: Int, eF: Int, score: Double)]) -> (i: Int, j: Int, qual: Double, avg: Double)? {
            guard !al.isEmpty else { return nil }
            var saneMax = 0.0
            for x in al {
                let dur = Double(x.eF - x.sF) * spf
                let cap = max(4.0, 0.34 * Double(charCount(x.u)))
                if dur >= 0.25, dur <= cap * 1.9 { saneMax = max(saneMax, x.score) }
            }
            _ = saneMax
            // dòng "hợp lệ về hình dạng" (thời lượng); điểm để LỌC ĐOẠN, không cắt cứng.
            func shapeOK(_ i: Int) -> Bool {
                let dur = Double(al[i].eF - al[i].sF) * spf
                let cap = max(4.0, 0.34 * Double(charCount(al[i].u)))
                return dur >= 0.25 && dur <= cap * 2.0
            }
            var best: (i: Int, j: Int, qual: Double, avg: Double)?
            var i = 0
            while i < al.count {
                // bắt đầu đoạn ở dòng điểm KHÁ (không mở đầu bằng rác)
                if !shapeOK(i) || al[i].score < 0.24 { i += 1; continue }
                var j = i
                while j + 1 < al.count, shapeOK(j + 1),
                      al[j + 1].score >= 0.09,                       // cho phép dòng yếu ở GIỮA
                      al[j + 1].u >= al[j].u, al[j + 1].u <= al[j].u + 3,
                      al[j + 1].sF >= al[j].sF,
                      Double(al[j + 1].sF - al[j].eF) * spf < 9 { j += 1 }
                // co đuôi bỏ RÁC cuối (điểm rất thấp), nhưng GIỮ dòng điểm trung bình
                while j > i, al[j].score < 0.15 { j -= 1 }
                let span = Double(al[j].eF - al[i].sF) * spf
                let avg = (i...j).reduce(0.0) { $0 + al[$1].score } / Double(j - i + 1)
                let qual = max(0.02, avg - 0.20) * min(span, 70.0)
                if span >= 2.5, avg >= 0.26, best == nil || qual > best!.qual {
                    best = (i, j, qual, avg)
                }
                i = j + 1
            }
            return best
        }

        // Đoạn DẪN ĐẦU: bắt buộc bắt đầu ở u0..2, kéo dài tối đa theo thứ tự.
        // → chống LƯỢT ĐẦU khoá nhầm vào khúc lặp về sau / cụm ngắn điểm cao (lời gõ ĐỦ, đúng thứ tự).
        func leadRun(_ al: [(u: Int, sF: Int, eF: Int, score: Double)]) -> (i: Int, j: Int, qual: Double, avg: Double)? {
            func shapeOK(_ i: Int) -> Bool {
                let dur = Double(al[i].eF - al[i].sF) * spf
                let cap = max(4.0, 0.34 * Double(charCount(al[i].u)))
                return dur >= 0.25 && dur <= cap * 2.2
            }
            guard let i = al.indices.first(where: { al[$0].u <= 2 && shapeOK($0) && al[$0].score >= 0.12 }) else { return nil }
            var j = i
            while j + 1 < al.count, shapeOK(j + 1), al[j + 1].score >= 0.08,
                  al[j + 1].u >= al[j].u, al[j + 1].u <= al[j].u + 3,
                  al[j + 1].sF >= al[j].sF, Double(al[j + 1].sF - al[j].eF) * spf < 12 { j += 1 }
            while j > i, al[j].score < 0.13 { j -= 1 }
            let span = Double(al[j].eF - al[i].sF) * spf
            guard span >= 3, j - i >= 3 else { return nil }
            let avg = (i...j).reduce(0.0) { $0 + al[$1].score } / Double(j - i + 1)
            return (i, j, max(0.02, avg - 0.20) * min(span, 70.0), avg)
        }

        var dedup: [(u: Int, sF: Int, eF: Int, score: Double)] = []

        // Mốc GIỌNG bắt đầu hát (RMS) — dùng để chống base "chờ" quá lâu ở đầu bài.
        let phrasesEarly = LocalAligner.vocalPhrases(samples: samples, spf: spf, frames: T)
        let vocalOnset = phrasesEarly.first?.sF ?? 0

        // (A) canh 1 lượt cả bài — mốc dự phòng cho skeleton.
        var base = alignRot(0, rot: 0, copies: 1)
        // Nếu câu ĐẦU của base rơi MUỘN hơn nhiều so với lúc giọng thật bắt đầu hát (>8s),
        // base đã bị trễ cả đoạn mở đầu (thường do stem đầu bài yếu / hát nhỏ). Canh LẠI
        // trong cửa sổ bắt đầu từ đúng onset → MMS không thể đặt câu đầu quá trễ nữa.
        if let firstBase = base.filter({ $0.u < U }).min(by: { $0.sF < $1.sF }),
           firstBase.sF - vocalOnset > Int(8.0 / spf) {
            let reBase = alignRot(max(0, vocalOnset - Int(1.5 / spf)), rot: 0, copies: 1)
            if let fr = reBase.filter({ $0.u < U }).min(by: { $0.sF < $1.sF }), fr.sF < firstBase.sF - Int(3.0 / spf) {
                derr("BASE canh lại từ onset \(String(format: "%.1f", Double(vocalOnset) * spf))s (câu đầu cũ ở \(String(format: "%.1f", Double(firstBase.sF) * spf))s → giờ \(String(format: "%.1f", Double(fr.sF) * spf))s)")
                base = reBase
            }
        }
        var lineFrame: [(s: Int, e: Int)] = Array(repeating: (0, 1), count: U)
        for r in base where r.u < U { lineFrame[r.u] = (r.sF, r.eF) }
        if dbg {
            for r in base.sorted(by: { $0.u < $1.u }) {
                derr("BASE u\(r.u): \(String(format: "%.1f", Double(r.sF) * spf))-\(String(format: "%.1f", Double(r.eF) * spf))s sc=\(String(format: "%.2f", r.score))")
            }
        }
        progress(0.66)

        // ================================================================
        // LỜI ĐỦ (mọi câu đều được gõ, đúng thứ tự) → CANH 1 LƯỢT ĐƠN ĐIỆU là đủ.
        // Kiểm tra: `base` có phủ hầu hết thời gian HÁT không? Nếu có → dùng thẳng base,
        // BỎ toàn bộ máy dò-lặp/vá (thứ đó chỉ dành cho lời chép TẮT).
        // ================================================================
        let phrases = LocalAligner.vocalPhrases(samples: samples, spf: spf, frames: T)
        var sungF = 0, covF = 0
        for p in phrases {
            var f = p.sF
            while f < p.eF {
                sungF += 1
                if base.contains(where: { $0.u < U && $0.sF - 8 <= f && $0.eF + 8 >= f }) { covF += 1 }
                f += 5
            }
        }
        let baseCov = sungF > 0 ? Double(covF) / Double(sungF) : 0
        // (2026-09-06) User CHỐT: BỎ HẲN phần "lời thiếu" — LUÔN canh 1 lượt đơn điệu.
        // Ai chỉ gõ v1+chorus1 mà bỏ v2+c2 thì chỗ đó KHÔNG có text, không tự nhân bản.
        let fullPaste = true
        derr("phrases=\(phrases.count) baseCov=\(String(format: "%.2f", baseCov)) fullPaste=\(fullPaste) (ép cứng)")

        if fullPaste {
            var b = base.filter { $0.u < U }.sorted { $0.u < $1.u }
            // dòng THẬT SỰ RÁC ở đuôi (rơi HẲN sau chỗ hát cuối + điểm ~0) → dồn sát dòng tốt
            // trước. NGƯỠNG CHẶT: đừng đụng vào các câu điệp khúc lặp user cố ý gõ ở cuối bài.
            let lastSung = phrases.last?.eF ?? T
            var g = b.count - 1
            while g > 0, b[g].score < 0.05, b[g].sF > lastSung + Int(2.0 / spf) { g -= 1 }
            if g < b.count - 1 {
                let anchor = b[g].eF
                let room = max(Int(0.9 / spf), (min(T, lastSung + Int(1.0 / spf)) - anchor) / max(1, b.count - 1 - g))
                for k in (g + 1)..<b.count {
                    let s = anchor + (k - g - 1) * room
                    b[k].sF = min(T - 2, s)
                    b[k].eF = min(T - 1, s + max(Int(0.6 / spf), room - Int(0.2 / spf)))
                }
                derr("  full-paste: dồn \(b.count - 1 - g) dòng chép-dư về ~\(String(format: "%.1f", Double(anchor) * spf))s")
            }
            dedup = b.sorted { $0.sF < $1.sF }
            for c in dedup where c.u < U { lineFrame[c.u] = (c.sF, c.eF) }
            derr("FULL-PASTE → dùng base (\(dedup.count) dòng)")
        } else {

        // ================================================================
        // (C) LẶP: mỗi lượt thử vài điểm bắt đầu (xoay lời), lấy đoạn khớp tốt nhất,
        //     ghi nhận, dời cursor. → bắt V1-ĐK, ĐK/đoạn hát lại, đoạn cầu… KHÔNG cần chia đoạn.
        // ================================================================
        var passLines: [(u: Int, sF: Int, eF: Int, score: Double)] = []
        var cursor = max(0, base.map { $0.sF }.min() ?? 0)
        var guardN = 0
        let rots = Array(stride(from: 0, to: U, by: max(1, U / 5)))
        while cursor < T - Int(3.0 / spf) && guardN < 18 {
            guardN += 1
            var pick: (al: [(u: Int, sF: Int, eF: Int, score: Double)], r: (i: Int, j: Int, qual: Double, avg: Double))?
            // LƯỢT ĐẦU: neo vào đoạn dẫn đầu (rot 0, từ đầu bài) — không cho rượt theo khúc lặp.
            if passLines.isEmpty {
                let al0 = alignRot(0, rot: 0, copies: 1)
                if let r = leadRun(al0) { pick = (al0, r) }
            }
            if pick == nil {
                for rot in rots {
                    let al = alignRot(cursor, rot: rot)
                    guard let r = bestRun(al) else { continue }
                    if pick == nil || r.qual > pick!.r.qual { pick = (al, r) }
                }
                // Nếu đoạn thắng bắt đầu QUÁ XA cursor mà KHOẢNG GIỮA vẫn còn hát nhiều
                // (bộ dò rượt theo dòng ngắn lặp cuối bài) → dùng BASE (canh cả bài, đơn điệu)
                // cho khúc bị bỏ qua thay vì nhảy tới.
                if let pk0 = pick {
                    derr("  [chk] pk start u\(pk0.al[pk0.r.i].u)@\(String(format: "%.0f", Double(pk0.al[pk0.r.i].sF) * spf))s cursor@\(String(format: "%.0f", Double(cursor) * spf))s gap=\(String(format: "%.0f", Double(pk0.al[pk0.r.i].sF - cursor) * spf))s")
                }
                if let pk0 = pick, pk0.al[pk0.r.i].sF - cursor > Int(35.0 / spf) {
                    // BASE (canh cả bài, đơn điệu) có đặt dòng nào trong khoảng bị bỏ qua không?
                    let seg = base.filter {
                        $0.u < U && $0.sF >= cursor - Int(1.5 / spf)
                            && $0.sF < min(pk0.al[pk0.r.i].sF - Int(2.0 / spf), cursor + Int(62.0 / spf))
                    }.sorted { $0.u < $1.u }
                    if seg.count >= 3, seg.last!.u > seg.first!.u + 1 {
                        let avg = seg.map(\.score).reduce(0, +) / Double(seg.count)
                        pick = (seg, (0, seg.count - 1, 999.0, avg))
                        derr("  (base-fill: u\(seg.first!.u)..\(seg.last!.u) @\(String(format: "%.0f", Double(seg.first!.sF) * spf))s thay cho đoạn xa @\(String(format: "%.0f", Double(pk0.al[pk0.r.i].sF) * spf))s)")
                    }
                }
            }
            guard let pk = pick else {
                let jump = cursor + Int(6.0 / spf)
                if jump <= cursor { break }
                cursor = jump; continue
            }
            let al = pk.al, bI = pk.r.i, bJ = pk.r.j
            for k in bI...bJ { passLines.append(al[k]) }
            derr("pass \(guardN): u \(al[bI].u)..\(al[bJ].u)  \(String(format: "%.1f", Double(al[bI].sF) * spf))-\(String(format: "%.1f", Double(al[bJ].eF) * spf))s avg=\(String(format: "%.2f", pk.r.avg))")
            var endF = al[bJ].eF

            // MỞ RỘNG tới trước: các dòng NGAY SAU đoạn vừa lấy nếu còn hát nối tiếp
            // ("…giấc mơ" cuối điệp khúc, đuôi bài) — có thể ngân dài / cách quãng.
            var uWant = al[bJ].u + 1
            if uWant < U {
                let ext = alignRot(endF, rot: uWant, copies: 1)
                var prevEnd = endF
                for e in ext {
                    guard e.u == uWant, uWant < U else { break }
                    let dur = Double(e.eF - e.sF) * spf
                    let cap = max(4.0, 0.34 * Double(charCount(e.u)))
                    let gap = Double(e.sF - prevEnd) * spf
                    guard dur >= 0.25, dur <= cap * 2.6, e.score >= 0.05, gap < 15, gap > -1.5 else { break }
                    passLines.append(e); prevEnd = e.eF; uWant += 1
                }
                if prevEnd > endF {
                    endF = prevEnd
                    derr("  ext -> u\(uWant - 1) @\(String(format: "%.1f", Double(endF) * spf))s")
                }
            }
            cursor = endF + max(1, Int(0.25 / spf))
        }

        // (C2) đuôi bài còn hát mà chưa có lời → canh full lời, lấy đoạn khớp (kể cả 1 dòng lặp)
        var outroCur = cursor
        var outroGuard = 0
        while outroCur < T - Int(4.0 / spf), outroGuard < 5 {
            outroGuard += 1
            var got = false
            for rot in rots {
                let al = alignRot(outroCur, rot: rot, copies: 2)
                guard let r = bestRun(al), r.avg >= 0.24 else { continue }
                for k in r.i...r.j { passLines.append(al[k]) }
                derr("outro: u \(al[r.i].u)..\(al[r.j].u) @\(String(format: "%.1f", Double(al[r.i].sF) * spf))s avg=\(String(format: "%.2f", r.avg))")
                outroCur = al[r.j].eF + max(1, Int(0.3 / spf))
                got = true
                break
            }
            if !got { break }
        }


        progress(0.9)

        passLines.sort { $0.sF < $1.sF }
        for c in passLines {
            if let last = dedup.last, last.u == c.u, Double(c.sF - last.eF) * spf < 1.0 {
                if c.score > last.score { dedup[dedup.count - 1] = c }
                continue
            }
            dedup.append(c)
        }

        // (C3) VÁ LỖ HỔNG: khe thời gian > 6s giữa 2 dòng → canh các dòng lời "đáng lẽ ở đó"
        //      (u sau dòng trước) VÀO ĐÚNG khe đó (bị chặn 2 đầu, không trôi ra ngoài).
        func fillHole(after aU: Int, from f0: Int, to f1: Int) -> [(u: Int, sF: Int, eF: Int, score: Double)] {
            guard aU + 1 < U, f1 - f0 > Int(2.5 / spf) else { return [] }
            let sub = alignRot(f0, to: min(T, f1 + Int(1.0 / spf)), rot: aU + 1, copies: 1)
            var out: [(u: Int, sF: Int, eF: Int, score: Double)] = []
            var wantU = aU + 1, prevEnd = f0
            for e in sub {
                guard e.u == wantU, wantU < U else { break }
                let dur = Double(e.eF - e.sF) * spf
                let cap = max(4.0, 0.34 * Double(charCount(e.u)))
                let gap = Double(e.sF - prevEnd) * spf
                guard dur >= 0.3, dur <= cap * 2.4, e.score >= 0.05, gap < 13, e.eF <= f1 + Int(1.0 / spf) else { break }
                out.append(e); prevEnd = e.eF; wantU += 1
            }
            return out
        }
        // VÁ NGƯỢC: khe trước một đoạn "quay lại" ở dòng bU → các dòng bU-k…bU-1 (điệp khúc
        // hát lại nhưng bắt đầu SỚM HƠN chỗ pass bắt được) canh vào cuối khe.
        func backfillBefore(_ bU: Int, from f0: Int, to f1: Int) -> [(u: Int, sF: Int, eF: Int, score: Double)] {
            guard bU >= 2, f1 - f0 > Int(3.0 / spf) else { return [] }
            let sub = alignRot(f0, to: min(T, f1 + Int(1.5 / spf)), rot: max(0, bU - 8), copies: 1)
            var out: [(u: Int, sF: Int, eF: Int, score: Double)] = []
            for e in sub {
                guard e.u < bU else { break }                       // chỉ nhận các dòng TRƯỚC bU, theo thứ tự
                let dur = Double(e.eF - e.sF) * spf
                let cap = max(4.0, 0.34 * Double(charCount(e.u)))
                guard dur >= 0.35, dur <= cap * 2.4, e.score >= 0.16,
                      e.sF >= f0, e.eF <= f1 + Int(1.5 / spf) else { continue }
                if let last = out.last, e.u <= last.u { continue }
                out.append(e)
            }
            return out
        }
        var holes: [(u: Int, sF: Int, eF: Int, score: Double)] = []
        for i in 0..<dedup.count {
            let a = dedup[i]
            let nextStart = i + 1 < dedup.count ? dedup[i + 1].sF : T
            let nextU = i + 1 < dedup.count ? dedup[i + 1].u : 0
            let gapSec = Double(nextStart - a.eF) * spf
            guard gapSec > 6 else { continue }
            if nextU <= a.u || i + 1 == dedup.count {
                let f = fillHole(after: a.u, from: a.eF, to: nextStart)
                if !f.isEmpty { holes.append(contentsOf: f); derr("hole+ @\(String(format: "%.1f", Double(a.eF) * spf))s -> u\(f.first!.u)..\(f.last!.u)") }
            }
            if i + 1 < dedup.count, nextU < a.u, nextU >= 2 {
                let b = backfillBefore(nextU, from: a.eF, to: nextStart)
                if !b.isEmpty { holes.append(contentsOf: b); derr("hole- @\(String(format: "%.1f", Double(nextStart) * spf))s <- u\(b.first!.u)..\(b.last!.u)") }
            }
        }

        // Tỉ lệ khung CÓ TIẾNG HÁT trong [f0,f1) (blank prob thấp).
        func voicedRatio(_ f0: Int, _ f1: Int) -> Double {
            let a = max(0, f0), b = min(T, f1)
            guard b - a > 2 else { return 0 }
            var v = 0
            for f in a..<b where 1.0 - exp(Double(emission[f][blankID])) > 0.12 { v += 1 }
            return Double(v) / Double(b - a)
        }

        // CLONE ĐUÔI: đoạn hát CUỐI (điệp khúc lần chót) thường bị hụt vài dòng cuối vì
        // đoạn fade quá nhỏ để bộ canh chấm. Nếu một LẦN HÁT TRƯỚC có đủ các dòng đó
        // → sao chép đuôi ấy, dời theo mốc — CHỈ chèn dòng nào rơi vào chỗ CÒN HÁT.
        do {
            let sorted = (dedup + []).sorted { $0.sF < $1.sF }
            // tách thành các "đoạn" u tăng dần
            var runs: [[(u: Int, sF: Int, eF: Int, score: Double)]] = []
            for c in sorted {
                if var lastRun = runs.last, let prev = lastRun.last, c.u > prev.u, c.u <= prev.u + 4 {
                    lastRun.append(c); runs[runs.count - 1] = lastRun
                } else { runs.append([c]) }
            }
            if let lastRun = runs.last, let tailU = lastRun.map({ $0.u }).max(), tailU + 1 < U,
               let anchorLast = lastRun.first(where: { $0.u == tailU }) {
                // tìm đoạn TRƯỚC có đủ tailU và tailU+1…
                var refRun: [(u: Int, sF: Int, eF: Int, score: Double)]?
                for r in runs.dropLast() where (r.map { $0.u }.max() ?? -1) > tailU && r.contains(where: { $0.u == tailU }) {
                    refRun = r
                }
                if let ref = refRun, let refAnchor = ref.first(where: { $0.u == tailU }) {
                    let delta = anchorLast.eF - refAnchor.eF
                    var added: [Int] = []
                    for rl in ref where rl.u > tailU && rl.u < U {
                        let s = rl.sF + delta, e = rl.eF + delta
                        guard s < T - 2, e <= T else { break }
                        // dòng ĐẦU tiên phải rơi vào chỗ CÒN HÁT (chống bịa lời vào nhạc dạo);
                        // đã bắt đầu clone thì chép NỐT cả đuôi điệp khúc (fade nhỏ dần vẫn tính).
                        if added.isEmpty, voicedRatio(s, e) <= 0.10 { break }
                        holes.append((rl.u, s, min(T, e), 0.18)); added.append(rl.u)
                    }
                    if !added.isEmpty {
                        derr("clone-tail @\(String(format: "%.1f", Double(anchorLast.eF) * spf))s -> u\(added.first!)..\(added.last!) (delta \(String(format: "%.1f", Double(delta) * spf))s)")
                    }
                }
            }
        }

        // ================================================================
        // (C4) NHÂN BẢN ĐOẠN CUỐI THEO NĂNG LƯỢNG GIỌNG — KHÔNG "chấm điểm chọn khối".
        //   Bộ canh MMS đôi khi quá yếu ở điệp khúc cuối (stem mờ) → tự nó không bắt được.
        //   Nhưng NĂNG LƯỢNG sóng giọng thì rõ ràng: chỗ nào còn hát to mà CHƯA có lời =
        //   bài đang hát lại ĐOẠN CUỐI (điệp khúc + cụm kết). Lấy nguyên đoạn cuối user đã
        //   gõ, co giãn cho vừa vùng đó. MMS chỉ để tinh chỉnh — yếu quá thì co giãn thẳng.
        // ================================================================
        if T > 20, samples.count > sr {
            func fF(_ s: Double) -> Int { Int(s / spf) }

            // --- đường năng lượng giọng theo khung (mean-square, cửa sổ ~0.4s) ---
            var pfx = [Double](repeating: 0, count: samples.count + 1)
            for i in 0..<samples.count { pfx[i + 1] = pfx[i] + Double(samples[i]) * Double(samples[i]) }
            let half = min(3200, max(400, samples.count / 200))
            var env = [Double](repeating: 0, count: T)
            for f in 0..<T {
                let c = min(samples.count - 1, Int(Double(f) / Double(T) * Double(samples.count)))
                let a = max(0, c - half), b = min(samples.count, c + half)
                env[f] = b > a ? (pfx[b] - pfx[a]) / Double(b - a) : 0
            }
            let srt = env.sorted()
            let floorV = srt[srt.count / 10]
            let peakV = srt[min(srt.count - 1, srt.count * 85 / 100)]
            let thr = floorV + 0.10 * max(1e-12, peakV - floorV)
            func sing(_ f: Int) -> Bool { f >= 0 && f < T && env[f] > thr }

            // --- vùng hát (nối khe < 1.2s, bỏ mẩu < 0.6s) ---
            var voiced: [(s: Int, e: Int)] = []
            do {
                var i = 0
                while i < T {
                    while i < T, !sing(i) { i += 1 }
                    guard i < T else { break }
                    let s = i
                    while i < T, sing(i) { i += 1 }
                    if var l = voiced.last, s - l.e < fF(2.5) { l.e = i; voiced[voiced.count - 1] = l }
                    else { voiced.append((s, i)) }
                }
                voiced = voiced.filter { $0.e - $0.s >= fF(0.6) }
            }

            // "đã có lời" = mọi thứ đã đặt: pass + vá lỗ (holes) + clone-đuôi.
            let covBase = dedup + holes
            func coveredAt(_ f: Int) -> Bool {
                let pad = fF(0.7)
                return covBase.contains { f >= $0.sF - pad && f <= $0.eF + pad }
            }
            let lastCov = covBase.map { $0.eF }.max() ?? 0

            // --- đợt lời cuối làm KHUÔN (u tăng dần, liền giờ) ---
            let sortedD = covBase.sorted { $0.sF < $1.sF }
            var runs: [[(u: Int, sF: Int, eF: Int, score: Double)]] = []
            for c in sortedD {
                if var last = runs.last, let p = last.last,
                   c.u >= p.u, c.u <= p.u + 3, Double(c.sF - p.eF) * spf < 7 {
                    last.append(c); runs[runs.count - 1] = last
                } else { runs.append([c]) }
            }
            // ưu tiên đợt ≥ 5 dòng, bắt đầu sau 1/3 lời, muộn nhất; nếu không có → đợt dài nhất.
            let tmpl: [(u: Int, sF: Int, eF: Int, score: Double)]? = {
                let cands = runs.filter { ($0.count >= 5) && (($0.first?.u ?? 0) >= max(2, U / 3)) }
                if let pick = cands.max(by: { ($0.first?.sF ?? 0) < ($1.first?.sF ?? 0) }) { return pick }
                return runs.max(by: { $0.count < $1.count })
            }()

            if let tmpl, let tf = tmpl.first, tmpl.count >= 4 {
                let R0 = tf.u
                let runStart = tf.sF
                // khuôn: (u, khung-tương-đối-bắt-đầu, kết) cho R0..U-1
                var rel: [(u: Int, r0: Int, r1: Int)] = []
                var prevEnd = 0
                for u in R0...(U - 1) {
                    if let hit = tmpl.first(where: { $0.u == u }) {
                        let r0 = max(0, hit.sF - runStart), r1 = max(r0 + 1, hit.eF - runStart)
                        rel.append((u, r0, r1)); prevEnd = r1
                    } else {
                        let d = max(fF(1.0), fF(0.30 * Double(charCount(u))))
                        rel.append((u, prevEnd, prevEnd + d)); prevEnd += d
                    }
                }
                let Ltmpl = max(fF(4.0), rel.map { $0.r1 }.max() ?? fF(4.0))
                let coLo = max(R0, U - 2)

                // trải chữ ĐÃ BIẾT lo..hi vào [a,b) bằng MMS → (lines, meanScore).
                func lay(_ lo: Int, _ hi: Int, _ a0: Int, _ b0: Int) -> ([(u: Int, sF: Int, eF: Int, score: Double)], Double) {
                    let a = max(0, a0), b = min(T, b0)
                    guard b - a > fF(1.0), lo <= hi else { return ([], 0) }
                    let ws = (lo...hi).flatMap { uWords[$0] }
                    guard !ws.isEmpty else { return ([], 0) }
                    let sf = starFlat(ws)
                    let sp = forcedAlign(emission: Array(emission[a..<b]), targets: sf.flat)
                    let w = wordsFrom(spans: sp, ranges: sf.ranges, words: ws, frameOffset: a, secPerFrame: spf)
                    guard w.count == ws.count else { return ([], 0) }
                    let mean = w.reduce(0.0) { $0 + ($1.score ?? 0) } / Double(w.count)
                    var out: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                    var wi = 0
                    for u in lo...hi {
                        let n = uWords[u].count
                        let seg = Array(w[min(wi, w.count)..<min(wi + n, w.count)]); wi += n
                        guard let s0 = seg.first?.start, let e0 = seg.last?.end else { continue }
                        let cap = max(3.0, 0.34 * Double(charCount(u)))
                        let sF = fF(s0), eF = fF(min(e0, s0 + cap))
                        out.append((u, sF, max(eF, sF + 1), max(0.24, mean)))
                    }
                    return (out, mean)
                }
                // co giãn KHUÔN tuyến tính vào [startF, startF+lenF) — không cần MMS.
                // (chuẩn hoá: dòng ĐẦU của lát lo..hi bắt đầu ở startF)
                func scaled(_ lo: Int, _ startF: Int, _ lenF: Int) -> [(u: Int, sF: Int, eF: Int, score: Double)] {
                    let base = rel.first(where: { $0.u >= lo })?.r0 ?? 0
                    let span = max(1, (rel.last?.r1 ?? Ltmpl) - base)
                    let sc = Double(max(1, lenF)) / Double(span)
                    var out: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                    for r in rel where r.u >= lo {
                        let s = startF + Int(Double(r.r0 - base) * sc)
                        var e = startF + Int(Double(r.r1 - base) * sc)
                        e = min(e, s + fF(max(3.0, 0.34 * Double(charCount(r.u)))))
                        out.append((r.u, min(T - 1, max(0, s)), min(T, max(s + 1, e)), 0.27))
                    }
                    return out
                }

                if dbg {
                    let ivs = voiced.map { "\(String(format: "%.0f", Double($0.s) * spf))-\(String(format: "%.0f", Double($0.e) * spf))" }.joined(separator: " ")
                    derr("  voiced: \(ivs)")
                    derr("  R0=\(R0) Ltmpl=\(String(format: "%.1f", Double(Ltmpl) * spf))s lastCov=\(String(format: "%.1f", Double(lastCov) * spf))s coLo=\(coLo)")
                }
                var newLines: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                func hasNew(_ f: Int) -> Bool { newLines.contains { f >= $0.sF - fF(0.5) && f <= $0.eF + fF(0.5) } }
                let capNew = U + 24
                var cursor = 0, guardN = 0, cho = 0, coCnt = 0
                while cursor < T - fF(3.0), guardN < 26, newLines.count < capNew {
                    guardN += 1
                    // vùng hát kế tiếp CÒN một mảng chưa có lời ĐỦ DÀI (không phải khe thở giữa 2 dòng).
                    // QUÉT HẾT mọi mảng hở trong từng vùng — không dừng ở khe thở đầu tiên.
                    var pick: (s: Int, e: Int)?
                    for v in voiced where v.e > cursor + fF(0.3) {
                        var p = max(cursor, v.s)
                        while p < v.e {
                            while p < v.e, coveredAt(p) || hasNew(p) { p += fF(0.3) }
                            let outro = p >= lastCov - fF(2)            // sau dòng đã đặt CUỐI = đuôi bài
                            guard p < v.e - (outro ? fF(0.8) : fF(2.0)) else { break }
                            var q = p
                            while q < v.e, !coveredAt(q), !hasNew(q) { q += fF(0.3) }
                            let uncLen = q - p
                            let prevEnd = covBase.filter { $0.eF <= p + fF(0.5) }.map { $0.eF }.max() ?? 0
                            // NGUYÊN TẮC: đuôi bài còn hát mà chưa có lời → LẤP (mẩu ngắn cũng nhận);
                            // GIỮA bài chỉ lấp lỗ LỚN (≥6s) hoặc cách dòng trước ≥3.5s (không phải hơi thở).
                            let want = outro ? fF(1.2) : fF(4.0)
                            let realGap = outro || uncLen >= fF(6.0) || (p - prevEnd) >= fF(3.5)
                            if dbg {
                                derr("    v \(String(format: "%.0f", Double(v.s) * spf))-\(String(format: "%.0f", Double(v.e) * spf)): p=\(String(format: "%.0f", Double(p) * spf)) unc=\(String(format: "%.1f", Double(uncLen) * spf))s outro=\(outro) realGap=\(realGap)")
                            }
                            if uncLen >= want, realGap { pick = (p, min(v.e, q + fF(1.0))); break }
                            p = q + fF(0.3)
                        }
                        if pick != nil { break }
                    }
                    guard let reg = pick else { break }
                    let regS = reg.s, regE = reg.e
                    let trailing = regS >= lastCov - fF(2)
                    let boundedAfter = covBase.contains { $0.sF >= regE - fF(1) && $0.sF <= regE + fF(16) }
                    var contig = 0
                    do { var i = regS; while i < regE { if !coveredAt(i), !hasNew(i) { contig += 4 }; i += 4 } }

                    // (a) vùng hát TƯƠI đủ dài ≈ điệp khúc → chép cả khuôn (1 lần / vùng)
                    if contig >= max(fF(10), Ltmpl * 45 / 100), cho < 4 {
                        let actual = max(fF(6), min(Ltmpl * 3 / 2, regE - regS))
                        let (seg, mean) = lay(R0, U - 1, regS - fF(0.3), min(T, regS + actual + fF(4)))
                        let spanOK = (seg.last?.eF ?? 0) - (seg.first?.sF ?? 0) >= actual * 6 / 10
                        let chosen: [(u: Int, sF: Int, eF: Int, score: Double)]
                        if !seg.isEmpty, mean >= 0.20, spanOK { chosen = seg }                    // MMS chắc + phủ đủ
                        else if trailing || boundedAfter { chosen = scaled(R0, regS, actual) }     // yếu → co giãn thẳng
                        else if !seg.isEmpty, mean >= 0.14 { chosen = seg }
                        else { cursor = regE + 1; continue }
                        newLines.append(contentsOf: chosen); cho += 1
                        let tag = (!seg.isEmpty && mean >= 0.20 && spanOK) ? "mms " + String(format: "%.2f", mean) : "scaled"
                        derr("clone-block @\(String(format: "%.1f", Double(regS) * spf))s u\(R0)..\(U - 1) (\(chosen.count) dòng, \(tag))")
                        cursor = max(chosen.last?.eF ?? 0, min(regE, regS + actual)) + fF(0.3)
                        continue
                    }
                    // (b) vùng hát ngắn → cụm kết (2 dòng chót).
                    //   • ĐUÔI bài (bài còn hát sau khi hết lời): cứ lấp, mẩu ngắn cũng lấp.
                    //   • GIỮA bài: chỉ lỗ lớn (≥12s) kẹp 2 đầu — không đoán bừa vào hơi thở.
                    let regPrevEnd = covBase.filter { $0.eF <= regS + fF(0.5) }.map { $0.eF }.max() ?? 0
                    let midHole = !trailing && (regE - regS) >= fF(12) && regPrevEnd > fF(5) && boundedAfter
                    if contig >= (trailing ? fF(1.2) : fF(2)), coCnt < 6, (trailing || midHole) {
                        let (seg, mean) = lay(coLo, U - 1, regS - fF(0.25), min(T, min(regE + fF(2), regS + fF(16))))
                        if !seg.isEmpty, mean >= (trailing ? 0.10 : 0.16) {
                            newLines.append(contentsOf: seg); coCnt += 1
                            derr("clone-couplet @\(String(format: "%.1f", Double(regS) * spf))s (mms \(String(format: "%.2f", mean)))")
                            cursor = (seg.last?.eF ?? regE) + fF(0.3); continue
                        } else {
                            let sp = scaled(coLo, regS, min(regE - regS, fF(12)))
                            newLines.append(contentsOf: sp); coCnt += 1
                            derr("clone-couplet @\(String(format: "%.1f", Double(regS) * spf))s (scaled)")
                            cursor = (sp.last?.eF ?? regE) + fF(0.3); continue
                        }
                    }
                    cursor = regE + 1
                }
                holes.append(contentsOf: newLines)
                derr("replicate: +\(newLines.count) dòng (\(cho) khối, \(coCnt) cụm kết)")
            }
        }

        dedup.append(contentsOf: holes)
        derr("passLines=\(passLines.count) dedup=\(dedup.count) holes=\(holes.count)")

        } // hết nhánh KHÔNG-phải-lời-đủ

        dedup.sort { $0.sF < $1.sF }

        // ================================================================
        // (M6, TUỲ CHỌN) VÁ THEO CẤU TRÚC ÂM THANH THẬT — chỉ chạy khi có `mixURL`
        // (bản trộn gốc, chưa tách giọng — dò lặp trên bản trộn chính xác hơn dò trên
        // giọng-đã-tách vì phần đệm nhạc vẫn rõ khi giọng bị mờ đúng ở chỗ đang thiếu).
        // Nguyên tắc AN TOÀN: CHỈ THÊM, không sửa/xoá gì đã có; chỉ vá khi 1 cụm audio
        // lặp lại (SSM) TRÙNG với 1 cụm lời ĐÃ ĐƯỢC ĐẶT ở chỗ khác — không bịa lời mới,
        // chỉ nhân bản đúng khối lời đã biết vào đúng cửa sổ thời gian mà cấu trúc thật
        // xác nhận là còn thiếu. Lỗi ở bước này (đọc file, không tìm thấy cặp…) → bỏ qua,
        // không ảnh hưởng luồng chính.
        // ================================================================
        if let mixURL {
            do {
                let (hopX, chromaX, _) = try LocalAligner.extractFeatures(vocalURL: mixURL)
                if chromaX.count > 8 {
                    let repsX = LocalAligner.detectRepeats(chroma: chromaX, hopSec: hopX)

                    // (M7) NGƯỠNG TIN CẬY: đối chứng cấu trúc dò trên bản trộn với cấu trúc dò
                    // trên CHÍNH giọng đã tách (đằng nào cũng đã có `samples` sẵn, khỏi đọc lại
                    // file). Tin cậy CAO (≥1 cặp được cả 2 tầng xác nhận, hoặc ≥4 cặp độc lập
                    // trên bản trộn) → mới thử vá; THẤP → bỏ hẳn bước này, giữ nguyên kết quả
                    // luồng hiện tại (không có gì để "quay về" vì chưa đổi gì).
                    let (hopV, chromaV, _) = LocalAligner.chromaMFCC(samples: samples)
                    let repsV = LocalAligner.detectRepeats(chroma: chromaV, hopSec: hopV)
                    let combined = LocalAligner.combineRepeats(mix: repsX, vocal: repsV)
                    let corroborated = combined.filter { $0.corroborated }.count
                    let confident = repsX.count >= 2 && (corroborated > 0 || repsX.count >= 4)
                    derr("M7 tin cậy: \(repsX.count) cặp (trộn), \(corroborated) được đối chứng bởi giọng → \(confident ? "ĐỦ, thử vá" : "THẤP, bỏ qua M6")")

                    if confident {
                    let seqX = LocalAligner.labelStructure(repeats: repsX, totalFrames: chromaX.count)
                    let secX = LocalAligner.sectionize(uLines)
                    var blockOf: [Int: (lo: Int, hi: Int)] = [:]
                    for s in secX { for u in s.lo...s.hi { blockOf[u] = (s.lo, s.hi) } }
                    // Chữ CHUẨN HOÁ của từng dòng — dùng cho M6c: 2 dòng KHÁC index nhưng
                    // Y HỆT chữ (vd 2 dòng hook giống hệt viết liền nhau ở đoạn tag) vẫn nhận
                    // ra là "cùng 1 câu". KHÔNG dùng cụm của `sectionize` — cụm đó gộp theo
                    // KHỐI NHIỀU DÒNG (biên do thuật toán tham lam chọn), không phải "y hệt
                    // chữ" — 1 dòng có thể rơi vào 1 khối lớn chung với nhiều dòng KHÁC chữ.
                    func normText(_ u: Int) -> String {
                        uLines[u].folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
                            .lowercased().filter { $0.isLetter || $0.isNumber }
                    }

                    // cụm audio -> khối lời [lo,hi] đã CHỨNG MINH khớp (đã có dòng đặt trong đó).
                    var audioToLyricBlock: [Int: (lo: Int, hi: Int)] = [:]
                    for c in dedup {
                        guard let blk = blockOf[c.u] else { continue }
                        let fX = Int(Double(c.sF) * spf / hopX), eX = Int(Double(c.eF) * spf / hopX)
                        for seg in seqX where seg.sF < eX && seg.eF > fX {
                            if audioToLyricBlock[seg.cluster] == nil { audioToLyricBlock[seg.cluster] = blk }
                        }
                    }

                    func coveredX(_ fX: Int) -> Bool {
                        let fV = Int(Double(fX) * hopX / spf)
                        return dedup.contains { fV >= $0.sF - Int(0.7 / spf) && fV <= $0.eF + Int(0.7 / spf) }
                    }

                    if dbg {
                        derr("M6 dbg: dedup=\(dedup.count) secX=\(secX.count) seqX=\(seqX.count) audioToLyricBlock=\(audioToLyricBlock.count)")
                        for seg in seqX {
                            let hasCorr = audioToLyricBlock[seg.cluster] != nil
                            let cov = coveredX((seg.sF + seg.eF) / 2)
                            derr("  seg cụm=\(seg.cluster) @\(String(format: "%.1f", Double(seg.sF)*hopX))-\(String(format: "%.1f", Double(seg.eF)*hopX))s corr=\(hasCorr) covered=\(cov)")
                        }
                    }

                    // (M6) VÁ LỖ theo cấu trúc — CHỈ cho LỜI TẮT. Với LỜI ĐỦ (`fullPaste`),
                    // `base` (canh 1 lượt) đã đặt HẾT các câu đúng thứ tự phủ cả bài; "lỗ" còn
                    // lại chỉ là nhạc dạo (không có gì để vá) hoặc lệch cục bộ ở đầu bài — vá
                    // theo cấu trúc lúc này CHỈ đoán bừa lời KHÁC vào (đã gặp: đặt đoạn cầu vào
                    // ngay đầu bài, đảo lộn hết). → BỎ HẲN M6 khi fullPaste. (M6c gỡ dồn cục
                    // vẫn chạy — nó chỉ nắn dòng ĐÃ CÓ, không bịa chỗ mới.)
                    var addedX = 0
                    var patched: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                    for seg in seqX where !fullPaste {
                        guard addedX < 6, let blk = audioToLyricBlock[seg.cluster] else { continue }
                        let mid = (seg.sF + seg.eF) / 2
                        guard !coveredX(mid) else { continue }
                        let a = max(0, Int(Double(seg.sF) * hopX / spf) - Int(1.0 / spf))
                        let z = min(T, Int(Double(seg.eF) * hopX / spf) + Int(1.0 / spf))
                        guard z - a > Int(1.5 / spf) else { continue }
                        let ws = (blk.lo...blk.hi).flatMap { uWords[$0] }
                        guard !ws.isEmpty else { continue }
                        derr("  M6 thử cụm\(seg.cluster): blk=u\(blk.lo)..\(blk.hi) (\(ws.count) từ) window=\(String(format: "%.1f", Double(a)*spf))-\(String(format: "%.1f", Double(z)*spf))s (\(String(format: "%.1f", Double(z-a)*spf))s) chữ=\"\(ws.prefix(6).joined(separator: " "))…\"")
                        let sfp = starFlat(ws)
                        let sp = forcedAlign(emission: Array(emission[a..<z]), targets: sfp.flat)
                        let w = wordsFrom(spans: sp, ranges: sfp.ranges, words: ws, frameOffset: a, secPerFrame: spf)
                        guard w.count == ws.count else {
                            derr("  M6 bỏ cụm\(seg.cluster): w.count \(w.count) != ws.count \(ws.count)"); continue
                        }
                        let mean = w.reduce(0.0) { $0 + ($1.score ?? 0) } / Double(max(1, w.count))
                        var newSeg: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                        var wi = 0
                        for u in blk.lo...blk.hi {
                            let n = uWords[u].count
                            let wseg = Array(w[min(wi, w.count)..<min(wi + n, w.count)]); wi += n
                            guard let s0 = wseg.first?.start, let e0 = wseg.last?.end else { continue }
                            let cap = max(3.0, 0.34 * Double(charCount(u)))
                            let sF2 = Int(s0 / spf), eF2 = Int(min(e0, s0 + cap) / spf)
                            newSeg.append((u, sF2, max(eF2, sF2 + 1), max(0.22, mean)))
                        }
                        guard !newSeg.isEmpty else { continue }
                        // chống co dúm 1 chỗ: hoặc điểm MMS khá, hoặc trải đủ rộng trong cửa sổ.
                        let spanOK = (newSeg.last!.eF - newSeg.first!.sF) >= (z - a) * 4 / 10
                        guard mean >= 0.14 || (mean >= 0.08 && spanOK) else {
                            derr("  M6 bỏ cụm\(seg.cluster): điểm=\(String(format: "%.2f", mean)) spanOK=\(spanOK)"); continue
                        }
                        // không chồng lên dòng đã có (kể cả dòng M6 vừa thêm trong vòng này).
                        let clash = (dedup + patched).contains { !($0.eF <= newSeg.first!.sF || $0.sF >= newSeg.last!.eF) }
                        guard !clash else {
                            derr("  M6 bỏ cụm\(seg.cluster): đè lên dòng đã có"); continue
                        }
                        patched.append(contentsOf: newSeg)
                        addedX += 1
                        derr("M6 vá cấu trúc @\(String(format: "%.1f", Double(seg.sF) * hopX))s <- u\(blk.lo)..\(blk.hi) (điểm=\(String(format: "%.2f", mean)))")
                    }
                    if !patched.isEmpty {
                        dedup.append(contentsOf: patched)
                        dedup.sort { $0.sF < $1.sF }
                        derr("M6: +\(patched.count) dòng vá theo cấu trúc")
                    }

                    // ================================================================
                    // (M6c) GỠ DỒN CỤC — 2+ dòng CÙNG 1 CÂU bị `base` (canh 1 lượt) đặt
                    // sát/đè lên nhau (không câu hát thật nào lặp lại cách nhau <3s cả) —
                    // dấu hiệu base hết cách phân biệt các lần lặp identical gần cuối bài.
                    // Dùng ĐÚNG cấu trúc audio thật (seqX) đã dò để tách về đúng các lần
                    // lặp THẬT trong 1 vùng LÂN CẬN hẹp quanh chỗ dồn cục — không đụng
                    // những chỗ khác của bài đang đặt đúng.
                    // ================================================================
                    func coveredExcluding(_ fX: Int, excluding: Set<Int>) -> Bool {
                        let fV = Int(Double(fX) * hopX / spf)
                        for (idx, c) in dedup.enumerated() where !excluding.contains(idx) {
                            if fV >= c.sF - Int(0.7 / spf) && fV <= c.eF + Int(0.7 / spf) { return true }
                        }
                        return false
                    }
                    // chữ (chuẩn hoá) -> các cụm audio mà 1 dòng CÓ CHỮ ĐÓ đang chồng lên
                    // (đọc lại từ `dedup` hiện có — không suy qua block/cụm của sectionize,
                    // tránh nhầm "chung khối nhiều dòng" với "y hệt chữ").
                    var textToAudioClusters: [String: Set<Int>] = [:]
                    for c in dedup {
                        let fX = Int(Double(c.sF) * spf / hopX), eX = Int(Double(c.eF) * spf / hopX)
                        let t = normText(c.u)
                        for seg in seqX where seg.sF < eX && seg.eF > fX {
                            textToAudioClusters[t, default: []].insert(seg.cluster)
                        }
                    }
                    var consumed = Set<Int>()
                    var reflowed: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                    var bi = 0
                    while bi < dedup.count {
                        guard !consumed.contains(bi) else { bi += 1; continue }
                        let myText = normText(dedup[bi].u)
                        var run = [bi]
                        var bj = bi
                        while bj + 1 < dedup.count, normText(dedup[bj + 1].u) == myText,
                              dedup[bj + 1].sF - dedup[bj].eF < Int(3.0 / spf) {
                            run.append(bj + 1); bj += 1
                        }
                        defer { bi = bj + 1 }
                        guard run.count >= 2, !myText.isEmpty else { continue }
                        derr("  M6c dò: u\(dedup[bi].u) run=\(run.count) @\(String(format: "%.1f", Double(dedup[bi].sF)*spf))s chữ=\"\(uLines[dedup[bi].u].prefix(24))\"")
                        let clusters = Array(textToAudioClusters[myText] ?? [])
                        derr("  M6c: audioClusters=\(clusters)")
                        guard !clusters.isEmpty else { continue }
                        // CHÚ Ý ĐƠN VỊ: `dedup[...].sF/eF` là khung THEO `spf` (giọng), còn
                        // `seg.sF/eF` (seqX) là khung THEO `hopX` (bản trộn) — 2 lưới khung
                        // KHÁC nhau. Quy hết về GIÂY trước khi so, không so thẳng số khung.
                        let spanLoSec = Double(dedup[run.first!].sF) * spf - 30.0
                        let spanHiSec = Double(dedup[run.last!].eF) * spf + 30.0
                        let excl = Set(run)
                        let candSegs = seqX
                            .filter { clusters.contains($0.cluster)
                                && Double($0.sF) * hopX < spanHiSec && Double($0.eF) * hopX > spanLoSec
                                && !coveredExcluding(($0.sF + $0.eF) / 2, excluding: excl) }
                            .sorted { $0.sF < $1.sF }
                        derr("  M6c: candSegs=\(candSegs.count) cần \(run.count)")
                        guard !candSegs.isEmpty else { continue }
                        // Thử XÁC NHẬN từng chỗ bằng MMS thật (không chỉ tin cấu trúc SSM —
                        // 2 đoạn nhạc GIỐNG NHAU không có nghĩa CÙNG LỜI, đã gặp ở nơi khác).
                        // Có thể xác nhận ÍT hơn số dòng dồn cục thật (lời gõ dư — bài THẬT
                        // không lặp nhiều lần như vậy) → GIỮ đúng số lần THẬT, bỏ bản dư THỪA
                        // (là bản sao/đè lên nhau, chữ vẫn còn nguyên ở bản giữ lại — không mất
                        // nội dung nào, chỉ gỡ hình ảnh chồng/dồn cục).
                        let tryCount = min(candSegs.count, run.count)
                        var verified: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                        for k in 0..<tryCount {
                            let seg = candSegs[k]
                            let ri = run[k]
                            let a = max(0, Int(Double(seg.sF) * hopX / spf) - Int(1.0 / spf))
                            let z = min(T, Int(Double(seg.eF) * hopX / spf) + Int(1.0 / spf))
                            guard z - a > Int(1.0 / spf) else { continue }
                            let ws = uWords[dedup[ri].u]
                            guard !ws.isEmpty else { continue }
                            let sfp = starFlat(ws)
                            let sp = forcedAlign(emission: Array(emission[a..<z]), targets: sfp.flat)
                            let w = wordsFrom(spans: sp, ranges: sfp.ranges, words: ws, frameOffset: a, secPerFrame: spf)
                            guard w.count == ws.count, let s0 = w.first?.start, let e0 = w.last?.end else { continue }
                            let mean = w.reduce(0.0) { $0 + ($1.score ?? 0) } / Double(max(1, w.count))
                            derr("    M6c thử @\(String(format: "%.1f", Double(a)*spf))-\(String(format: "%.1f", Double(z)*spf))s điểm=\(String(format: "%.2f", mean))")
                            guard mean >= 0.10 else { continue }
                            let cap = max(3.0, 0.34 * Double(charCount(dedup[ri].u)))
                            let sF2 = Int(s0 / spf), eF2 = Int(min(e0, s0 + cap) / spf)
                            verified.append((dedup[ri].u, sF2, max(eF2, sF2 + 1), max(0.22, mean)))
                        }
                        guard !verified.isEmpty else { continue }
                        let sortedV = verified.sorted { $0.sF < $1.sF }
                        let spreadOK = sortedV.count < 2
                            || (0..<(sortedV.count - 1)).allSatisfy { sortedV[$0].eF <= sortedV[$0 + 1].sF }
                        guard spreadOK else { continue }

                        reflowed.append(contentsOf: verified)
                        consumed.formUnion(run)
                        if verified.count < run.count {
                            derr("M6c gỡ dồn cục (1 phần): u\(dedup[bi].u) x\(run.count) — chỉ xác nhận được \(verified.count) lần THẬT, bỏ \(run.count - verified.count) bản trùng thừa (chữ vẫn còn ở bản giữ lại)")
                        } else {
                            derr("M6c gỡ dồn cục: u\(dedup[bi].u) x\(run.count) @\(String(format: "%.1f", Double(dedup[bi].sF) * spf))s → trải vào \(run.count) đoạn thật")
                        }
                    }
                    if !reflowed.isEmpty {
                        var kept: [(u: Int, sF: Int, eF: Int, score: Double)] = []
                        for (idx, c) in dedup.enumerated() where !consumed.contains(idx) { kept.append(c) }
                        kept.append(contentsOf: reflowed)
                        kept.sort { $0.sF < $1.sF }
                        dedup = kept
                        derr("M6c: gỡ dồn cục \(consumed.count) dòng → \(reflowed.count) dòng trải lại")
                    }
                    }  // hết nhánh confident (M7)
                }
            } catch { derr("M6 lỗi (bỏ qua): \(error)") }
        }

        // ================================================================
        // (F) Mốc TỪNG CHỮ trong CHÍNH cửa sổ audio của lần hát đó + chống trôi.
        // ================================================================
        let padF = max(4, Int(0.4 / spf))
        var built: [(t: Double, u: Int, sc: Double, line: AlignResponse.Line)] = []
        for c in dedup {
            let a = max(0, c.sF - padF), z = min(T, c.eF + padF)
            var w: [AlignResponse.Word] = []
            if z - a >= 4 {
                let sp = forcedAlign(emission: Array(emission[a..<z]), targets: sfs[c.u].flat)
                w = wordsFrom(spans: sp, ranges: sfs[c.u].ranges, words: uWords[c.u], frameOffset: a, secPerFrame: spf)
            }
            if w.isEmpty {
                w = spreadWords(uWords[c.u], start: Double(c.sF) * spf, end: Double(c.eF) * spf + 0.3)
            }
            if let s = w.first?.start, let e = w.last?.end {
                let cap = max(4.0, 0.34 * Double(charCount(c.u)))
                if e - s > cap { w = spreadWords(uWords[c.u], start: s, end: s + cap) }
            }
            built.append((w.first?.start ?? Double(c.sF) * spf, c.u, c.score,
                          AlignResponse.Line(line_index: 0, text: uLines[c.u], words: w)))
        }

        // ================================================================
        // (G) Bảo đảm MỌI dòng user xuất hiện >= 1 lần — chèn GIỮA 2 hàng xóm (u nhỏ hơn / lớn hơn)
        //     của LƯỢT ĐẦU; nếu không có thì dùng mốc dự phòng (A).
        // ================================================================
        let seen = Set(built.map { $0.u })
        if seen.count < U {
            // lượt đầu = các dòng built trước mốc lặp đầu tiên (u giảm)
            var firstPass: [(u: Int, t: Double, e: Double)] = []
            let sorted = built.sorted { $0.t < $1.t }
            for b in sorted {
                if let last = firstPass.last, b.u <= last.u { break }
                firstPass.append((b.u, b.line.words.first?.start ?? b.t, b.line.words.last?.end ?? b.t))
            }
            for u in 0..<U where !seen.contains(u) {
                let before = firstPass.last(where: { $0.u < u })
                let after  = firstPass.first(where: { $0.u > u })
                let s0: Double, e0: Double
                if let a = before, let z = after, z.t > a.e {
                    let cnt = Double(z.u - a.u)
                    let step = (z.t - a.e) / max(1, cnt)
                    s0 = a.e + step * Double(u - a.u - 1) + step * 0.1
                    e0 = s0 + min(step * 0.85, max(2.0, 0.28 * Double(charCount(u))))
                } else {
                    s0 = Double(lineFrame[u].s) * spf
                    e0 = min(Double(lineFrame[u].e) * spf, s0 + max(2.0, 0.28 * Double(charCount(u))))
                }
                // điểm 0.34: hơn rác (dọn chồng sẽ giữ), kém dòng canh chuẩn.
                built.append((s0, u, 0.34, AlignResponse.Line(line_index: 0, text: uLines[u],
                    words: spreadWords(uWords[u], start: s0, end: max(e0, s0 + 0.6)))))
            }
        }
        built.sort { $0.t < $1.t }

        // (H) — (2026-09-06) KHÔNG bỏ câu nào. User gõ ĐỦ lời → mọi câu phải hiện, kể cả
        // điệp khúc / cụm kết lặp gõ liền nhau ở cuối bài. Câu đè nhau sẽ được
        // `AdvancedKaraoke.tidyOverlaps` đẩy về sau + co lại ở bước cuối.
        let pruned = built

        let out = pruned.enumerated().map {
            AlignResponse.Line(line_index: $0.offset, text: $0.element.line.text, words: $0.element.line.words)
        }
        progress(0.97)
        derr("out=\(out.count) U=\(U)")

        guard out.count >= 1, out.count <= U * 6 else { throw LocalAlignerError.badOutput }
        return out
    }



    private struct Phrase {
        let sF: Int; let eF: Int
        func startSec(_ spf: Double) -> Double { Double(sF) * spf }
        func endSec(_ spf: Double)   -> Double { Double(eF) * spf }
    }

    /// Khung nào "có tiếng hát" = xác suất blank thấp; gộp thành câu hát.
    /// Ngưỡng tự điều chỉnh để ra số câu hợp lý (8…200).
    private static func voicedPhrases(emission: [[Float]], spf: Double) -> [Phrase] {
        let T = emission.count
        guard T > 8 else { return [] }
        var nb = [Double](repeating: 0, count: T)
        for f in 0..<T { nb[f] = 1.0 - exp(Double(emission[f][blankID])) }
        // trung bình trượt ±4 khung
        var pre = [Double](repeating: 0, count: T + 1)
        for f in 0..<T { pre[f + 1] = pre[f] + nb[f] }
        let w = 4
        var sm = [Double](repeating: 0, count: T)
        for f in 0..<T {
            let lo = max(0, f - w), hi = min(T, f + w + 1)
            sm[f] = (pre[hi] - pre[lo]) / Double(hi - lo)
        }
        let minGapF = max(1, Int(0.30 / spf))
        let minLenF = max(1, Int(0.28 / spf))
        let maxLenF = max(4, Int(9.0 / spf))

        func build(_ thr: Double) -> [Phrase] {
            var run: [Phrase] = []
            var f = 0
            while f < T {
                while f < T && sm[f] < thr { f += 1 }
                guard f < T else { break }
                let s = f
                while f < T && sm[f] >= thr { f += 1 }
                run.append(Phrase(sF: s, eF: f))
            }
            var merged: [Phrase] = []
            for ph in run {
                if let last = merged.last, ph.sF - last.eF < minGapF {
                    merged[merged.count - 1] = Phrase(sF: last.sF, eF: ph.eF)
                } else { merged.append(ph) }
            }
            merged = merged.filter { $0.eF - $0.sF >= minLenF }
            // Cắt đoạn dài thành các câu hát ~3.5s; mỗi ranh giới nắn về chỗ TRŨNG nhất
            // trong ±1.5s (giọng ngân dài / bleed nhạc không tạo khoảng lặng rõ).
            let tgtF = max(minLenF * 2, Int(3.5 / spf))
            var split: [Phrase] = []
            for ph in merged {
                let len = ph.eF - ph.sF
                if len <= maxLenF { split.append(ph); continue }
                let pieces = max(2, Int((Double(len) / Double(tgtF)).rounded()))
                var prev = ph.sF
                for i in 1..<pieces {
                    let target = ph.sF + len * i / pieces
                    let lo = max(prev + minLenF, target - tgtF / 2)
                    let hi = min(ph.eF - minLenF, target + tgtF / 2)
                    var cut = target
                    if lo < hi {
                        var mv = Double.greatestFiniteMagnitude
                        for j in lo..<hi where sm[j] < mv { mv = sm[j]; cut = j }
                    }
                    if cut > prev + minLenF { split.append(Phrase(sF: prev, eF: cut)); prev = cut }
                }
                split.append(Phrase(sF: prev, eF: ph.eF))
            }
            return split.filter { $0.eF - $0.sF >= minLenF }.sorted { $0.sF < $1.sF }
        }

        for thr in [0.14, 0.11, 0.18, 0.09, 0.22] {
            let r = build(thr)
            if r.count >= 8 && r.count <= 200 { return r }
        }
        return build(0.13)
    }

    /// (Dự án "Nhân bản lời thiếu" — M1) Cắt lời user thành các KHỐI liên tục, phủ hết
    /// 0..<U, không chồng không hở. Khối nào TRÙNG NGUYÊN VĂN khối khác (bất kể đứng đâu)
    /// thì gắn cùng `cluster` — đó là tín hiệu "đoạn này lặp lại" lấy thẳng từ lời user gõ,
    /// không dùng điểm khớp MMS. Biên khối: với mỗi dòng bắt đầu, lấy đoạn DÀI NHẤT có bản
    /// sao y hệt ở chỗ khác trong bài (ưu tiên đoạn dài trước, không chồng lấn).
    static func sectionize(_ uLines: [String]) -> [(lo: Int, hi: Int, cluster: Int)] {
        let U = uLines.count
        guard U > 0 else { return [] }
        func norm(_ s: String) -> String {
            s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN"))
                .lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let nm = uLines.map(norm)

        var ranges: [(Int, Int)] = []
        for a in 0..<U {
            var b = U - 1
            while b >= a + 1 {
                let L = b - a + 1
                var found = false, c = 0
                while c + L <= U {
                    if c != a, Array(nm[c..<c + L]) == Array(nm[a..<b + 1]) { found = true; break }
                    c += 1
                }
                if found { ranges.append((a, b)); break }
                b -= 1
            }
        }
        ranges.sort { ($0.1 - $0.0) > ($1.1 - $1.0) }
        var blocks: [(Int, Int)] = []
        for r in ranges where !blocks.contains(where: { r.0 <= $0.1 && r.1 >= $0.0 }) { blocks.append(r) }
        var covered = [Bool](repeating: false, count: U)
        for (a, b) in blocks { for k in a...b { covered[k] = true } }
        var k = 0
        while k < U {
            if covered[k] { k += 1; continue }
            var e = k; while e + 1 < U, !covered[e + 1] { e += 1 }
            blocks.append((k, e)); k = e + 1
        }
        blocks.sort { $0.0 < $1.0 }

        var clusterOf: [String: Int] = [:]
        var nextID = 0
        return blocks.map { (a, b) in
            let key = (a...b).map { nm[$0] }.joined(separator: "␟")
            let id = clusterOf[key] ?? { let i = nextID; clusterOf[key] = i; nextID += 1; return i }()
            return (a, b, id)
        }
    }

    /// Đọc file giọng (16kHz mono) rồi trích chroma/MFCC — dùng cho `--feat-test` và M2 sau này.
    static func extractFeatures(vocalURL: URL) throws -> (hopSec: Double, chroma: [[Float]], mfcc: [[Float]]) {
        let samples = try read16kMono(vocalURL)
        return chromaMFCC(samples: samples)
    }

    /// Đọc file âm thanh (16kHz mono) trả mẫu thô — dùng cho `--regress-test` (M8) để dò
    /// đoạn CÓ HÁT (`vocalPhrases`) mà không cần chạy lại toàn bộ mô hình canh giờ.
    static func readSamples(_ url: URL) throws -> [Float] { try read16kMono(url) }

    /// Đoạn nào (giây) đang CÓ HÁT trong file — bọc `vocalPhrases` với lưới 20ms cho gọn,
    /// không cần `spf` thật của mô hình MMS.
    static func sungIntervals(samples: [Float]) -> [(start: Double, end: Double)] {
        let hopSec = 0.02
        let T = Int(Double(samples.count) / Double(sr) / hopSec) + 10
        return vocalPhrases(samples: samples, spf: hopSec, frames: T)
            .map { (Double($0.sF) * hopSec, Double($0.eF) * hopSec) }
    }

    /// (Dự án "Nhân bản lời thiếu" — M2) Đặc trưng âm thanh theo khung ~0.25s: CHROMA (12 lớp cao
    /// độ, "điệp khúc giống điệp khúc" kể cả đổi tông) và MFCC (13 hệ số, màu âm — verse khác bridge).
    /// Cùng khuôn FFT/vDSP đã dùng ở `SpectrumAnalyzer` (đã kiểm chứng), chỉ khác cách gộp bin.
    static func chromaMFCC(samples: [Float], sampleRate: Int = sr, hopSec: Double = 0.25, fftSize: Int = 4096)
        -> (hopSec: Double, chroma: [[Float]], mfcc: [[Float]]) {
        let n = fftSize, half = n / 2
        guard samples.count > n else { return (hopSec, [], []) }
        let log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (hopSec, [], []) }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let hop = max(1, Int(hopSec * Double(sampleRate)))
        let nFrames = max(0, (samples.count - n) / hop + 1)
        guard nFrames > 0 else { return (hopSec, [], []) }

        // bin FFT → lớp cao độ 0..11 (bỏ quá trầm <60Hz / quá cao >5kHz, không mang nhiều thông tin hợp âm)
        let binHz = Double(sampleRate) / Double(n)
        var chromaMap = [Int](repeating: -1, count: half)
        for k in 1..<half {
            let f = Double(k) * binHz
            guard f >= 60, f <= 5000 else { continue }
            let midi = 69.0 + 12.0 * log2(f / 440.0)
            chromaMap[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }
        // bộ lọc tam giác thang Mel (26 dải, 0–8kHz hoặc tới Nyquist) + ma trận DCT-II (giữ 13 hệ số)
        let nMel = 26, nMfcc = 13
        func hz2mel(_ f: Double) -> Double { 2595.0 * log10(1.0 + f / 700.0) }
        func mel2hz(_ m: Double) -> Double { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }
        let nyq = Double(sampleRate) / 2, melHi = hz2mel(min(nyq, 8000))
        var binPts = [Int](repeating: 0, count: nMel + 2)
        for i in 0...(nMel + 1) {
            let f = mel2hz(hz2mel(0) + melHi * Double(i) / Double(nMel + 1))
            binPts[i] = max(0, min(half - 1, Int((f / binHz).rounded())))
        }
        var filt = [[Float]](repeating: [Float](repeating: 0, count: half), count: nMel)
        for m in 1...nMel {
            let f0 = binPts[m - 1], f1 = binPts[m], f2 = binPts[m + 1]
            if f1 > f0 { for k in f0..<f1 { filt[m - 1][k] = Float(k - f0) / Float(max(1, f1 - f0)) } }
            if f2 > f1 { for k in f1..<f2 { filt[m - 1][k] = Float(f2 - k) / Float(max(1, f2 - f1)) } }
        }
        var dct = [[Float]](repeating: [Float](repeating: 0, count: nMel), count: nMfcc)
        for c in 0..<nMfcc { for m in 0..<nMel {
            dct[c][m] = Float(cos(Double.pi / Double(nMel) * (Double(m) + 0.5) * Double(c)))
        } }

        var chromaOut = [[Float]](repeating: [Float](repeating: 0, count: 12), count: nFrames)
        var mfccOut = [[Float]](repeating: [Float](repeating: 0, count: nMfcc), count: nFrames)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: n)
        var mags = [Float](repeating: 0, count: half)

        samples.withUnsafeBufferPointer { sp in
            for fi in 0..<nFrames {
                let start = fi * hop
                vDSP_vmul(sp.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                var cnt = Int32(half)
                vvsqrtf(&mags, mags, &cnt)

                var chroma = [Float](repeating: 0, count: 12)
                mags.withUnsafeBufferPointer { magp in
                    for k in 1..<half where chromaMap[k] >= 0 { chroma[chromaMap[k]] += magp[k] }
                }
                let cmax = chroma.max() ?? 0
                if cmax > 1e-9 { for i in 0..<12 { chroma[i] /= cmax } }
                chromaOut[fi] = chroma

                var mfcc = [Float](repeating: 0, count: nMfcc)
                var logMel = [Float](repeating: 0, count: nMel)
                for m in 0..<nMel {
                    var s: Float = 0
                    vDSP_dotpr(mags, 1, filt[m], 1, &s, vDSP_Length(half))
                    logMel[m] = log(max(s, 1e-8))
                }
                for c in 0..<nMfcc { var s: Float = 0; vDSP_dotpr(logMel, 1, dct[c], 1, &s, vDSP_Length(nMel)); mfcc[c] = s }
                mfccOut[fi] = mfcc
            }
        }
        return (Double(hop) / Double(sampleRate), chromaOut, mfccOut)
    }

    /// (Dự án "Nhân bản lời thiếu" — M3) Dò ĐOẠN LẶP trong bài từ chroma: so mọi cặp khung (ma trận
    /// tự-tương-đồng), tìm đường chéo (lệch `d` khung) mà độ giống ở mức CAO LIÊN TỤC đủ dài
    /// → đoạn [a,aEnd) giống hệt đoạn [b,bEnd) (điệp khúc/phiên khúc hát lại). Ngưỡng tự thích ứng
    /// theo phân vị của chính bài đó (không hằng số cứng cho mọi bài — giống RefraiD/Goto).
    static func detectRepeats(chroma: [[Float]], hopSec: Double,
                              minRepeatSec: Double = 6.0, minGapSec: Double = 8.0)
        -> [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)] {
        let N = chroma.count
        guard N > 8 else { return [] }
        let dim = chroma[0].count
        var vecs = chroma
        for i in 0..<N {
            var norm: Float = 0
            for v in vecs[i] { norm += v * v }
            norm = sqrt(max(norm, 1e-9))
            for k in 0..<dim { vecs[i][k] /= norm }
        }
        func sim(_ i: Int, _ j: Int) -> Float {
            var s: Float = 0
            for k in 0..<dim { s += vecs[i][k] * vecs[j][k] }
            return s
        }
        let minLen = max(4, Int(minRepeatSec / hopSec))
        let minGap = max(1, Int(minGapSec / hopSec))

        // ngưỡng thích ứng: phân vị 90% của độ giống lấy mẫu đều (lưới), bỏ vùng sát đường chéo chính
        var samples: [Float] = []
        let step = max(1, N / 300)
        var si = 0
        while si < N { var sj = 0; while sj < N { if abs(si - sj) > minGap { samples.append(sim(si, sj)) }; sj += step }; si += step }
        samples.sort()
        let thr = samples.isEmpty ? 0.85 : samples[min(samples.count - 1, Int(Double(samples.count) * 0.90))]
        let softThr = thr * 0.85

        var found: [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)] = []
        var d = minGap
        while d < N - minLen {
            var i = 0
            while i < N - d {
                if sim(i, i + d) >= thr {
                    let start = i
                    var acc: Float = 0, cnt = 0
                    while i < N - d, sim(i, i + d) >= softThr { acc += sim(i, i + d); cnt += 1; i += 1 }
                    let len = i - start
                    if len >= minLen { found.append((start, start + len, start + d, start + d + len, acc / Float(max(1, cnt)))) }
                } else { i += 1 }
            }
            d += 1
        }
        // rút gọn: bỏ cặp bị cặp DÀI HƠN bao trọn (cùng offset ±2 khung)
        found.sort { ($0.aEnd - $0.a) > ($1.aEnd - $1.a) }
        var kept: [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)] = []
        for f in found {
            let dupOf = kept.contains { k in f.a >= k.a - 2 && f.aEnd <= k.aEnd + 2 && f.b >= k.b - 2 && f.bEnd <= k.bEnd + 2 }
            if !dupOf { kept.append(f) }
        }
        return kept.sorted { $0.a < $1.a }
    }

    /// (M3+) Kết hợp 2 tầng dò lặp làm đối chứng: BẢN TRỘN GỐC là tầng CHÍNH (bắt được nhiều nhất,
    /// kể cả đúng chỗ giọng mờ — chỗ hay cần vá nhất). GIỌNG TÁCH là tầng ĐỐI CHỨNG tăng độ tin,
    /// KHÔNG PHẢI CỔNG bắt buộc: nếu đòi cả 2 tầng cùng đồng ý (AND) mới nhận, sẽ MẤT đúng ca khó
    /// nhất — ví dụ "dạo bước tiểu băng" chỉ bản trộn tìm ra đoạn 164–224s, tầng giọng bỏ sót vì
    /// đúng chỗ đó stem mờ. Cặp nào giọng CŨNG thấy → +độ tin (dùng để phân xử khi M5 phải chọn
    /// giữa nhiều ứng viên). Cặp giọng thấy mà bản trộn không thấy → vẫn giữ riêng (hiếm nhưng thật).
    static func combineRepeats(mix: [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)],
                               vocal: [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)])
        -> [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float, corroborated: Bool, source: String)] {
        func sameLag(_ x: (a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float),
                     _ y: (a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)) -> Bool {
            guard abs((x.b - x.a) - (y.b - y.a)) <= 6 else { return false }
            return min(x.aEnd, y.aEnd) - max(x.a, y.a) > 0
        }
        var out: [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float, corroborated: Bool, source: String)] = []
        for m in mix {
            let hit = vocal.contains { sameLag(m, $0) }
            out.append((m.a, m.aEnd, m.b, m.bEnd, hit ? min(1, m.score + 0.04) : m.score, hit, "trộn"))
        }
        for v in vocal where !mix.contains(where: { sameLag($0, v) }) {
            out.append((v.a, v.aEnd, v.b, v.bEnd, v.score, false, "chỉ-giọng"))
        }
        return out.sorted { $0.a < $1.a }
    }

    /// (M4) Từ danh sách cặp đoạn lặp (M3) → CHUỖI đoạn cấu trúc có NHÃN, phủ hết timeline
    /// [0, totalFrames). Đoạn nào không nằm trong cặp lặp nào → nhãn riêng (không lặp, vd verse/bridge).
    static func labelStructure(repeats: [(a: Int, aEnd: Int, b: Int, bEnd: Int, score: Float)], totalFrames: Int,
                               bridgeFrames: Int = 24)
        -> [(sF: Int, eF: Int, cluster: Int)] {
        guard totalFrames > 0 else { return [] }
        // 1. gộp các cặp GẦN NHAU/CHỒNG LẤN cùng độ lệch (lag) thành 1 cặp lớn hơn — chống vụn.
        let pairs = repeats.sorted { $0.a < $1.a }
        var merged: [(a: Int, aEnd: Int, b: Int, bEnd: Int)] = []
        for p in pairs {
            if var last = merged.last,
               abs((p.b - p.a) - (last.b - last.a)) <= 6,
               p.a <= last.aEnd + 12 {
                let lag = last.b - last.a
                last.aEnd = max(last.aEnd, p.aEnd)
                last.bEnd = last.aEnd + lag
                merged[merged.count - 1] = last
            } else {
                merged.append((p.a, p.aEnd, p.b, p.bEnd))
            }
        }

        // 2. mọi mốc biên (2 đầu mỗi cặp) + 0 + hết bài → chia timeline thành đoạn nhỏ liên tục ("atom").
        var bounds = Set<Int>([0, totalFrames])
        for m in merged {
            bounds.insert(max(0, min(totalFrames, m.a))); bounds.insert(max(0, min(totalFrames, m.aEnd)))
            bounds.insert(max(0, min(totalFrames, m.b))); bounds.insert(max(0, min(totalFrames, m.bEnd)))
        }
        let sb = bounds.sorted()
        var atoms: [(s: Int, e: Int)] = []
        for i in 0..<sb.count - 1 where sb[i + 1] > sb[i] { atoms.append((sb[i], sb[i + 1])) }
        guard !atoms.isEmpty else { return [] }
        func atomIndex(at f: Int) -> Int? { atoms.firstIndex { f >= $0.s && f < $0.e } }

        // 3. union-find giữa atom theo từng cặp lặp: atom nằm trong vế A ↔ atom tương ứng trong vế B.
        var parent = Array(0..<atoms.count)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        func union(_ x: Int, _ y: Int) { let a = find(x), b = find(y); if a != b { parent[max(a, b)] = min(a, b) } }
        for m in merged {
            let lag = m.b - m.a
            for (idx, at) in atoms.enumerated() where at.s >= m.a && at.e <= m.aEnd {
                if let ib = atomIndex(at: at.s + lag) { union(idx, ib) }
            }
        }

        // 4. gộp atom liền kề CÙNG cụm (root) thành đoạn cuối; atom không thuộc cặp nào → cụm riêng.
        var clusterOf: [Int: Int] = [:]
        var nextID = 0
        func clusterID(_ root: Int) -> Int {
            if let id = clusterOf[root] { return id }
            let id = nextID; clusterOf[root] = id; nextID += 1; return id
        }
        var out: [(sF: Int, eF: Int, cluster: Int)] = []
        var i = 0
        while i < atoms.count {
            let root = find(i)
            var j = i
            while j + 1 < atoms.count, find(j + 1) == root { j += 1 }
            out.append((atoms[i].s, atoms[j].e, clusterID(root)))
            i = j + 1
        }

        // 5. BẮC CẦU: đoạn NGẮN "riêng" (không lặp ai) kẹp giữa 2 đoạn CÙNG cụm → coi là dao động
        //    nhỏ trong 1 lần lặp liên tục (không phải ranh giới thật), gộp vào cụm 2 bên.
        var bridged = out
        var idx = 1
        while idx + 1 < bridged.count {
            let dur = bridged[idx].eF - bridged[idx].sF
            if bridged[idx - 1].cluster == bridged[idx + 1].cluster,
               bridged[idx].cluster != bridged[idx - 1].cluster,
               dur <= bridgeFrames {
                let joined = (bridged[idx - 1].sF, bridged[idx + 1].eF, bridged[idx - 1].cluster)
                bridged.replaceSubrange((idx - 1)...(idx + 1), with: [joined])
                idx = max(1, idx - 1)
            } else {
                idx += 1
            }
        }
        return bridged
    }

    /// Cắt vocal thành "câu hát" theo NĂNG LƯỢNG: vùng có tiếng, ngắt ở khoảng lặng ≥ ~0.3s.
    /// Trả [(khungBắtĐầu, khungKết)] theo giờ khung emission.
    static func vocalPhrases(samples: [Float], spf: Double, frames T: Int) -> [(sF: Int, eF: Int)] {
        guard T > 20, samples.count > sr else { return [] }
        let hop = max(1, Int(0.02 * Double(sr)))               // 20ms
        let win = max(hop, Int(0.05 * Double(sr)))             // 50ms cửa sổ RMS
        var pfx = [Double](repeating: 0, count: samples.count + 1)
        for i in 0..<samples.count { pfx[i + 1] = pfx[i] + Double(samples[i]) * Double(samples[i]) }
        let nb = max(1, samples.count / hop)
        var e = [Double](repeating: 0, count: nb)
        for k in 0..<nb {
            let c = k * hop, a = max(0, c - win / 2), b = min(samples.count, c + win / 2)
            e[k] = b > a ? (pfx[b] - pfx[a]) / Double(b - a) : 0
        }
        let srt = e.sorted()
        let lo = srt[srt.count * 15 / 100], hi = srt[min(srt.count - 1, srt.count * 90 / 100)]
        let thr = lo + 0.06 * max(1e-12, hi - lo)
        let hopSec = Double(hop) / Double(sr)
        let minGap = max(1, Int(0.30 / hopSec)), minLen = max(1, Int(0.34 / hopSec))
        var v = (0..<nb).map { e[$0] > thr }
        var k = 0                                              // lấp khoảng lặng ngắn (hơi thở)
        while k < nb {
            if v[k] { k += 1; continue }
            var g = k; while g < nb, !v[g] { g += 1 }
            if g - k < minGap, k > 0, g < nb { for x in k..<g { v[x] = true } }
            k = g
        }
        var runs: [(Int, Int)] = []
        k = 0
        while k < nb {
            while k < nb, !v[k] { k += 1 }
            guard k < nb else { break }
            let s = k
            while k < nb, v[k] { k += 1 }
            runs.append((s, k))
        }
        let scale = hopSec / spf
        return runs.filter { $0.1 - $0.0 >= minLen }
            .map { (Int(Double($0.0) * scale), max(Int(Double($0.0) * scale) + 1, Int(Double($0.1) * scale))) }
    }

    /// Gán MỖI dòng lời vào MỘT câu hát, ĐÚNG thứ tự (cho phép gộp/tách nhẹ khi lệch số lượng).
    /// Quy hoạch động cực tiểu tổng |thời-lượng-mong-đợi − thời-lượng-câu| + phạt bỏ/gộp.
    static func assign1to1(phrases: [(sF: Int, eF: Int)], uWords: [[String]], spf: Double)
        -> [(u: Int, sF: Int, eF: Int, score: Double)] {
        let U = uWords.count, P = phrases.count
        guard U > 0, P > 0 else { return [] }
        func chars(_ u: Int) -> Double { Double(max(1, uWords[u].reduce(0) { $0 + $1.count })) }
        let totalChars = (0..<U).reduce(0.0) { $0 + chars($1) }
        let totalDur = phrases.reduce(0.0) { $0 + Double($1.eF - $1.sF) }
        let secPerChar = totalChars > 0 ? totalDur / totalChars : 1
        func expLen(_ u: Int) -> Double { chars(u) * secPerChar }
        func pdur(_ j: Int) -> Double { Double(phrases[j].eF - phrases[j].sF) }
        let BIG = 1e12
        var dp = [[Double]](repeating: [Double](repeating: BIG, count: P + 1), count: U + 1)
        var bk = [[Int]](repeating: [Int](repeating: 0, count: P + 1), count: U + 1)  // 1=match 2=bỏcâu 3=gộpdòng
        dp[0][0] = 0
        for j in 1...P { dp[0][j] = dp[0][j - 1] + pdur(j - 1) * 0.6; bk[0][j] = 2 }
        for i in 1...U {
            for j in 1...P {
                var best = BIG, who = 0
                let cM = dp[i - 1][j - 1] + abs(expLen(i - 1) - pdur(j - 1))
                if cM < best { best = cM; who = 1 }
                if j - 1 >= i {
                    let cS = dp[i][j - 1] + pdur(j - 1) * 0.6 + 0.5
                    if cS < best { best = cS; who = 2 }
                }
                if i - 1 >= j {
                    let cG = dp[i - 1][j] + expLen(i - 1) * 0.5 + 0.4
                    if cG < best { best = cG; who = 3 }
                }
                dp[i][j] = best; bk[i][j] = who
            }
        }
        var i = U, j = P
        var perLine = [Int](repeating: -1, count: U)
        while i > 0, j > 0 {
            switch bk[i][j] {
            case 1: perLine[i - 1] = j - 1; i -= 1; j -= 1
            case 2: j -= 1
            case 3: perLine[i - 1] = j - 1; i -= 1
            default: i -= 1; j -= 1
            }
        }
        while i > 0 { perLine[i - 1] = max(0, j - 1); i -= 1 }
        var out: [(u: Int, sF: Int, eF: Int, score: Double)] = []
        var k = 0
        while k < U {
            let pj = perLine[k]
            guard pj >= 0, pj < P else { k += 1; continue }
            var g = k
            while g + 1 < U, perLine[g + 1] == pj { g += 1 }
            let s0 = Double(phrases[pj].sF), s1 = Double(phrases[pj].eF)
            let sumC = (k...g).reduce(0.0) { $0 + chars($1) }
            var acc = 0.0
            for u in k...g {
                let a = s0 + (s1 - s0) * acc / sumC
                acc += chars(u)
                let b = s0 + (s1 - s0) * acc / sumC
                out.append((u, Int(a), max(Int(a) + 1, Int(b)), 0.5))
            }
            k = g + 1
        }
        return out.sorted { $0.sF < $1.sF }
    }

    /// Điền thời gian cho dòng skeleton chưa được hát (nội suy tuyến tính giữa 2 dòng có giờ).
    private static func fillSkeleton(_ sk: inout [(words: [AlignResponse.Word], timed: Bool)],
                                     uWords: [[String]], songEnd: Double) {
        let n = sk.count
        var i = 0
        while i < n {
            if sk[i].timed { i += 1; continue }
            var a = i - 1; while a >= 0 && !sk[a].timed { a -= 1 }
            var b = i;     while b < n  && !sk[b].timed { b += 1 }
            let s0 = a >= 0 ? (sk[a].words.last?.end ?? 0) : 0
            let s1 = b < n  ? (sk[b].words.first?.start ?? songEnd) : max(songEnd, s0 + 1)
            let cnt = b - i
            let step = max(0.4, (s1 - s0) / Double(cnt + 1))
            for m in 0..<cnt {
                let st = s0 + step * Double(m + 1)
                sk[i + m].words = spreadWords(uWords[i + m], start: st, end: st + step * 0.85)
                sk[i + m].timed = true
            }
            i = b
        }
    }

    /// Rải đều chữ trong một khoảng (dùng khi không có mốc canh thật).
    private static func spreadWords(_ words: [String], start: Double, end: Double) -> [AlignResponse.Word] {
        guard !words.isEmpty else { return [] }
        let span = max(0.2, end - start)
        let step = span / Double(words.count)
        return words.enumerated().map { i, wd in
            AlignResponse.Word(text: wd,
                               start: ((start + step * Double(i)) * 1000).rounded() / 1000,
                               end: ((start + step * Double(i + 1)) * 1000).rounded() / 1000,
                               score: 0)
        }
    }

    /// `<star> w0chars <star> w1chars <star> …` — star (id 31) = "đậu tự do", nuốt khoảng lặng.
    private static func starFlat(_ words: [String]) -> (flat: [Int], ranges: [(Int, Int)]) {
        var flat: [Int] = []
        var ranges: [(Int, Int)] = []
        for w in words {
            flat.append(starID)
            let ids = normWord(w)
            let s = flat.count
            flat.append(contentsOf: ids.isEmpty ? [unkID] : ids)
            ranges.append((s, flat.count))
        }
        flat.append(starID)
        return (flat, ranges)
    }

    /// `w0chars w1chars …` — KHÔNG có <star>. Mọi ký tự phải khớp khung thật →
    /// điểm phân biệt được lời ĐÚNG với lời SAI cho một mẩu audio ngắn.
    private static func plainFlat(_ words: [String]) -> (flat: [Int], ranges: [(Int, Int)]) {
        var flat: [Int] = []
        var ranges: [(Int, Int)] = []
        for w in words {
            let ids = normWord(w)
            let s = flat.count
            flat.append(contentsOf: ids.isEmpty ? [unkID] : ids)
            ranges.append((s, flat.count))
        }
        return (flat, ranges)
    }

    private static func wordsFrom(spans: [Span], ranges: [(Int, Int)], words: [String],
                                  frameOffset: Int, secPerFrame: Double) -> [AlignResponse.Word] {
        var out: [AlignResponse.Word] = []
        for (k, (rs, re)) in ranges.enumerated() where re > rs && re <= spans.count {
            let g = spans[rs..<re]
            guard let f0 = g.first, let f1 = g.last else { continue }
            let sc = g.map(\.score).reduce(0, +) / Double(max(1, g.count))
            let st = Double(frameOffset + f0.start) * secPerFrame
            let en = Double(frameOffset + max(f1.end, f0.start + 1)) * secPerFrame
            out.append(AlignResponse.Word(text: words[k],
                                          start: (st * 1000).rounded() / 1000,
                                          end: (en * 1000).rounded() / 1000,
                                          score: (sc * 1000).rounded() / 1000))
        }
        return out
    }

    private static func splitWords(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    // MARK: - CTC forced alignment (Viterbi trên chuỗi mở rộng blank)

    private struct Span { let start: Int; let end: Int; let score: Double }

    /// `emission`: [T][31] log-prob. `<star>` (id 31) coi như logp 0 ở mọi khung.
    /// Trả 1 span / target token, ĐÚNG thứ tự.
    private static func forcedAlign(emission: [[Float]], targets: [Int]) -> [Span] {
        let T = emission.count
        let L = targets.count
        // chuỗi mở rộng: blank, t0, blank, t1, blank, ...
        var ext = [Int](); ext.reserveCapacity(2 * L + 1)
        ext.append(blankID)
        for t in targets { ext.append(t); ext.append(blankID) }
        let S = ext.count

        @inline(__always) func emit(_ t: Int, _ tok: Int) -> Float {
            tok == starID ? 0 : emission[t][tok]
        }

        let neg: Float = -1e30
        var prev = [Float](repeating: neg, count: S)
        var curr = [Float](repeating: neg, count: S)
        var back = [Int16](repeating: 0, count: T * S)

        prev[0] = emit(0, ext[0])
        if S > 1 { prev[1] = emit(0, ext[1]) }

        for t in 1..<T {
            let rowOff = t * S
            for s in 0..<S {
                var bestV = prev[s]
                var bestS = s
                if s >= 1, prev[s - 1] > bestV { bestV = prev[s - 1]; bestS = s - 1 }
                if s >= 2, ext[s] != blankID, ext[s] != ext[s - 2], prev[s - 2] > bestV {
                    bestV = prev[s - 2]; bestS = s - 2
                }
                curr[s] = bestV + emit(t, ext[s])
                back[rowOff + s] = Int16(bestS)
            }
            swap(&prev, &curr)
            for i in 0..<S { curr[i] = neg }
        }

        // backtrack từ S-1 hoặc S-2
        var s = (S >= 2 && prev[S - 2] > prev[S - 1]) ? S - 2 : S - 1
        var pathTok = [Int](repeating: blankID, count: T)
        for t in stride(from: T - 1, through: 0, by: -1) {
            pathTok[t] = ext[s]
            if t > 0 { s = Int(back[t * S + s]) }
        }

        // merge_tokens: mỗi chuỗi non-blank liên tiếp = 1 span, khớp 1-1 với `targets`
        var spans = [Span](); spans.reserveCapacity(L)
        var t = 0
        var ti = 0
        while t < T && ti < L {
            // bỏ blank
            while t < T && pathTok[t] == blankID { t += 1 }
            guard t < T else { break }
            let tok = pathTok[t]
            let start = t
            var acc: Double = 0; var cnt = 0
            while t < T && pathTok[t] == tok {
                acc += Double(exp(emit(t, tok))); cnt += 1; t += 1
            }
            spans.append(Span(start: start, end: t, score: cnt > 0 ? acc / Double(cnt) : 0))
            ti += 1
        }
        // nếu thiếu (hiếm) → nhồi span rỗng cuối
        while spans.count < L {
            let last = spans.last?.end ?? 0
            spans.append(Span(start: last, end: last, score: 0))
        }
        return spans
    }

    // MARK: - Tiện ích

    private static func normWord(_ w: String) -> [Int] {
        var s = w.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
        s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US")).lowercased()
        return s.compactMap { vocab[$0] }
    }

    private static func logSoftmax(_ row: inout [Float]) {
        var m: Float = -.greatestFiniteMagnitude
        for v in row where v > m { m = v }
        var sum: Float = 0
        for v in row { sum += exp(v - m) }
        let logSum = m + log(sum)
        for i in row.indices { row[i] -= logSum }
    }

    private static func runModel(_ sess: OpaquePointer, _ chunk: [Float]) throws -> ([Float], Int) {
        let shape: [Int] = [1, chunk.count]
        var outShape = [Int](repeating: 0, count: 8)
        var outLen = 0
        var outRank: Int32 = 0
        let cap = (chunk.count / 300 + 128) * vocabSize
        var out = [Float](repeating: 0, count: cap)
        let rc: Int32 = chunk.withUnsafeBufferPointer { ib in
            shape.withUnsafeBufferPointer { sh in
                out.withUnsafeMutableBufferPointer { ob in
                    outShape.withUnsafeMutableBufferPointer { os in
                        mdx_run(sess, ib.baseAddress, ib.count, sh.baseAddress, 2,
                                ob.baseAddress, ob.count, &outLen, os.baseAddress, &outRank)
                    }
                }
            }
        }
        guard rc == 0 else { throw LocalAlignerError.runFailed(rc) }
        let frames = outRank >= 2 ? outShape[1] : (outLen / vocabSize)
        return (Array(out[0..<max(0, outLen)]), frames)
    }

    private static func read16kMono(_ url: URL) throws -> [Float] {
        guard let f = try? AVAudioFile(forReading: url) else { throw LocalAlignerError.cannotOpen }
        let inFmt = f.processingFormat
        guard inFmt.sampleRate > 0,
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sr),
                                         channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw LocalAlignerError.cannotOpen }
        let inChunk: AVAudioFrameCount = 65_536
        let outCap = AVAudioFrameCount((Double(inChunk) * Double(sr) / inFmt.sampleRate).rounded(.up)) + 8_192
        guard let ib = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inChunk),
              let ob = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
            throw LocalAlignerError.cannotOpen
        }
        var out = [Float]()
        out.reserveCapacity(Int(Double(f.length) * Double(sr) / inFmt.sampleRate) + sr)
        while true {
            ib.frameLength = 0
            do { try f.read(into: ib, frameCount: inChunk) } catch { throw LocalAlignerError.cannotOpen }
            if ib.frameLength == 0 { break }
            ob.frameLength = 0
            var fed = false
            var e: NSError?
            _ = conv.convert(to: ob, error: &e) { _, s in
                if fed { s.pointee = .noDataNow; return nil }
                fed = true; s.pointee = .haveData; return ib
            }
            if e != nil { throw LocalAlignerError.cannotOpen }
            let m = Int(ob.frameLength)
            if m > 0, let ch = ob.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: m))
            }
            if ib.frameLength < inChunk { break }
        }
        return out
    }
}
