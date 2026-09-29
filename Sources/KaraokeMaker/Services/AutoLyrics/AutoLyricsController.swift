import Foundation

/// Cổng MỘT LƯỢT DUY NHẤT: cả app chỉ được có 1 lượt "Tự động lấy lời" chạy cùng lúc (mỗi lượt = 1 tiến trình Python + mô hình
/// chiếm vài GB). Lượt mới phải chờ lượt cũ (đang dừng dở) kết thúc hẳn.
@MainActor
final class AutoLyricsJobGate {
    static let shared = AutoLyricsJobGate()
    private var holder: UUID?
    var isBusy: Bool { holder != nil }
    func acquire(_ token: UUID) -> Bool { if holder == nil { holder = token; return true }; return false }
    func release(_ token: UUID) { if holder == token { holder = nil } }
}

/// Trạng thái để bộ kiểm thử GUI (`KM_GUITEST_DIR`) đọc — không dùng cho logic.
@MainActor
enum AutoLyricsDebug {
    static var phase = "idle"
    static var flowPhase = "idle"
    static var jobOwner = "-"
    static var draftWords = 0
    /// Nhật ký MỌI lần gọi hàm canh giờ chung (origin, số dòng, dấu vân tay văn bản) — để chứng minh 2 đường dùng cùng 1 hàm.
    static var timingCalls: [String] = []
    static func recordTiming(origin: String, lyrics: String) {
        var h: UInt64 = 1469598103934665603
        for b in lyrics.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        timingCalls.append("\(origin) lines=\(lyrics.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count) hash=\(String(h, radix: 16))")
    }
    static var failNextTiming = false          // chỉ dùng bởi bản dựng kiểm thử GUI
    static var lastAudio = "-"
    static var lastVocal = "-"
    static var gateBusy: Bool { AutoLyricsJobGate.shared.isBusy }
}

/// Điều phối luồng "Tự động lấy lời": chạy nền → tiến độ THẬT → bản nháp để user xem → chỉ khi user xác nhận mới giao văn bản ra.
///
/// BẤT BIẾN AN TOÀN (có test trong `--autolyrics-test selftest` và test GUI thật):
///  • Controller KHÔNG giữ tham chiếu tới project/store/lời hiện có → không thể ghi đè gì.
///  • Văn bản chỉ ra khỏi controller qua `takeDraftForImport(owner:)` — hàm duy nhất, chỉ chạy khi đang ở bước xem lại
///    (`.review`) VÀ đúng project đã bắt đầu lượt này (`owner`). Project khác → bản nháp bị vứt, không giao gì.
///  • Huỷ / đóng / lỗi / đổi project / rời tab → bản nháp bị vứt, helper bị dừng, project không hề bị chạm tới.
///  • Tối đa 1 lượt chạy toàn app (`AutoLyricsJobGate`).
@MainActor
final class AutoLyricsController: ObservableObject {

    enum Phase: Equatable {
        case idle
        case needsVocalStem                     // thiếu bản tách giọng hát — chưa chạy gì cả
        case running(AutoLyricsProgress)
        case review                             // bản nháp sẵn sàng, chờ user xác nhận
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle { didSet { AutoLyricsDebug.phase = "\(phase)" } }
    @Published private(set) var draft: GeneratedLyricsResult? { didSet { AutoLyricsDebug.draftWords = draft?.lines.reduce(0) { $0 + $1.words.count } ?? 0 } }

    private let service: LyricTranscriptionService
    private let gate: AutoLyricsJobGate
    private var task: Task<Void, Never>?
    private var runToken = UUID()
    /// Phiên project (ProjectStore.projectSessionID) đã bắt đầu lượt hiện tại.
    private(set) var jobOwner: UUID? { didSet { AutoLyricsDebug.jobOwner = jobOwner?.uuidString.prefix(8).description ?? "-" } }

    // `gate` defaults to nil (resolved to `.shared` in the body) rather than `= .shared` directly:
    // a default-argument expression referencing a MainActor-isolated static is evaluated in the
    // caller's inferred context, which Swift 6 flags even though this whole class is @MainActor —
    // resolving it inside the (actor-isolated) init body sidesteps that false positive.
    init(service: LyricTranscriptionService = QwenHelperTranscriptionService(), gate: AutoLyricsJobGate? = nil) {
        self.service = service; self.gate = gate ?? .shared
    }

    deinit {                                    // ContentView bị huỷ (đổi tab…) → không để helper mồ côi
        service.cancel()
    }

    var isRunning: Bool { if case .running = phase { return true }; return false }

    func start(audioURL: URL?, vocalStemURL: URL?, owner: UUID) {
        guard !isRunning else { return }        // bấm 2 lần → bỏ qua an toàn
        draft = nil
        jobOwner = owner
        guard let audioURL else { phase = .failed(AutoLyricsError.noAudio.localizedDescription); return }
        guard let vocalStemURL, FileManager.default.fileExists(atPath: vocalStemURL.path) else { phase = .needsVocalStem; return }
        let token = UUID(); runToken = token
        AutoLyricsDebug.lastAudio = audioURL.path; AutoLyricsDebug.lastVocal = vocalStemURL.path
        phase = .running(.preparing)
        let svc = service, gate = self.gate
        let applyOnMain: @MainActor @Sendable (AutoLyricsProgress) -> Void = { [weak self] ev in self?.apply(progress: ev, token: token) }
        let report: @Sendable (AutoLyricsProgress) -> Void = { ev in Task { @MainActor in applyOnMain(ev) } }
        task = Task { [weak self] in
            // Chờ tới lượt: lượt trước (vừa Hủy) có thể còn đang tắt helper.
            var acquired = false
            for _ in 0..<200 {
                if Task.isCancelled { break }
                if await MainActor.run(body: { gate.acquire(token) }) { acquired = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let outcome: Result<GeneratedLyricsResult, Error>
            if !acquired {
                outcome = .failure(Task.isCancelled ? CancellationError() : AutoLyricsError.helperFailed(L("Đang có một lượt lấy lời khác đang chạy.")))
            } else {
                do { outcome = .success(try await svc.generateLyrics(audioURL: audioURL, vocalStemURL: vocalStemURL, progress: report)) }
                catch { outcome = .failure(error) }
                await MainActor.run { gate.release(token) }      // luôn nhả cổng khi tiến trình đã KẾT THÚC thật
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch outcome {
                case .success(let r): self.finish(result: r, token: token)
                case .failure(let e) where e is CancellationError: self.finishCancelled(token: token)
                case .failure(let e): self.finish(failure: (e as? LocalizedError)?.errorDescription ?? e.localizedDescription, token: token)
                }
            }
        }
    }

    /// Huỷ: dừng ASR còn dở + kết thúc helper + giải phóng mô hình + vứt bản nháp. Project không bị chạm tới.
    func cancel() {
        runToken = UUID()                       // mọi tiến độ/kết quả về muộn sẽ bị bỏ qua
        service.cancel()
        task?.cancel(); task = nil
        draft = nil; jobOwner = nil
        phase = .idle
    }

    /// Đóng bản nháp / lỗi mà không dùng.
    func discard() {
        guard !isRunning else { cancel(); return }
        draft = nil; jobOwner = nil; phase = .idle
    }

    /// DUY NHẤT nơi văn bản bản nháp được giao ra ngoài — chỉ khi đang `.review` và đúng project (`owner`). Sau đó bản nháp bị xoá.
    /// Sai project → vứt bản nháp và trả nil (kết quả của project A không bao giờ vào project B).
    func takeDraftForImport(owner: UUID) -> String? {
        guard case .review = phase, let d = draft else { return nil }
        guard owner == jobOwner else { draft = nil; jobOwner = nil; phase = .idle; return nil }
        draft = nil; jobOwner = nil; phase = .idle
        return d.plainText
    }

    // MARK: - Private

    private func apply(progress: AutoLyricsProgress, token: UUID) {
        guard token == runToken, case .running = phase else { return }
        phase = .running(progress)
    }

    private func finish(result: GeneratedLyricsResult, token: UUID) {
        guard token == runToken else { return }
        task = nil
        if result.isEmpty {
            draft = nil
            phase = .failed(L("Không nhận ra lời nào trong bài này (có thể đây là bản nhạc không lời)."))
        } else {
            draft = result; phase = .review
        }
    }

    private func finish(failure: String, token: UUID) {
        guard token == runToken else { return }
        task = nil; draft = nil; phase = .failed(failure)
    }

    private func finishCancelled(token: UUID) {
        guard token == runToken else { return }
        task = nil; draft = nil; phase = .idle
    }
}
