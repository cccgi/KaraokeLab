import Foundation
import SwiftUI
import AppKit

/// Kiểm thử không giao diện cho "Tự động lấy lời" (giống kiểu `AlignTestCLI`). Không đụng project thật.
///   KaraokeMaker --autolyrics-test probe
///   KaraokeMaker --autolyrics-test run    <audio> <vocalStem> [--diag]
///   KaraokeMaker --autolyrics-test cancel <audio> <vocalStem>
///   KaraokeMaker --autolyrics-test prep <src-audio> <out.wav>          (chỉ chạy bước đổi 16 kHz mono của app)
///   KaraokeMaker --autolyrics-test selftest [<helper-result.json>]
enum AutoLyricsTestCLI {

    static func main(_ args: [String]) {
        let app = NSApplication.shared                 // SwiftUI (ImageRenderer) cần NSApplication + vòng lặp chính thật
        app.setActivationPolicy(.prohibited)           // không hiện icon Dock / cửa sổ
        DispatchQueue.main.async {
            Task { @MainActor in
                let code = await run(args)
                exit(code)
            }
        }
        app.run()
    }

    // MARK: - Dispatcher

    @MainActor
    static func run(_ a: [String]) async -> Int32 {
        guard let mode = a.first else { print("usage: --autolyrics-test probe|run|cancel|selftest …"); return 2 }
        switch mode {
        case "probe": return await probe()
        case "run":
            guard a.count >= 3 else { print("usage: run <audio> <vocalStem> [--diag]"); return 2 }
            return await runReal(audio: a[1], vocal: a[2], diag: a.contains("--diag"))
        case "cancel":
            guard a.count >= 3 else { print("usage: cancel <audio> <vocalStem>"); return 2 }
            return await cancelReal(audio: a[1], vocal: a[2])
        case "selftest": return await selfTest(fixture: a.count > 1 ? a[1] : nil)
        case "prep":
            guard a.count >= 3 else { print("usage: prep <src-audio> <out.wav>"); return 2 }
            do { try AutoLyricsAudioPrep.write16kMonoWAV(from: URL(fileURLWithPath: a[1]), to: URL(fileURLWithPath: a[2])); print("wrote \(a[2])"); return 0 }
            catch { print("FAILED: \(error.localizedDescription)"); return 1 }
        default: print("unknown mode \(mode)"); return 2
        }
    }

    // MARK: - probe / run / cancel (helper thật)

    @MainActor
    static func probe() async -> Int32 {
        let hw = AutoLyricsHardware.current
        print("hardware: \(hw == .appleSilicon ? "Apple Silicon" : "Intel") -> device \(hw.device), dtype \(hw.dtype)")
        do {
            let rt = try AutoLyricsRuntime.locate()
            print("python:  \(rt.python.path)\nhf_home: \(rt.hfHome.path)\nhelper:  \(rt.helperScript.path)")
            let l = rt.launch(arguments: ["--probe"])
            print("launch:  \(l.executable.path) \(l.arguments.prefix(3).joined(separator: " ")) …")
            guard let info = await rt.probe() else { print("PROBE FAILED (no answer)"); return 1 }
            print("probe:   \(info)")
            return (info["ready"] as? Bool) == true ? 0 : 1
        } catch { print("RUNTIME ERROR: \(error.localizedDescription)"); return 1 }
    }

    @MainActor
    static func runReal(audio: String, vocal: String, diag: Bool) async -> Int32 {
        let svc = QwenHelperTranscriptionService(diagnostics: diag)
        let t0 = Date()
        do {
            let r = try await svc.generateLyrics(audioURL: URL(fileURLWithPath: audio), vocalStemURL: URL(fileURLWithPath: vocal)) { p in
                print(String(format: "[%6.1fs] %@", Date().timeIntervalSince(t0), p.label)); fflush(stdout)
            }
            print(String(format: "DONE in %.1fs | backend %@/%@ | lines %d | words %d | uncertain %d | non-lexical %d | unconfirmed %d",
                         Date().timeIntervalSince(t0), r.backend?.device ?? "?", r.backend?.dtype ?? "?", r.lines.count,
                         r.stats?.words ?? 0, r.uncertainWords.count, r.nonLexicalVocal.count, r.unconfirmedVocalChunks.count))
            print("first line approx start: \(r.lines.first?.approxStart ?? -1)s  (instrumental windows: \(r.stats?.instrumentalWindows ?? -1))")
            print("--- draft ---")
            for l in r.lines {
                if l.sectionBreakBefore { print("") }
                print(l.words.map { $0.isUncertain ? "⟦\($0.text)\($0.alternatives.isEmpty ? "" : "|" + $0.alternatives.joined(separator: ","))⟧" : $0.text }.joined(separator: " "))
            }
            return 0
        } catch { print("FAILED: \(error.localizedDescription)"); return 1 }
    }

    /// Bắt đầu chạy thật, chờ tới khi đã nhận dạng được ≥ 1 đoạn rồi HUỶ: helper phải chết nhanh, không sót tiến trình.
    @MainActor
    static func cancelReal(audio: String, vocal: String) async -> Int32 {
        let svc = QwenHelperTranscriptionService()
        final class Flag: @unchecked Sendable { let l = NSLock(); var v = false; func set() { l.lock(); v = true; l.unlock() }; var get: Bool { l.lock(); defer { l.unlock() }; return v } }
        let started = Flag()
        let task = Task { () -> Result<GeneratedLyricsResult, Error> in
            do { return .success(try await svc.generateLyrics(audioURL: URL(fileURLWithPath: audio), vocalStemURL: URL(fileURLWithPath: vocal)) { p in
                if case .recognizing(let d, _) = p, d >= 1 { started.set() }
                print("  progress: \(p.label)"); fflush(stdout)
            }) } catch { return .failure(error) }
        }
        let deadline = Date().addingTimeInterval(600)
        while !started.get && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard started.get else { print("FAIL: never reached recognizing"); return 1 }
        print("cancelling now…")
        let t1 = Date()
        svc.cancel(); task.cancel()
        let out = await task.value
        let dt = Date().timeIntervalSince(t1)
        var ok = true
        if case .failure(let e) = out, e is CancellationError { print(String(format: "PASS: CancellationError after %.2fs", dt)) }
        else { print("FAIL: expected CancellationError, got \(out)"); ok = false }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let left = shell("pgrep -f lyric_asr_helper.py | wc -l").trimmingCharacters(in: .whitespacesAndNewlines)
        let leftovers = shell("ls \"\(NSTemporaryDirectory())\" | grep -c KaraokeMaker-autolyrics || true").trimmingCharacters(in: .whitespacesAndNewlines)
        print("helper processes still alive: \(left) | leftover temp dirs: \(leftovers)")
        if left != "0" { ok = false }
        return ok ? 0 : 1
    }

    private static func shell(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    // MARK: - selftest (dịch vụ giả — kiểm tra HỢP ĐỒNG an toàn của controller)

    private final class StubService: LyricTranscriptionService, @unchecked Sendable {
        enum Mode { case succeed(GeneratedLyricsResult), fail(Error), hang }
        var mode: Mode
        private let l = NSLock(); private var _cancels = 0; private var _calls = 0
        init(_ m: Mode) { mode = m }
        // `NSLock.lock()/unlock()` are `noasync` — Swift 6 flags calling them directly inside an
        // `async` function even when never held across a suspension point. Routing through a
        // plain, non-`async` helper keeps the lock calls in a synchronous context.
        private func withLock<T>(_ body: () -> T) -> T { l.lock(); defer { l.unlock() }; return body() }
        var cancelCalls: Int { withLock { _cancels } }
        var calls: Int { withLock { _calls } }
        func cancel() { withLock { _cancels += 1 } }
        func generateLyrics(audioURL: URL, vocalStemURL: URL?, progress: @escaping @Sendable (AutoLyricsProgress) -> Void) async throws -> GeneratedLyricsResult {
            withLock { _calls += 1 }
            progress(.recognizing(done: 1, total: 14))
            switch mode {
            case .succeed(let r): try await Task.sleep(nanoseconds: 80_000_000); return r
            case .fail(let e): throw e
            case .hang:
                while !Task.isCancelled { try await Task.sleep(nanoseconds: 20_000_000) }
                throw CancellationError()
            }
        }
    }

    /// Dịch vụ giả đo số lượt chạy ĐỒNG THỜI toàn tiến trình.
    private final class CountingStub: LyricTranscriptionService, @unchecked Sendable {
        private static let l = NSLock(); private static var active = 0, _max = 0, _total = 0
        private static func withLock<T>(_ body: () -> T) -> T { l.lock(); defer { l.unlock() }; return body() }
        static func reset() { withLock { active = 0; _max = 0; _total = 0 } }
        static var maxActive: Int { withLock { _max } }
        static var total: Int { withLock { _total } }
        private let stopLock = NSLock(); private var stopped = false
        private func withStopLock<T>(_ body: () -> T) -> T { stopLock.lock(); defer { stopLock.unlock() }; return body() }
        func cancel() { withStopLock { stopped = true } }
        func generateLyrics(audioURL: URL, vocalStemURL: URL?, progress: @escaping @Sendable (AutoLyricsProgress) -> Void) async throws -> GeneratedLyricsResult {
            Self.withLock { Self.active += 1; Self._total += 1; Self._max = max(Self._max, Self.active) }
            defer { Self.withLock { Self.active -= 1 } }
            progress(.recognizing(done: 1, total: 14))
            for _ in 0..<15 {                                              // ~300 ms, huỷ được, và (như helper thật) mất thêm chút để tắt
                try await Task.sleep(nanoseconds: 20_000_000)
                let st = withStopLock { stopped }
                if st || Task.isCancelled { try await Task.sleep(nanoseconds: 150_000_000); throw CancellationError() }
            }
            return GeneratedLyricsResult(lines: [GeneratedLyricLine(words: [.init(text: "a", confidence: .confident)])])
        }
    }

    @MainActor
    private static func waitFor(_ c: AutoLyricsController, timeout: Double = 5, _ pred: (AutoLyricsController.Phase) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if pred(c.phase) { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return pred(c.phase)
    }

    @MainActor
    static func selfTest(fixture: String?) async -> Int32 {
        var fails = 0
        let ownerA = UUID(), ownerB = UUID()
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — \(detail)")); if !ok { fails += 1 } }

        let sample = GeneratedLyricsResult(lines: [
            GeneratedLyricLine(words: [.init(text: "cuộc", confidence: .confident), .init(text: "tình", confidence: .confident), .init(text: "dĩ", confidence: .confident),
                                       .init(text: "vang", confidence: .uncertain, alternatives: ["vãng", "vẫn"])], sectionBreakBefore: false, approxStart: 35),
            GeneratedLyricLine(words: [.init(text: "anh", confidence: .uncertain, alternatives: [], kind: .possibleMissing), .init(text: "đi", confidence: .confident)], sectionBreakBefore: true, approxStart: 60),
        ], nonLexicalVocal: [NonLexicalVocal(start: 240, end: 262, text: "Hm")])
        let audio = URL(fileURLWithPath: "/tmp/does-not-matter.wav")
        let vocal = URL(fileURLWithPath: "/tmp/autolyrics-selftest-vocal.wav"); FileManager.default.createFile(atPath: vocal.path, contents: Data([0]))
        defer { try? FileManager.default.removeItem(at: vocal) }

        // 0. bảng dịch nạp được (khoá trùng làm app văng ngay lúc dịch chuỗi đầu tiên)
        check("LOCALIZATION: table loads without duplicate keys; new strings translated", LocTables.all[.en]?["Tự động lấy lời"] == "Auto Lyrics" && LocTables.all[.en]?["Dùng lời này"] == "Use these lyrics")
        // 1. project TRỐNG
        do {
            let c = AutoLyricsController(service: StubService(.succeed(sample)))
            c.start(audioURL: nil, vocalStemURL: nil, owner: ownerA)
            if case .failed = c.phase { check("EMPTY PROJECT: no audio -> clear failure, no crash", true) } else { check("EMPTY PROJECT", false, "\(c.phase)") }
        }
        // 2. thiếu bản tách giọng → trạng thái rõ ràng, KHÔNG chạy gì
        do {
            let stub = StubService(.succeed(sample)); let c = AutoLyricsController(service: stub)
            c.start(audioURL: audio, vocalStemURL: nil, owner: ownerA)
            check("NO VOCAL STEM: status .needsVocalStem, ASR never started", c.phase == .needsVocalStem && stub.calls == 0)
        }
        // 3. lời hiện có KHÔNG bị ghi đè trước khi xác nhận (chạy xong → xem → Hủy)
        do {
            var projectLyrics = "Lời cũ của tôi\nDòng hai"          // đại diện lời hiện có của project (controller không hề nhận được tham chiếu)
            let before = projectLyrics
            let c = AutoLyricsController(service: StubService(.succeed(sample)))
            c.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            let reached = await waitFor(c) { $0 == .review }
            check("EXISTING LYRICS: draft reaches review, project text untouched", reached && projectLyrics == before)
            check("EXISTING LYRICS: nothing is exported before confirmation", c.draft != nil && c.phase == .review)
            c.discard()
            check("EXISTING LYRICS: after Hủy the draft is gone and project text still identical", c.draft == nil && c.phase == .idle && projectLyrics == before)
            check("EXISTING LYRICS: takeDraftForImport after discard yields nothing", c.takeDraftForImport(owner: ownerA) == nil)
            projectLyrics += ""                                        // (silence 'never mutated' warning)
        }
        // 4. chỉ "Dùng lời này" mới giao văn bản ra; giao đúng 1 lần; văn bản không có dấu "?"
        do {
            let c = AutoLyricsController(service: StubService(.succeed(sample)))
            c.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            check("IMPORT: nothing can be taken while still running", c.takeDraftForImport(owner: ownerA) == nil)
            _ = await waitFor(c) { $0 == .review }
            let text = c.takeDraftForImport(owner: ownerA)
            check("IMPORT: text delivered only after review", text != nil)
            check("IMPORT: uncertain words kept verbatim, no '?' markers, blank line between sections", text == "cuộc tình dĩ vang\n\nanh đi", text ?? "nil")
            check("IMPORT: second take returns nothing", c.takeDraftForImport(owner: ownerA) == nil)
        }
        // 5. HUỶ khi đang chạy
        do {
            let stub = StubService(.hang); let c = AutoLyricsController(service: stub)
            let projectLyrics = "giữ nguyên"
            c.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            let running = await waitFor(c) { if case .running = $0 { return true }; return false }
            c.cancel()
            try? await Task.sleep(nanoseconds: 200_000_000)
            check("CANCEL: was running, service.cancel() called, controller idle, draft discarded, project untouched",
                  running && stub.cancelCalls >= 1 && c.phase == .idle && c.draft == nil && projectLyrics == "giữ nguyên")
        }
        // 6. lỗi từ dịch vụ → thông báo, project không đổi
        do {
            let c = AutoLyricsController(service: StubService(.fail(AutoLyricsError.runtimeMissing("x"))))
            c.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            check("ERROR: helper failure surfaces as .failed", await waitFor(c) { if case .failed = $0 { return true }; return false })
        }
        // 7. bản nháp rỗng (nhạc không lời) → không tạo lời giả
        do {
            let c = AutoLyricsController(service: StubService(.succeed(GeneratedLyricsResult(lines: []))))
            c.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            let failed = await waitFor(c) { if case .failed = $0 { return true }; return false }
            check("INSTRUMENTAL-ONLY: empty result never becomes a draft", failed && c.draft == nil)
        }
        // 7b. ĐỔI PROJECT: kết quả của project A không bao giờ giao cho project B
        do {
            let c = AutoLyricsController(service: StubService(.succeed(sample)))
            c.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            _ = await waitFor(c) { $0 == .review }
            let leaked = c.takeDraftForImport(owner: ownerB)                 // "Dùng lời này" bấm khi đã sang project B
            check("PROJECT SWITCH: A's draft is NOT delivered to B, and is discarded", leaked == nil && c.draft == nil && c.phase == .idle, "leaked=\(leaked ?? "nil")")
            let c2 = AutoLyricsController(service: StubService(.hang))
            c2.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            _ = await waitFor(c2) { if case .running = $0 { return true }; return false }
            c2.cancel()                                                      // ContentView làm việc này khi projectSessionID đổi / rời tab
            check("PROJECT SWITCH: running job is cancelled and nothing is left to import", c2.phase == .idle && c2.takeDraftForImport(owner: ownerA) == nil && c2.takeDraftForImport(owner: ownerB) == nil)
        }
        // 7c. KHÔNG hai lượt cùng lúc (2 controller dùng chung cổng; dịch vụ giả đo số lượt chạy đồng thời)
        do {
            CountingStub.reset()
            let c1 = AutoLyricsController(service: CountingStub()), c2 = AutoLyricsController(service: CountingStub())
            c1.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            c2.start(audioURL: audio, vocalStemURL: vocal, owner: ownerB)
            let ok1 = await waitFor(c1, timeout: 8) { $0 == .review }, ok2 = await waitFor(c2, timeout: 8) { $0 == .review }
            check("SINGLE JOB: two controllers started at once never ran concurrently (max \(CountingStub.maxActive)), both finished in turn", CountingStub.maxActive == 1 && ok1 && ok2 && CountingStub.total == 2)
            CountingStub.reset()
            let c3 = AutoLyricsController(service: CountingStub()), c4 = AutoLyricsController(service: CountingStub())
            c3.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            _ = await waitFor(c3) { if case .running = $0 { return true }; return false }
            try? await Task.sleep(nanoseconds: 60_000_000)
            c3.cancel(); c4.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)      // Hủy rồi bấm lại NGAY
            let ok4 = await waitFor(c4, timeout: 8) { $0 == .review }
            check("SINGLE JOB: cancel then immediate restart waits for the old job to end (max concurrent \(CountingStub.maxActive))", CountingStub.maxActive == 1 && ok4)
            let stub = StubService(.hang); let c5 = AutoLyricsController(service: stub)
            c5.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA); c5.start(audioURL: audio, vocalStemURL: vocal, owner: ownerA)
            _ = await waitFor(c5) { if case .running = $0 { return true }; return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
            check("SINGLE JOB: pressing Start twice on the same controller starts ONE job", stub.calls == 1, "calls=\(stub.calls)")
            c5.cancel(); try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // 7d. LUỒNG "KHÔNG CẦN LỜI" đầu-cuối (dịch vụ giả + bước canh giờ giả): nhạc → lời → canh giờ tự động
        do {
            final class Host {
                var session = UUID(); var audio: URL?; var vocal: URL?; var analyzeResult: URL?
                var timingTexts: [String] = []; var applied = 0; var outcome: KaraokeTimingOutcome = .success(lines: 2)
                var timingDelayNs: UInt64 = 0; var analyzeCalls = 0
                var lines: [LyricLine] = []; var uncertain: [AutoUncertainWord] = []
            }
            func hooks(_ h: Host) -> AutoKaraokeHooks {
                AutoKaraokeHooks(projectSession: { h.session }, sourceAudio: { h.audio }, vocalStem: { h.vocal },
                                 analyzeMusic: { h.analyzeCalls += 1; if let v = h.analyzeResult { h.vocal = v }; return h.analyzeResult },
                                 createKaraoke: { text, shouldApply in
                                     h.timingTexts.append(text)
                                     if h.timingDelayNs > 0 { try? await Task.sleep(nanoseconds: h.timingDelayNs) }
                                     guard shouldApply() else { return .discarded }
                                     if case .success = h.outcome { h.applied += 1 }
                                     return h.outcome
                                 },
                                 currentLines: { h.lines }, karaokeCreated: { h.uncertain = $0 })
            }
            func flowPhase(_ f: AutoKaraokeFlow, timeout: Double = 8, _ pred: (AutoKaraokeFlow.Phase) -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end { if pred(f.phase) { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
                return pred(f.phase)
            }
            func isDone(_ p: AutoKaraokeFlow.Phase) -> Bool { if case .done = p { return true }; return false }
            func isFail(_ p: AutoKaraokeFlow.Phase) -> Bool { switch p { case .failedAnalysis, .failedRecognition, .failedTiming: return true; default: return false } }
            let timed = [LyricLine(text: "cuộc tình dĩ vang"), LyricLine(text: "anh đi")]

            // thành công: văn bản đưa cho bộ canh giờ = văn bản thuần (không có ? ⟦ ⟧), đúng 1 lần; từ chưa chắc còn theo dõi được
            do {
                let h = Host(); h.audio = audio; h.vocal = vocal; h.lines = timed
                let stub = StubService(.succeed(sample)); let f = AutoKaraokeFlow(service: stub); f.hooks = hooks(h)
                var seen: [String] = []
                let watcher = Task { @MainActor in for await p in f.$phase.values { seen.append("\(p)".components(separatedBy: "(").first ?? "") } }
                f.start()
                let ok = await flowPhase(f) { isDone($0) }
                watcher.cancel()
                check("NO-LYRICS FLOW: audio -> ASR -> automatic timing -> done, no manual step", ok && stub.calls == 1 && h.timingTexts.count == 1 && h.applied == 1)
                check("NO-LYRICS FLOW: timing engine received PLAIN text (no ? ⟦⟧ [ ] |), uncertain words kept as best text", h.timingTexts.first == "cuộc tình dĩ vang\n\nanh đi" && !(h.timingTexts.first ?? "").contains(where: { "?⟦⟧[]|".contains($0) }), h.timingTexts.first ?? "nil")
                check("NO-LYRICS FLOW: phases visible in order (recognizing -> timing -> done)", seen.firstIndex(of: "recognizing").map { r in (seen.firstIndex(of: "timing") ?? -1) > r && (seen.firstIndex(of: "done") ?? -1) > (seen.firstIndex(of: "timing") ?? -1) } ?? false, "\(seen)")
                check("UNCERTAINTY: after automatic timing both uncertain words are attached to timed lines", h.uncertain.count == 2 && h.uncertain[0].original == "vang" && h.uncertain[0].alternatives == ["vãng", "vẫn"] && h.uncertain[0].wordIndex == 3 && h.uncertain[0].lineID == timed[0].id && h.uncertain[1].lineID == timed[1].id && h.uncertain[1].kind == .possibleMissing)
                check("UNCERTAINTY: replacing a word keeps the other words", UncertaintyMapper.replacingWord(in: "cuộc tình dĩ vang", at: 3, with: "vãng") == "cuộc tình dĩ vãng")
            }
            // thiếu bản giọng hát → chạy bước phân tích nhạc sẵn có TRƯỚC; phân tích lỗi → dừng, không chạy ASR
            do {
                let h = Host(); h.audio = audio; h.vocal = nil; h.analyzeResult = nil
                let stub = StubService(.succeed(sample)); let f = AutoKaraokeFlow(service: stub); f.hooks = hooks(h); f.start()
                let failed = await flowPhase(f) { if case .failedAnalysis = $0 { return true }; return false }
                check("FAILURE: analysis fails -> failedAnalysis, ASR never started, timing never started", failed && stub.calls == 0 && h.timingTexts.isEmpty && h.analyzeCalls == 1)
                let h2 = Host(); h2.audio = audio; h2.vocal = nil; h2.analyzeResult = vocal
                let stub2 = StubService(.succeed(sample)); let f2 = AutoKaraokeFlow(service: stub2); f2.hooks = hooks(h2); f2.start()
                check("NO STEM: existing music-analysis step runs automatically, then the flow continues to the end", await flowPhase(f2) { isDone($0) } && h2.analyzeCalls == 1 && stub2.calls == 1)
            }
            // ASR lỗi → KHÔNG canh giờ; thử lại chạy lại được
            do {
                let h = Host(); h.audio = audio; h.vocal = vocal
                let stub = StubService(.fail(AutoLyricsError.runtimeMissing("x"))); let f = AutoKaraokeFlow(service: stub); f.hooks = hooks(h); f.start()
                let failed = await flowPhase(f) { if case .failedRecognition = $0 { return true }; return false }
                check("FAILURE: recognition fails -> failedRecognition and timing is NOT started", failed && h.timingTexts.isEmpty && h.applied == 0)
                stub.mode = .succeed(sample); f.start()
                check("RETRY: 'Thử lại' after a recognition failure runs the whole flow again", await flowPhase(f) { isDone($0) } && h.applied == 1)
            }
            // canh giờ lỗi → GIỮ lời, thử lại canh giờ KHÔNG chạy lại ASR
            do {
                let h = Host(); h.audio = audio; h.vocal = vocal; h.lines = timed; h.outcome = .failure("Canh giờ không ra kết quả")
                let stub = StubService(.succeed(sample)); let f = AutoKaraokeFlow(service: stub); f.hooks = hooks(h); f.start()
                let failed = await flowPhase(f) { if case .failedTiming = $0 { return true }; return false }
                check("TIMING FAILURE: generated lyrics are KEPT and nothing is applied", failed && f.draftText == sample.plainText && h.applied == 0)
                h.outcome = .success(lines: 2); f.retryTiming()
                check("TIMING RETRY: succeeds without running ASR again", await flowPhase(f) { isDone($0) } && stub.calls == 1 && h.timingTexts.count == 2 && h.applied == 1)
            }
            // huỷ giữa lúc ASR / giữa lúc canh giờ / đổi project / bấm 2 lần
            do {
                let h = Host(); h.audio = audio; h.vocal = vocal
                let stub = StubService(.hang); let f = AutoKaraokeFlow(service: stub); f.hooks = hooks(h); f.start()
                _ = await flowPhase(f) { if case .recognizing = $0 { return true }; return false }
                f.start()                                                        // bấm lần 2 khi đang chạy → bỏ qua
                f.cancel(); try? await Task.sleep(nanoseconds: 300_000_000)
                check("CANCEL during ASR: helper stop requested, phase idle, nothing timed, nothing applied, second Start ignored", f.phase == .idle && stub.cancelCalls >= 1 && stub.calls == 1 && h.timingTexts.isEmpty && h.applied == 0)
            }
            do {
                let h = Host(); h.audio = audio; h.vocal = vocal; h.timingDelayNs = 400_000_000
                let f = AutoKaraokeFlow(service: StubService(.succeed(sample))); f.hooks = hooks(h); f.start()
                _ = await flowPhase(f) { $0 == .timing }
                f.cancel(); try? await Task.sleep(nanoseconds: 700_000_000)
                check("CANCEL during timing: result is discarded (no partial timed lyrics inserted)", f.phase == .idle && h.applied == 0 && f.draftText == nil)
            }
            do {
                let h = Host(); h.audio = audio; h.vocal = vocal; h.timingDelayNs = 400_000_000
                let f = AutoKaraokeFlow(service: StubService(.succeed(sample))); f.hooks = hooks(h); f.start()
                _ = await flowPhase(f) { $0 == .timing }
                h.session = UUID()                                                // user opened project B
                try? await Task.sleep(nanoseconds: 700_000_000)
                check("PROJECT SWITCH: lyrics/timing of project A are never applied to project B", h.applied == 0 && f.phase == .idle)
            }
        }
        // 8. UNCERTAIN đi qua JSON (Python → Swift)
        do {
            let json = """
            {"schema":1,"audio_seconds":10.0,"backend":{"device":"cpu","dtype":"float32","engine":"x"},
             "lines":[{"words":[{"text":"vang","confidence":"uncertain","alternatives":["vãng","vẫn"],"kind":"word"},
                                {"text":"anh","confidence":"uncertain","alternatives":[],"kind":"possible_missing"},
                                {"text":"đi","confidence":"confident","alternatives":[],"kind":"word"}],
                      "section_break_before":false,"approx_start":35.4}],
             "non_lexical_vocal":[{"start":240.0,"end":262.0,"text":"Hm"}],"unconfirmed_vocal_chunks":[{"start":0.0,"end":22.0,"text06":"Mới có","text17":"Người có"}],
             "stats":{"windows":14,"vocal_windows":12,"instrumental_windows":2,"verified_windows":12,"context_windows":5,"words":3,"uncertain_words":2},"warnings":[]}
            """
            let r = try GeneratedLyricsResult.decode(from: Data(json.utf8))
            let w = r.lines[0].words
            check("UNCERTAIN via JSON: confidence, alternatives, kind survive", w[0].isUncertain && w[0].alternatives == ["vãng", "vẫn"] && w[1].kind == .possibleMissing && !w[2].isUncertain)
            check("UNCERTAIN via JSON: non-lexical vocal stored separately (not in lines)", r.nonLexicalVocal.count == 1 && !r.plainText.contains("Hm") && r.unconfirmedVocalChunks.count == 1)
        } catch { check("UNCERTAIN via JSON decode", false, "\(error)") }
        // 9. kết quả THẬT của helper (tuỳ chọn)
        if let f = fixture, let data = FileManager.default.contents(atPath: f) {
            do {
                let r = try GeneratedLyricsResult.decode(from: data)
                let unc = r.uncertainWords.count
                check("REAL HELPER RESULT: decodes; uncertain count matches helper stats", unc == (r.stats?.uncertainWords ?? -1), "swift \(unc) vs helper \(r.stats?.uncertainWords ?? -1) | \(r.lines.count) lines, \(r.stats?.words ?? 0) words")
                check("REAL HELPER RESULT: uncertain words carry alternatives (survived Python→JSON→Swift)", r.uncertainWords.contains { !$0.word.alternatives.isEmpty })
                let wins = r.stats?.instrumentalWindows ?? 0
                check("REAL HELPER RESULT: instrumental windows reported (\(wins)) and first draft line starts after them", wins == 0 || (r.lines.first?.approxStart ?? 0) >= 15, "first line ~\(r.lines.first?.approxStart ?? -1)s")
            } catch { check("REAL HELPER RESULT decode", false, "\(error)") }
        }
        // 10. chọn backend theo máy + lệnh chạy
        do {
            let py = URL(fileURLWithPath: "/x/python"), hf = URL(fileURLWithPath: "/x/hf"), sc = URL(fileURLWithPath: "/x/h.py")
            let arm = AutoLyricsRuntime(hardware: .appleSilicon, python: py, hfHome: hf, helperScript: sc).launch(arguments: ["--device", "mps"])
            let x86 = AutoLyricsRuntime(hardware: .intel, python: py, hfHome: hf, helperScript: sc).launch(arguments: ["--device", "cpu"])
            check("BACKEND: Apple Silicon -> MPS/bf16 via `arch -arm64 python helper`", AutoLyricsHardware.appleSilicon.device == "mps" && AutoLyricsHardware.appleSilicon.dtype == "bfloat16"
                  && arm.executable.path == "/usr/bin/arch" && arm.arguments.prefix(3) == ["-arm64", "/x/python", "/x/h.py"])
            check("BACKEND: Intel -> CPU/fp32, python launched directly", AutoLyricsHardware.intel.device == "cpu" && AutoLyricsHardware.intel.dtype == "float32"
                  && x86.executable.path == "/x/python" && x86.arguments.first == "/x/h.py")
            print("      this machine detected as: \(AutoLyricsHardware.current == .appleSilicon ? "Apple Silicon" : "Intel")")
        }
        // 11. WAV 16k float đúng định dạng
        do {
            let d = AutoLyricsAudioPrep.wavData(samples: [0, 0.5, -0.5, 1], sampleRate: 16000)
            let riff = String(decoding: d.prefix(4), as: UTF8.self), wave = String(decoding: d.subdata(in: 8..<12), as: UTF8.self)
            check("AUDIO PREP: WAV header ok, size = 12 + fmt(26) + fact(12) + data(8+16)", riff == "RIFF" && wave == "WAVE" && d.count == 12 + 26 + 12 + 8 + 16, "\(d.count) bytes")
        }
        print(fails == 0 ? "\nALL SELFTESTS PASSED" : "\n\(fails) SELFTEST(S) FAILED")
        return Int32(fails)
    }
}
