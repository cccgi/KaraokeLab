import Foundation
import Darwin

/// Máy chạy app: quyết định bộ xử lý cho bộ nhận dạng. Người dùng KHÔNG thấy/không chỉnh phần này.
///   Apple Silicon (arm64) → Qwen3-ASR 0.6B, MPS, bf16
///   Intel (x86_64)        → Qwen3-ASR 0.6B, CPU, fp32
/// (Mô hình 1.7B luôn chỉ là bộ KIỂM TRA cho đoạn có giọng hát — quyết định trong helper.)
enum AutoLyricsHardware: Equatable {
    case appleSilicon
    case intel

    /// `hw.optional.arm64` = 1 trên mọi máy Apple Silicon, KỂ CẢ khi app chạy qua Rosetta.
    static var current: AutoLyricsHardware {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0, v == 1 { return .appleSilicon }
        return .intel
    }

    var device: String { self == .appleSilicon ? "mps" : "cpu" }
    var dtype: String { self == .appleSilicon ? "bfloat16" : "float32" }
}

/// Vị trí bộ chạy (Python + qwen-asr chính thức + PyTorch + 2 mô hình) và helper của app.
///
/// BẢN PHÁT HÀNH: mọi thứ nằm NGAY TRONG app —
///   KaraokeMaker.app/Contents/Resources/AutoLyricsRuntime/{python/, site-packages/, hf_cache/}
/// Máy khách KHÔNG cần cài Python / Homebrew / PyTorch / qwen-asr / cache Hugging Face / Terminal / Internet.
/// Các đường dẫn dựng thử (`~/qwen3_asr_*`, biến môi trường, UserDefaults) CHỈ tồn tại trong bản dev/test
/// (cờ biên dịch DEBUG hoặc KM_DEV_RUNTIME) — bản phát hành không chứa chúng.
struct AutoLyricsRuntime: Equatable {
    let hardware: AutoLyricsHardware
    let python: URL
    let hfHome: URL
    let helperScript: URL
    /// Thư mục site-packages đi kèm (bản đóng gói); nil = dùng venv có sẵn (bản dev).
    var sitePackages: URL? = nil

    /// Thư mục runtime đóng gói trong app.
    static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("AutoLyricsRuntime", isDirectory: true)
    }

    private struct Candidate { let python: String; let hf: String; let site: String? }

    private static func candidates(for hw: AutoLyricsHardware) -> [Candidate] {
        var list: [Candidate] = []
        // 1) Bản đóng gói trong app (đường DUY NHẤT của bản phát hành).
        if let root = bundledRoot {
            for exe in ["python/bin/python3", "python/bin/python3.11"] {
                list.append(Candidate(python: root.appendingPathComponent(exe).path,
                                      hf: root.appendingPathComponent("hf_cache").path,
                                      site: root.appendingPathComponent("site-packages").path))
            }
        }
        #if DEBUG || KM_DEV_RUNTIME
        let home = NSHomeDirectory()
        let env = ProcessInfo.processInfo.environment
        let devRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KaraokeMaker/AutoLyricsRuntime", isDirectory: true)
        if let py = env["KM_AUTOLYRICS_PYTHON"] { list.append(Candidate(python: py, hf: env["KM_AUTOLYRICS_HF_HOME"] ?? devRoot.appendingPathComponent("hf_cache").path, site: nil)) }
        switch hw {   // các bộ chạy đã dựng khi thử nghiệm (chỉ máy dev)
        case .intel: list.append(Candidate(python: home + "/qwen3_asr_intel_test/venv_qwenasr/bin/python", hf: home + "/qwen3_asr_intel_test/hf_cache", site: nil))
        case .appleSilicon: list.append(Candidate(python: home + "/qwen3_asr_m4_test/venv_official/bin/python", hf: home + "/qwen3_asr_m4_test/hf_cache", site: nil))
        }
        #endif
        return list
    }

    /// Thư mục helper: gói tài nguyên của app (bản dev còn cho phép ghi đè bằng biến môi trường).
    static func locateHelperDir() -> URL? {
        let fm = FileManager.default
        #if DEBUG || KM_DEV_RUNTIME
        if let p = ProcessInfo.processInfo.environment["KM_AUTOLYRICS_HELPER"] {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            if fm.fileExists(atPath: u.appendingPathComponent("lyric_asr_helper.py").path) { return u }
        }
        #endif
        if let u = KMBundle.url(forResource: "lyric_asr", withExtension: ""),
           fm.fileExists(atPath: u.appendingPathComponent("lyric_asr_helper.py").path) { return u }
        return nil
    }

    static func locate(hardware: AutoLyricsHardware = .current) throws -> AutoLyricsRuntime {
        let fm = FileManager.default
        guard let dir = locateHelperDir() else {
            throw AutoLyricsError.runtimeMissing(L("Không thấy helper nhận dạng lời trong app."))
        }
        for c in candidates(for: hardware) {
            guard fm.isExecutableFile(atPath: c.python) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: c.hf, isDirectory: &isDir), isDir.boolValue else { continue }
            if let site = c.site { guard fm.fileExists(atPath: site, isDirectory: &isDir), isDir.boolValue else { continue } }
            return AutoLyricsRuntime(hardware: hardware, python: URL(fileURLWithPath: c.python),
                                     hfHome: URL(fileURLWithPath: c.hf, isDirectory: true),
                                     helperScript: dir.appendingPathComponent("lyric_asr_helper.py"),
                                     sitePackages: c.site.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
        #if DEBUG || KM_DEV_RUNTIME
        throw AutoLyricsError.runtimeMissing(String(format: L("Đã tìm: %@"), candidates(for: hardware).map(\.python).joined(separator: ", ")))
        #else
        throw AutoLyricsError.runtimeMissing(L("Bộ nhận dạng lời trong app bị thiếu hoặc hỏng. Hãy cài lại KaraokeMaker."))
        #endif
    }

    /// Lệnh chạy: trên Apple Silicon ép chạy bản arm64 gốc (kể cả khi app đang chạy qua Rosetta) để có MPS.
    func launch(arguments: [String]) -> (executable: URL, arguments: [String]) {
        var args = [python.path, helperScript.path] + arguments
        if hardware == .appleSilicon {
            args.insert("-arm64", at: 0)
            return (URL(fileURLWithPath: "/usr/bin/arch"), args)
        }
        return (python, Array(args.dropFirst()))
    }

    /// Môi trường cho tiến trình con: SẠCH (không thừa hưởng biến Python/HF/torch của máy), không ghi bytecode vào gói app,
    /// không tải gì từ mạng.
    func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("PYTHON") || k.hasPrefix("HF_") || k.hasPrefix("TRANSFORMERS_")
            || k.hasPrefix("TORCH_") || k.hasPrefix("DYLD_") || k.hasPrefix("CONDA") || k == "VIRTUAL_ENV" || k.hasPrefix("PIP_") {
            env.removeValue(forKey: k)
        }
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        if let site = sitePackages { env["PYTHONPATH"] = site.path }
        env["HF_HOME"] = hfHome.path
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        return env
    }

    /// Đọc trạng thái bộ chạy bằng `helper --probe` (torch / qwen-asr / mô hình / MPS). Không nhận dạng gì cả.
    func probe(timeout: TimeInterval = 120) async -> [String: Any]? {
        await withCheckedContinuation { cont in
            let p = Process()
            let l = launch(arguments: ["--probe", "--device", hardware.device, "--hf-home", hfHome.path])
            p.executableURL = l.executable; p.arguments = l.arguments; p.environment = environment()
            let out = Pipe(), inp = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = inp
            final class Once: @unchecked Sendable { let l = NSLock(); var done = false }
            let once = Once()
            let finish: @Sendable ([String: Any]?) -> Void = { v in once.l.lock(); defer { once.l.unlock() }; if !once.done { once.done = true; cont.resume(returning: v) } }
            p.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                _ = inp
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    if let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["event"] as? String == "probe" {
                        finish(o); return
                    }
                }
                finish(nil)
            }
            do { try p.run() } catch { finish(nil); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
    }
}
