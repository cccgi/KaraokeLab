import Foundation
import Combine

// "Tự động tạo Karaoke — Không cần lời": luồng ĐỘC LẬP từ nhạc → lời (Qwen) → canh giờ (bộ canh giờ SẴN CÓ) → karaoke.
//
// KHÔNG có bộ canh giờ mới ở đây: bước cuối gọi đúng hàm mà đường "Có lời" gọi (ContentView.runKaraokeTiming →
// AdvancedKaraoke.run). Đường "Có lời" đưa vào lời người dùng dán; đường này đưa vào lời do máy nhận dạng — cùng 1 văn bản thuần.

/// Kết quả bước canh giờ (do ContentView trả về — chính hàm dùng chung cho cả hai đường).
enum KaraokeTimingOutcome: Equatable {
    case success(lines: Int)
    case failure(String)
    /// Bị huỷ / đổi project giữa chừng → kết quả KHÔNG được áp vào project.
    case discarded
}

/// Từ máy chưa chắc, gắn với 1 dòng karaoke ĐÃ canh giờ. Chỉ trong bộ nhớ (không đổi định dạng file project).
struct AutoUncertainWord: Identifiable, Equatable {
    let id = UUID()
    let lineID: UUID
    /// Chỉ số từ (theo khoảng trắng) trong `LyricLine.text` lúc gắn.
    let wordIndex: Int
    let original: String
    let alternatives: [String]
    let kind: GeneratedLyricWord.Kind
}

enum UncertaintyMapper {
    static func norm(_ s: String) -> String {
        String(s.precomposedStringWithCanonicalMapping.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// Gắn từ chưa chắc của bản nháp vào các dòng đã canh giờ bằng LCS trên chữ đã chuẩn hoá (chịu được dòng bị đổi ngắt/nhân bản nhẹ).
    static func map(draft: GeneratedLyricsResult, lines: [LyricLine]) -> [AutoUncertainWord] {
        let stream = draft.lines.flatMap(\.words)
        guard stream.contains(where: \.isUncertain) else { return [] }
        var flat: [(line: Int, idx: Int, key: String)] = []
        for (li, l) in lines.enumerated() {
            for (wi, t) in tokens(l.text).enumerated() { flat.append((li, wi, norm(t))) }
        }
        let a = stream.map { norm($0.text) }, b = flat.map(\.key)
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [AutoUncertainWord] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                let w = stream[i]
                if w.isUncertain {
                    out.append(AutoUncertainWord(lineID: lines[flat[j].line].id, wordIndex: flat[j].idx, original: w.text,
                                                 alternatives: w.alternatives, kind: w.kind))
                }
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }

    /// Thay từ thứ `index` của `text` bằng `new` (các từ khác giữ nguyên). nil nếu không hợp lệ.
    static func replacingWord(in text: String, at index: Int, with new: String) -> String? {
        var t = tokens(text)
        guard t.indices.contains(index), !new.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        t[index] = new
        return t.joined(separator: " ")
    }
}

/// Các "móc" ContentView cung cấp cho luồng (ContentView là struct nên dùng closure thay vì protocol lớp).
struct AutoKaraokeHooks {
    var projectSession: @MainActor () -> UUID
    var sourceAudio: @MainActor () -> URL?
    var vocalStem: @MainActor () -> URL?
    /// Bước "phân tích nhạc" SẴN CÓ (tách giọng). Trả URL bản giọng hát, nil nếu lỗi.
    var analyzeMusic: @MainActor () async -> URL?
    /// Bước canh giờ SẴN CÓ — CÙNG hàm với đường "Có lời". `shouldApply` = false → không áp kết quả.
    var createKaraoke: @MainActor (_ lyrics: String, _ shouldApply: @escaping @MainActor () -> Bool) async -> KaraokeTimingOutcome
    var currentLines: @MainActor () -> [LyricLine]
    var karaokeCreated: @MainActor ([AutoUncertainWord]) -> Void
}

@MainActor
final class AutoKaraokeFlow: ObservableObject {

    enum Phase: Equatable {
        case idle
        case analyzing                          // phân tích bài hát (tách giọng — bước sẵn có)
        case recognizing(AutoLyricsProgress)    // nhận dạng + kiểm tra lời (helper Qwen)
        case timing                             // tự động canh giờ (bộ canh giờ sẵn có)
        case done(lines: Int, uncertain: Int)
        case failedAnalysis(String)
        case failedRecognition(String)
        case failedTiming(String)               // lời vừa nhận dạng được GIỮ để thử lại canh giờ / chuyển sang nhập tay
    }

    @Published private(set) var phase: Phase = .idle { didSet { AutoLyricsDebug.flowPhase = "\(phase)" } }
    /// Lời máy nhận dạng (văn bản thuần đúng như đưa cho bộ canh giờ). Giữ lại tới khi xong / huỷ / đổi project.
    @Published private(set) var draftText: String?
    @Published private(set) var draft: GeneratedLyricsResult?

    var hooks: AutoKaraokeHooks?
    private let asr: AutoLyricsController
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var owner: UUID?
    /// (2026-09-29) `asr.$phase` phát `.running(progress)` NHIỀU LẦN/GIÂY lúc helper đang chạy — y hệt lý do
    /// `BeatSepProxy`/`AdvancedKaraokeProxy` throttle tiến độ (xem comment ở `ContentView.swift`), nhưng
    /// `AutoKaraokeFlow` lại được `ContentView` giữ TRỰC TIẾP qua `@StateObject` (không qua proxy) → mỗi lần
    /// `phase` đổi, dù chỉ % nhỏ, kéo `ContentView.body` (3 cột + timeline) dựng lại → CPU cao liên tục lúc
    /// "Đang nhận dạng lời…". Throttle riêng nhánh `.recognizing` xuống tối đa vài lần/giây, KHÔNG đụng tốc độ/
    /// logic ASR thật — chặng đầu tiên luôn hiện ngay (mốc `.distantPast`).
    private var lastRecognizingPublish = Date.distantPast

    // See the matching comment on AutoLyricsController.init — `gate` defaults to nil here too, for
    // the same reason (avoids a Swift 6 false positive on a MainActor-isolated default argument).
    init(service: LyricTranscriptionService = QwenHelperTranscriptionService(), gate: AutoLyricsJobGate? = nil) {
        asr = AutoLyricsController(service: service, gate: gate)
    }

    var isRunning: Bool {
        switch phase { case .analyzing, .recognizing, .timing: return true; default: return false }
    }

    var isFailed: Bool {
        switch phase { case .failedAnalysis, .failedRecognition, .failedTiming: return true; default: return false }
    }

    // MARK: - Điều khiển

    /// Toàn bộ luồng: (phân tích nhạc nếu cần) → nhận dạng lời → canh giờ. Bấm lần 2 khi đang chạy → bỏ qua (chỉ 1 lượt).
    func start() {
        guard !isRunning, let hooks else { return }
        asr.discard()
        draft = nil; draftText = nil
        lastRecognizingPublish = .distantPast
        token = UUID(); owner = hooks.projectSession()
        let t = token
        task = Task { [weak self] in await self?.runAll(token: t) }
    }

    /// Thử lại RIÊNG bước canh giờ với lời đã nhận dạng (không chạy lại ASR).
    func retryTiming() {
        guard !isRunning, case .failedTiming = phase, draftText != nil, let hooks else { return }
        token = UUID(); owner = hooks.projectSession()
        let t = token
        task = Task { [weak self] in await self?.runTiming(token: t) }
    }

    /// Huỷ: dừng helper, bỏ kết quả về muộn, KHÔNG áp gì vào project. Bước phân tích nhạc / canh giờ sẵn có không dừng giữa chừng được —
    /// chúng tự kết thúc ngầm nhưng kết quả bị bỏ.
    func cancel() {
        token = UUID()
        asr.cancel()
        task?.cancel(); task = nil
        draft = nil; draftText = nil
        phase = .idle
    }

    /// Về trạng thái ban đầu (giữ nguyên nếu đang chạy).
    func reset() {
        guard !isRunning else { return }
        asr.discard()
        draft = nil; draftText = nil; phase = .idle
    }

    // MARK: - Các chặng

    private func alive(_ t: UUID) -> Bool { t == token && hooks?.projectSession() == owner }

    private func finishCancelledIfNeeded(_ t: UUID) -> Bool {
        guard !alive(t) else { return false }
        if t == token { cancel() }          // đổi project (token còn nguyên) → dọn hẳn
        return true
    }

    private func runAll(token t: UUID) async {
        guard let hooks, let owner else { return }
        guard let audio = hooks.sourceAudio() else { phase = .failedAnalysis(AutoLyricsError.noAudio.localizedDescription); return }

        // 1) Phân tích nhạc (tách giọng — bước sẵn có), chỉ khi chưa có bản giọng hát.
        var vocal = hooks.vocalStem()
        if vocal == nil {
            phase = .analyzing
            vocal = await hooks.analyzeMusic()
            if finishCancelledIfNeeded(t) { return }
            guard vocal != nil else { phase = .failedAnalysis(L("Không phân tích được bài hát.")); return }
        }

        // 2) Nhận dạng + kiểm tra lời (helper Qwen) — dùng lại nguyên bộ điều khiển đã kiểm chứng (owner / cổng 1 lượt / huỷ).
        phase = .recognizing(.preparing)
        asr.start(audioURL: audio, vocalStemURL: vocal, owner: owner)
        var result: GeneratedLyricsResult?
        var failure: String?
        var everRunning = false
        loop: for await ph in asr.$phase.values {
            if !alive(t) { break loop }
            switch ph {
            case .running(let p):
                everRunning = true
                let now = Date()
                guard now.timeIntervalSince(lastRecognizingPublish) >= 0.3 else { break }
                lastRecognizingPublish = now
                phase = .recognizing(p)
            case .review: result = asr.draft; break loop
            case .failed(let m): failure = m; break loop
            case .needsVocalStem: failure = AutoLyricsError.needsVocalStem.localizedDescription; break loop
            case .idle: if everRunning { break loop }
            }
        }
        if finishCancelledIfNeeded(t) { return }
        _ = asr.takeDraftForImport(owner: owner)            // đóng vòng đời bản nháp của bộ điều khiển
        guard let result else {
            phase = .failedRecognition(failure ?? L("Không nhận dạng được lời."))
            return
        }
        draft = result; draftText = result.plainText

        // 3) Canh giờ — CÙNG bộ canh giờ với đường "Có lời".
        await runTiming(token: t)
    }

    private func runTiming(token t: UUID) async {
        guard let hooks, let text = draftText else { return }
        phase = .timing
        let outcome = await hooks.createKaraoke(text, { [weak self] in self?.alive(t) ?? false })
        guard t == token else { return }                     // đã huỷ trong lúc canh giờ
        switch outcome {
        case .success(let n):
            let unc = draft.map { UncertaintyMapper.map(draft: $0, lines: hooks.currentLines()) } ?? []
            hooks.karaokeCreated(unc)
            phase = .done(lines: n, uncertain: unc.count)
        case .failure(let m):
            phase = .failedTiming(m)                         // GIỮ lời để thử lại canh giờ, không chạy lại ASR
        case .discarded:
            cancel()
        }
    }
}
