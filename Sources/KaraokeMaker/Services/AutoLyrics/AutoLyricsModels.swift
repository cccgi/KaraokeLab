import Foundation

// "Tự động lấy lời" (Local Auto Lyrics) — mô hình dữ liệu KẾT QUẢ nhận dạng.
//
// Tách hẳn khỏi lời của project (`KaraokeProject.rawLyrics/lines`): đây chỉ là BẢN NHÁP tạm thời,
// sống trong bộ nhớ tới khi user bấm "Dùng lời này". Không lưu xuống đĩa, không đổi file project.
// Chỉ có VĂN BẢN — mốc giờ do bộ canh giờ sẵn có của app lo, Qwen KHÔNG điều khiển timing.

enum LyricConfidence: String, Codable, Equatable {
    case confident
    case uncertain
}

/// 1 từ của bản nháp. `uncertain` = chưa đủ bằng chứng → giữ giả thuyết gốc tốt nhất, KHÔNG tự thay
/// bằng từ "nghe hợp lý hơn"; `alternatives` = các phương án còn lại (vd "vang" → ["vãng", "vẫn"]).
struct GeneratedLyricWord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, Equatable {
        case word
        /// Từ mà chỉ mô hình kiểm tra nghe thấy (mô hình chính bỏ sót) — giữ lại như ứng viên chưa chắc.
        case possibleMissing = "possible_missing"
    }

    var id = UUID()
    let text: String
    let confidence: LyricConfidence
    let alternatives: [String]
    let kind: Kind

    var isUncertain: Bool { confidence == .uncertain }

    enum CodingKeys: String, CodingKey { case text, confidence, alternatives, kind }

    init(text: String, confidence: LyricConfidence, alternatives: [String] = [], kind: Kind = .word) {
        self.text = text; self.confidence = confidence; self.alternatives = alternatives; self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        confidence = (try? c.decode(LyricConfidence.self, forKey: .confidence)) ?? .uncertain   // lạ → coi như chưa chắc (an toàn)
        alternatives = (try? c.decode([String].self, forKey: .alternatives)) ?? []
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .word
    }
}

struct GeneratedLyricLine: Codable, Identifiable, Equatable {
    var id = UUID()
    let words: [GeneratedLyricWord]
    /// Có dòng trống (ngắt đoạn) TRƯỚC dòng này.
    let sectionBreakBefore: Bool
    /// Vị trí ƯỚC LƯỢNG (giây) chỉ để hiển thị/ngắt dòng — KHÔNG dùng làm timing.
    let approxStart: Double

    enum CodingKeys: String, CodingKey { case words, sectionBreakBefore, approxStart }

    init(words: [GeneratedLyricWord], sectionBreakBefore: Bool = false, approxStart: Double = 0) {
        self.words = words; self.sectionBreakBefore = sectionBreakBefore; self.approxStart = approxStart
    }

    var text: String { words.map(\.text).joined(separator: " ") }
}

/// Đoạn ngân nga / âm không lời (Hmm, Ah, Ơ, La…) — LƯU RIÊNG, không tự chèn vào lời.
struct NonLexicalVocal: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// Đoạn mặt nạ giọng hát chưa chắc + 2 mô hình không xác nhận được cùng nội dung → KHÔNG đưa vào lời.
struct UnconfirmedVocalChunk: Codable, Equatable {
    let start: Double
    let end: Double
    let text06: String?
    let text17: String?
}

struct GeneratedLyricsResult: Codable, Equatable {
    struct Backend: Codable, Equatable {
        let device: String?
        let dtype: String?
        let engine: String?
    }
    struct Stats: Codable, Equatable {
        let windows: Int
        let vocalWindows: Int
        let instrumentalWindows: Int
        let verifiedWindows: Int
        let contextWindows: Int
        let words: Int
        let uncertainWords: Int
    }

    let schema: Int
    let audioSeconds: Double
    let backend: Backend?
    let lines: [GeneratedLyricLine]
    let nonLexicalVocal: [NonLexicalVocal]
    let unconfirmedVocalChunks: [UnconfirmedVocalChunk]
    let stats: Stats?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case schema, audioSeconds, backend, lines, nonLexicalVocal, unconfirmedVocalChunks, stats, warnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        audioSeconds = (try? c.decode(Double.self, forKey: .audioSeconds)) ?? 0
        backend = try? c.decode(Backend.self, forKey: .backend)
        lines = try c.decode([GeneratedLyricLine].self, forKey: .lines)
        nonLexicalVocal = (try? c.decode([NonLexicalVocal].self, forKey: .nonLexicalVocal)) ?? []
        unconfirmedVocalChunks = (try? c.decode([UnconfirmedVocalChunk].self, forKey: .unconfirmedVocalChunks)) ?? []
        stats = try? c.decode(Stats.self, forKey: .stats)
        warnings = (try? c.decode([String].self, forKey: .warnings)) ?? []
    }

    init(lines: [GeneratedLyricLine], nonLexicalVocal: [NonLexicalVocal] = [], unconfirmedVocalChunks: [UnconfirmedVocalChunk] = [],
         warnings: [String] = [], audioSeconds: Double = 0) {
        self.schema = 1; self.audioSeconds = audioSeconds; self.backend = nil; self.lines = lines
        self.nonLexicalVocal = nonLexicalVocal; self.unconfirmedVocalChunks = unconfirmedVocalChunks
        self.stats = nil; self.warnings = warnings
    }

    /// Văn bản sẽ đưa vào ô lời khi user bấm "Dùng lời này": mỗi dòng 1 câu, dòng trống giữa các đoạn.
    /// Từ chưa chắc được giữ NGUYÊN (giả thuyết gốc) — dấu "?" chỉ có ở màn xem trước, không nằm trong văn bản.
    var plainText: String {
        var out: [String] = []
        for (i, l) in lines.enumerated() {
            if i > 0 && l.sectionBreakBefore { out.append("") }
            out.append(l.text)
        }
        return out.joined(separator: "\n")
    }

    struct UncertainWord: Identifiable, Equatable {
        var id: UUID { word.id }
        let line: Int
        let word: GeneratedLyricWord
    }

    var uncertainWords: [UncertainWord] {
        lines.enumerated().flatMap { i, l in l.words.filter(\.isUncertain).map { UncertainWord(line: i, word: $0) } }
    }

    var isEmpty: Bool { lines.allSatisfy { $0.words.isEmpty } }

    static func decode(from data: Data) throws -> GeneratedLyricsResult {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(GeneratedLyricsResult.self, from: data)
    }
}

/// Tiến độ THẬT (đếm đoạn), không suy từ thời gian trôi qua.
enum AutoLyricsProgress: Equatable {
    case preparing
    case loadingModel
    case recognizing(done: Int, total: Int)
    case verifying(done: Int, total: Int)
    case checking
    case rechecking(done: Int, total: Int)
    case finishing

    /// 0…1 cho thanh tiến độ của CHẶNG hiện tại; `nil` = chưa biết (quay vòng).
    var fraction: Double? {
        switch self {
        case .recognizing(let d, let t), .verifying(let d, let t), .rechecking(let d, let t):
            return t > 0 ? Double(d) / Double(t) : nil
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .preparing: return L("Đang chuẩn bị…")
        case .loadingModel: return L("Đang nạp bộ nhận dạng…")
        case .recognizing(let d, let t): return String(format: L("Đang nhận dạng lời… %d / %d"), d, t)
        case .verifying(let d, let t): return String(format: L("Đang kiểm tra lời… %d / %d"), d, t)
        case .checking: return L("Đang kiểm tra lời…")
        case .rechecking(let d, let t): return String(format: L("Đang kiểm tra lại đoạn chưa chắc… %d / %d"), d, t)
        case .finishing: return L("Đang hoàn thiện…")
        }
    }
}

enum AutoLyricsError: LocalizedError, Equatable {
    case noAudio
    case needsVocalStem
    case runtimeMissing(String)
    case modelMissing(String)
    case backendUnavailable(String)
    case audioPrepFailed(String)
    case helperFailed(String)
    case badResult(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: return L("Chưa có file nhạc trong project.")
        case .needsVocalStem: return L("Chưa có bản tách giọng hát của bài này.")
        case .runtimeMissing(let d): return L("Chưa tìm thấy bộ nhận dạng lời trên máy này.") + " " + d
        case .modelMissing(let d): return L("Thiếu mô hình nhận dạng lời.") + " " + d
        case .backendUnavailable(let d): return L("Bộ xử lý của máy không dùng được cho việc này.") + " " + d
        case .audioPrepFailed(let d): return L("Không đọc được file nhạc.") + " " + d
        case .helperFailed(let d): return L("Nhận dạng lời gặp lỗi.") + " " + d
        case .badResult(let d): return L("Kết quả nhận dạng không hợp lệ.") + " " + d
        }
    }
}

/// Ghi nhật ký chẩn đoán kỹ thuật cho "Tự động tạo Karaoke" (mặc định TẮT, không hiện ở UI thường).
enum AutoLyricsFeature {
    static var diagnosticsEnabled: Bool {
        #if DEBUG || KM_DEV_RUNTIME || KM_GUITEST
        return ProcessInfo.processInfo.environment["KM_AUTOLYRICS_DIAG"] == "1"
            || UserDefaults.standard.bool(forKey: "LocalAutoLyricsDiagnostics")
        #else
        return false                     // bản phát hành: không ghi bất kỳ nhật ký nội dung lời nào
        #endif
    }
}
