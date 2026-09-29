import Foundation

/// K1 — canh lời CHÍNH XÁC bằng forced alignment (thay cho "Whisper nghe rồi ghép").
///
/// Luồng: gửi (audio + lời người dùng) lên Colab `/align` → máy tách giọng, ép TỪNG CHỮ
/// khớp vào tiếng hát, trả mốc theo đúng từng dòng người dùng nhập.
/// Kết quả đi THẲNG vào timeline — KHÔNG qua `WhisperToLines` / `LyricAligner` /
/// `LyricCorrector` / `TimingRefiner` (chuỗi cũ hay đẻ ra dòng thiếu + dồn chữ).
@MainActor
final class ForcedAligner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var progress: Double = 0

    struct Outcome {
        var lines: [LyricLine]
        var weakLines: Int
    }

    /// Canh mốc TRONG MÁY (offline). `vocalURL` = bản giọng đã tách. `lyrics` = lời ĐẦY ĐỦ.
    func run(vocalURL: URL, lyrics: String, preroll: Double = 2.0) async -> Outcome? {
        guard !isRunning else { return nil }
        guard LocalAligner.modelURL != nil else {
            status = "❌ Không canh giờ được."
            return nil
        }
        isRunning = true
        progress = 0
        status = "Đang canh giờ lời…"
        defer { isRunning = false }

        do {
            let aligned = try await Task.detached(priority: .userInitiated) {
                try LocalAligner.align(vocalURL: vocalURL, lyrics: lyrics) { p in
                    Task { @MainActor [weak self] in self?.progress = p }
                }
            }.value
            let (lines, weak) = Self.buildLines(from: aligned, preroll: preroll)
            let inCount = lyrics.split(whereSeparator: \.isNewline).filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }.count
            let miss = inCount - lines.count
            let missNote = miss > 0 ? " · thiếu \(miss) dòng" : ""
            let warn = weak > 0 ? " · \(weak) dòng nên nghe lại" : ""
            status = "✅ \(lines.count) dòng\(missNote)\(warn)"
            return Outcome(lines: lines, weakLines: weak)
        } catch {
            status = "❌ \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Dựng [LyricLine] (làm sạch NHẸ, không bóp nhịp)

    /// Trả (lines, số dòng khớp yếu).
    nonisolated static func buildLines(from aligned: [AlignResponse.Line], preroll: Double) -> ([LyricLine], Int) {
        var out: [LyricLine] = []
        var weak = 0

        for al in aligned {
            let raw = al.words.filter { $0.end >= $0.start && $0.start >= 0 }
            guard let first = raw.first else { continue }
            _ = first

            var words: [LyricWord] = raw.map { LyricWord(text: $0.text, start: $0.start, end: $0.end) }
            // Ép tăng dần, không chồng nhau — chỉ chạm khi thực sự sai thứ tự.
            for i in words.indices {
                if i > 0, let pe = words[i - 1].end, let cs = words[i].start, cs < pe {
                    words[i].start = pe
                }
                if let s = words[i].start, let e = words[i].end, e < s {
                    words[i].end = s + 0.05
                }
                // Chặn "smear" còn sót: 1 chữ (không phải chữ cuối câu) không nên dài quá 2.5s.
                if i < words.count - 1, let s = words[i].start, let e = words[i].end, e - s > 2.5 {
                    words[i].end = s + 2.5
                }
            }
            guard let s = words.first?.start, let e = words.last?.end else { continue }

            let scores = raw.compactMap { $0.score }
            let lowScore = !scores.isEmpty && scores.reduce(0, +) / Double(scores.count) < 0.3
            // Câu vẫn trải quá rộng so với số chữ ⇒ nghi còn lệch, đánh dấu để nghe lại.
            if lowScore || (e - s) > Double(words.count) * 3.0 + 3.0 { weak += 1 }

            let text = al.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var line = LyricLine(
                text: text.isEmpty ? raw.map(\.text).joined(separator: " ") : text,
                start: s, end: max(e, s + 0.2), source: .auto)
            line.words = words
            out.append(line)
        }

        out.sort { ($0.start ?? 0) < ($1.start ?? 0) }

        // Lead-in nhẹ: câu hiện sớm hơn mốc hát vài giây (karaoke chờ), KHÔNG đè câu trước.
        for i in out.indices {
            let firstWord = out[i].words.first?.start ?? out[i].start ?? 0
            let prevEnd = i > 0 ? (out[i - 1].end ?? 0) : 0
            let gap = firstWord - prevEnd
            let lead = gap > preroll + 0.3 ? preroll : max(0, gap * 0.6)
            out[i].start = max(prevEnd, firstWord - lead)
            if let s = out[i].start, let e = out[i].end, e <= s { out[i].end = s + 0.3 }
        }
        return (out, weak)
    }
}
