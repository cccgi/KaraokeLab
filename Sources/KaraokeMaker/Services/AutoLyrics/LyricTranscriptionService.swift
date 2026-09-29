import Foundation
import AppKit

/// Ranh giới dịch vụ "Tự động lấy lời". View/Controller chỉ biết giao diện này — KHÔNG biết Python, Torch, MPS hay Intel.
protocol LyricTranscriptionService: AnyObject {
    /// Sinh BẢN NHÁP lời từ file nhạc. `vocalStemURL` chỉ để dò đoạn có giọng hát (không đưa vào ASR).
    /// Huỷ = huỷ `Task` hoặc gọi `cancel()`; trả về bằng `CancellationError`.
    func generateLyrics(audioURL: URL, vocalStemURL: URL?,
                        progress: @escaping @Sendable (AutoLyricsProgress) -> Void) async throws -> GeneratedLyricsResult
    /// Dừng việc đang chạy: dừng nhận dạng còn dở, kết thúc tiến trình helper, giải phóng mô hình.
    func cancel()
}

/// Cài đặt thật: chạy helper Python (qwen-asr chính thức) ở TIẾN TRÌNH RIÊNG, nói chuyện bằng JSON từng dòng.
/// Không chạy gì trên main thread. Không đụng project, timeline hay bộ canh giờ.
final class QwenHelperTranscriptionService: LyricTranscriptionService, @unchecked Sendable {

    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    /// Đặt khác nil để chỉ định runtime cụ thể (test); mặc định tự dò.
    private let runtimeOverride: AutoLyricsRuntime?
    private let keepDiagnostics: Bool
    private let hardwareOverride: AutoLyricsHardware?

    private var terminateObserver: NSObjectProtocol?
    private var jobDir: URL?          // thư mục tạm của lượt đang chạy (dọn ngay khi app thoát giữa chừng)

    init(runtime: AutoLyricsRuntime? = nil, hardware: AutoLyricsHardware? = nil, diagnostics: Bool = AutoLyricsFeature.diagnosticsEnabled) {
        self.runtimeOverride = runtime; self.hardwareOverride = hardware; self.keepDiagnostics = diagnostics
        // Thoát app lúc đang nhận dạng → dừng helper ngay (ngoài ra helper tự thoát khi stdin đóng).
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.cancelForTermination() }
    }

    deinit { if let o = terminateObserver { NotificationCenter.default.removeObserver(o) } }

    /// Chốt chặn cuối cùng (ngoài `AutoLyricsJobGate`): toàn tiến trình chỉ 1 helper chạy tại 1 thời điểm.
    private static let busyLock = NSLock()
    private static var helperBusy = false
    private static var launches = 0
    /// Số lần helper đã khởi động trong tiến trình này (kiểm thử: "thử lại canh giờ" không được chạy lại ASR).
    static var launchCount: Int { busyLock.lock(); defer { busyLock.unlock() }; return launches }
    private static func takeBusy() -> Bool { busyLock.lock(); defer { busyLock.unlock() }; if helperBusy { return false }; helperBusy = true; launches += 1; return true }
    private static func dropBusy() { busyLock.lock(); helperBusy = false; busyLock.unlock() }

    // MARK: - Public

    func generateLyrics(audioURL: URL, vocalStemURL: URL?,
                        progress: @escaping @Sendable (AutoLyricsProgress) -> Void) async throws -> GeneratedLyricsResult {
        resetCancelled()
        guard let vocalStemURL, FileManager.default.fileExists(atPath: vocalStemURL.path) else { throw AutoLyricsError.needsVocalStem }
        let runtime = try runtimeOverride ?? AutoLyricsRuntime.locate(hardware: hardwareOverride ?? .current)

        Self.sweepStaleJobDirs()
        let job = FileManager.default.temporaryDirectory.appendingPathComponent("KaraokeMaker-autolyrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        setJobDir(job)
        defer { setJobDir(nil); try? FileManager.default.removeItem(at: job) }   // bản nháp tạm: dọn sạch dù xong, lỗi hay huỷ

        progress(.preparing)
        let mix = job.appendingPathComponent("mix_16k.wav"), vocal = job.appendingPathComponent("vocal_16k.wav")
        try await Task.detached(priority: .userInitiated) {
            try AutoLyricsAudioPrep.write16kMonoWAV(from: audioURL, to: mix)
            try AutoLyricsAudioPrep.write16kMonoWAV(from: vocalStemURL, to: vocal)
        }.value
        try Task.checkCancellation()

        let outURL = job.appendingPathComponent("result.json")
        try await runHelper(runtime: runtime, mix: mix, vocal: vocal, out: outURL, progress: progress)

        guard let data = try? Data(contentsOf: outURL) else { throw AutoLyricsError.badResult(L("Không có file kết quả.")) }
        if keepDiagnostics { saveDiagnostics(data) }
        do { return try GeneratedLyricsResult.decode(from: data) }
        catch { throw AutoLyricsError.badResult(error.localizedDescription) }
    }

    /// Thư mục tạm của lượt trước bị bỏ lại (app bị tắt cưỡng bức lúc đang chạy) → dọn nếu cũ hơn 1 giờ.
    private static func sweepStaleJobDirs() {
        let fm = FileManager.default, tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for u in items where u.lastPathComponent.hasPrefix("KaraokeMaker-autolyrics-") {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(m) > 3600 { try? fm.removeItem(at: u) }
        }
    }

    /// App đang thoát: dừng helper VÀ xoá thư mục tạm ngay (tác vụ nền sẽ không kịp chạy `defer`).
    private func cancelForTermination() {
        cancel()
        lock.lock(); let j = jobDir; lock.unlock()
        if let j { try? FileManager.default.removeItem(at: j) }
    }

    private func setJobDir(_ u: URL?) { lock.lock(); jobDir = u; lock.unlock() }

    private func resetCancelled() { lock.lock(); cancelled = false; lock.unlock() }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()                                                   // SIGTERM: helper thoát ngay, HĐH thu hồi bộ nhớ mô hình
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(pid, SIGKILL) } }   // chốt hạ nếu kẹt
    }

    // MARK: - Helper process

    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buf = Data()
        var resultPath: String?
        var errorCode: String?
        var errorMessage: String?
        var stderrTail = Data()
        private let progress: @Sendable (AutoLyricsProgress) -> Void
        init(progress: @escaping @Sendable (AutoLyricsProgress) -> Void) { self.progress = progress }

        func feed(_ d: Data) {
            lock.lock(); buf.append(d)
            var lines: [Data] = []
            while let nl = buf.firstIndex(of: 0x0A) { lines.append(buf.subdata(in: buf.startIndex..<nl)); buf.removeSubrange(buf.startIndex...nl) }
            lock.unlock()
            for l in lines { handle(l) }
        }
        func flush() { lock.lock(); let rest = buf; buf.removeAll(); lock.unlock(); if !rest.isEmpty { handle(rest) } }
        func feedErr(_ d: Data) { lock.lock(); stderrTail.append(d); if stderrTail.count > 8192 { stderrTail = Data(stderrTail.suffix(8192)) }; lock.unlock() }

        private func handle(_ line: Data) {
            guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let ev = o["event"] as? String else { return }
            func int(_ k: String) -> Int { (o[k] as? Int) ?? Int((o[k] as? Double) ?? 0) }
            switch ev {
            case "status":
                switch o["phase"] as? String {
                case "prepare": progress(.preparing)
                case "check": progress(.checking)
                case "finish": progress(.finishing)
                default: break
                }
            case "model":
                if (o["state"] as? String) == "loading" { progress(.loadingModel) }
            case "progress":
                let d = int("done"), t = int("total")
                switch o["phase"] as? String {
                case "recognize": progress(.recognizing(done: d, total: t))
                case "verify": progress(.verifying(done: d, total: t))
                case "context": progress(.rechecking(done: d, total: t))
                default: break
                }
            case "done": lock.lock(); resultPath = o["result"] as? String; lock.unlock()
            case "error": lock.lock(); errorCode = o["code"] as? String; errorMessage = o["message"] as? String; lock.unlock()
            default: break
            }
        }
    }

    private func runHelper(runtime: AutoLyricsRuntime, mix: URL, vocal: URL, out: URL,
                           progress: @escaping @Sendable (AutoLyricsProgress) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock(); let already = cancelled; lock.unlock()
                if already { cont.resume(throwing: CancellationError()); return }
                guard Self.takeBusy() else { cont.resume(throwing: AutoLyricsError.helperFailed(L("Đang có một lượt lấy lời khác đang chạy."))); return }

                var args = ["--mix", mix.path, "--vocal", vocal.path, "--out", out.path,
                            "--device", runtime.hardware.device, "--hf-home", runtime.hfHome.path]
                if keepDiagnostics { args.append("--diagnostics") }
                let l = runtime.launch(arguments: args)
                let p = Process()
                p.executableURL = l.executable; p.arguments = l.arguments; p.environment = runtime.environment()
                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()   // stdin mở suốt: helper tự thoát nếu app chết
                p.standardOutput = outPipe; p.standardError = errPipe; p.standardInput = inPipe
                let sink = LineSink(progress: progress)
                outPipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { sink.feed(d) } }
                errPipe.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; if d.isEmpty { h.readabilityHandler = nil } else { sink.feedErr(d) } }

                p.terminationHandler = { [weak self] proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    sink.feed(outPipe.fileHandleForReading.readDataToEndOfFile()); sink.flush()
                    sink.feedErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    _ = inPipe                                              // giữ pipe sống tới lúc tiến trình kết thúc
                    guard let self else { Self.dropBusy(); cont.resume(throwing: CancellationError()); return }
                    self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                    Self.dropBusy()
                    if wasCancelled || proc.terminationStatus == 143 { cont.resume(throwing: CancellationError()); return }
                    // "done" đã phát + file kết quả đã ghi nguyên vẹn (đổi tên nguyên tử) = thành công, bất kể mã thoát lúc tắt Python.
                    if sink.resultPath != nil, FileManager.default.fileExists(atPath: out.path) { cont.resume(); return }
                    cont.resume(throwing: Self.map(code: sink.errorCode, message: sink.errorMessage,
                                                   stderr: String(decoding: sink.stderrTail, as: UTF8.self), status: proc.terminationStatus))
                }
                lock.lock(); process = p; lock.unlock()
                do { try p.run() }
                catch {
                    lock.lock(); process = nil; lock.unlock()
                    Self.dropBusy()
                    cont.resume(throwing: AutoLyricsError.runtimeMissing(error.localizedDescription))
                }
            }
        } onCancel: { [weak self] in self?.cancel() }
    }

    private static func map(code: String?, message: String?, stderr: String, status: Int32) -> AutoLyricsError {
        let msg = message ?? ""
        switch code {
        case "runtime_missing": return .runtimeMissing(msg)
        case "model_missing": return .modelMissing(msg)
        case "backend_unavailable": return .backendUnavailable(msg)
        case "out_of_memory": return .helperFailed(L("Không đủ bộ nhớ."))
        default:
            if code == nil {           // helper chết đột ngột (crash / bị kill): KHÔNG hiện đống log kỹ thuật cho người dùng — ghi ra file nhật ký
                saveErrorLog(stderr, status: status)
                return .helperFailed(String(format: L("Bộ nhận dạng đã dừng đột ngột (mã %d). Bấm “Thử lại”."), Int(status)))
            }
            return .helperFailed(msg)
        }
    }

    /// Đuôi stderr của helper khi chết bất thường → ~/Library/Logs/KaraokeMaker/autolyrics-error-<giờ>.txt (dùng cho người gỡ lỗi).
    private static func saveErrorLog(_ text: String, status: Int32) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KaraokeMaker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? "exit status \(status)\n\(text)".write(to: dir.appendingPathComponent("autolyrics-error-\(f.string(from: Date())).txt"), atomically: true, encoding: .utf8)
    }

    /// Nhật ký chẩn đoán kỹ thuật (chỉ khi bật cờ): ~/Library/Logs/KaraokeMaker/autolyrics-<giờ>.json
    private func saveDiagnostics(_ data: Data) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/KaraokeMaker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? data.write(to: dir.appendingPathComponent("autolyrics-\(f.string(from: Date())).json"))
    }
}
