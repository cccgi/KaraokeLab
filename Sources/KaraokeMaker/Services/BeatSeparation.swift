import Foundation

/// Tách nhạc TRONG MÁY (MDX-Net) — 1 lần ra cả `vocal` (canh mốc) lẫn `beat` (xuất video).
/// File tách xong lưu vào thư mục cache theo tên + kích thước file gốc nên lần sau mở lại
/// cùng bài KHÔNG phải tách lại.
///
/// Người dùng cũng có thể tự đưa sẵn beat + vocal đã tách (`adoptUserStems`) → khỏi chạy MDX.
@MainActor
final class BeatSeparation: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    /// Tiến độ tách nhạc TRONG MÁY (0…1). Chỉ dùng cho `separateLocal`.
    @Published private(set) var localProgress: Double = 0
    /// Có giá trị khi đã có file (từ cache hoặc vừa tách xong).
    @Published private(set) var beatURL: URL?
    @Published private(set) var vocalURL: URL?
    /// True khi đang dùng beat + vocal do NGƯỜI DÙNG đưa vào (bỏ qua tách MDX).
    @Published private(set) var usingUserStems = false

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KaraokeMaker/stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Chất lượng tách nhạc — khoá đệm riêng để 2 bản không đè nhau.
    enum Quality: String { case fast, hq
        var config: MDXSeparator.Config { self == .hq ? .hq : .fast }
    }

    private func cacheURL(for source: URL, kind: String, quality: Quality) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let safe = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return dir.appendingPathComponent("\(safe)-\(size)-\(kind)-\(quality.rawValue).wav")
    }

    /// Gọi khi đổi bài / mở lại dự án. Tìm beat/vocal đã cache (ưu tiên hq) — để mở lại project cũ
    /// vẫn BẬT/TẮT karaoke + xuất-với-beat được ngay mà không phải tách lại. (Việc "luôn tách MỚI"
    /// chỉ áp cho `separateLocal` — tức lúc bấm Tạo Karaoke.)
    func refresh(for source: URL?) {
        if usingUserStems { return }   // beat + vocal do người dùng đưa, giữ nguyên
        guard let source else { vocalURL = nil; beatURL = nil; status = ""; return }
        let fm = FileManager.default
        for q in [Quality.hq, .fast] {
            let v = cacheURL(for: source, kind: "vocal", quality: q)
            let b = cacheURL(for: source, kind: "beat", quality: q)
            if fm.fileExists(atPath: v.path), fm.fileExists(atPath: b.path) {
                vocalURL = v; beatURL = b; status = "✅ Sẵn sàng"; return
            }
        }
        vocalURL = nil; beatURL = nil; status = ""
    }

    /// (2026-09-13) Project GÓI mang sẵn vocal/beat đã tách (`KaraokeProject.vocalStem/beatStem`,
    /// xem `ProjectPackage`) — máy MỚI (chưa có cache tách nhạc riêng cho bài này) vẫn dùng được
    /// NGAY, khỏi tách lại từ đầu. Gọi TRƯỚC `refresh(for:)`: có đủ cả 2 file thật trên đĩa thì
    /// nhận luôn (không tính là "user stems" — `refresh`/`separateLocal` cho bài khác vẫn bình
    /// thường); thiếu 1 trong 2 thì để nguyên, `refresh(for:)` tự lo phần cache máy này.
    func adoptFromProject(vocal: URL?, beat: URL?) -> Bool {
        guard !usingUserStems, let vocal, let beat,
              FileManager.default.fileExists(atPath: vocal.path),
              FileManager.default.fileExists(atPath: beat.path) else { return false }
        vocalURL = vocal; beatURL = beat; status = "✅ Sẵn sàng"
        return true
    }

    /// TÁCH NHẠC TRONG MÁY (offline) — 1 lần ra CẢ vocal lẫn beat.
    /// LUÔN TÁCH MỚI mỗi lần (user chốt 2026-09-08): nhiều khi user sửa file audio nhưng giữ
    /// nguyên tên → dùng lại stem cũ = kết quả canh lời SAI. Chỉ bỏ qua MDX khi user tự đưa stem.
    func separateLocal(source: URL, quality: Quality = .fast) async -> (vocal: URL, beat: URL)? {
        guard !isRunning else { return nil }
        let fm = FileManager.default

        // Người dùng đã tự đưa beat + vocal → dùng luôn của họ, khỏi chạy MDX.
        if usingUserStems, let v = vocalURL, let b = beatURL,
           fm.fileExists(atPath: v.path), fm.fileExists(atPath: b.path) {
            status = "✅ Sẵn sàng"
            return (v, b)
        }

        let vURL = cacheURL(for: source, kind: "vocal", quality: quality)
        let bURL = cacheURL(for: source, kind: "beat", quality: quality)
        // Xoá stem cũ (nếu có) để tách lại từ đầu.
        try? fm.removeItem(at: vURL)
        try? fm.removeItem(at: bURL)

        isRunning = true
        localProgress = 0
        status = "Đang phân tích nhạc…"
        defer { isRunning = false }

        do {
            let cfg = quality.config
            let out = try await Task.detached(priority: .userInitiated) {
                let cb: @Sendable (Double) -> Void = { p in
                    Task { @MainActor [weak self] in self?.localProgress = p }
                }
                return try MDXSeparator.separate(source: source, vocalOut: vURL, accompOut: bURL, config: cfg, progress: cb)
            }.value
            vocalURL = out.vocalURL
            beatURL = out.accompURL
            localProgress = 1
            status = "✅ Xong"
            return (out.vocalURL, out.accompURL)
        } catch {
            status = "❌ Lỗi: \(error.localizedDescription)"
            return nil
        }
    }

    /// Người dùng tự đưa BEAT + VOCAL đã tách sẵn → app KHỎI chạy MDX.
    /// Trộn 2 file thành 1 bản nghe (để phát/preview), rồi copy beat/vocal vào ĐÚNG
    /// cache path của bản trộn đó → `separateLocal(source: mix)` sẽ tự dùng lại ngay.
    /// Trả URL bản trộn (dùng làm `project.audio`), hoặc `nil` nếu lỗi.
    func adoptUserStems(beat: URL, vocal: URL) async -> URL? {
        guard !isRunning else { return nil }
        isRunning = true
        status = "Đang xử lý…"
        defer { isRunning = false }

        let base = vocal.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let mixURL = dir.appendingPathComponent("\(base)-usermix.wav")

        do {
            try await Task.detached(priority: .userInitiated) {
                let (bl, br) = try LocalSeparator.readStereo44k(beat)
                let (vl, vr) = try LocalSeparator.readStereo44k(vocal)
                let n = max(bl.count, vl.count)
                var ml = [Float](repeating: 0, count: n)
                var mr = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let l = (i < bl.count ? bl[i] : 0) + (i < vl.count ? vl[i] : 0)
                    let r = (i < br.count ? br[i] : 0) + (i < vr.count ? vr[i] : 0)
                    ml[i] = max(-1, min(1, l)); mr[i] = max(-1, min(1, r))
                }
                try LocalSeparator.writeStereo44k(left: ml, right: mr, to: mixURL)
            }.value

            let fm = FileManager.default
            // Ghi vào cả 2 khoá chất lượng — người dùng bấm nút nào cũng dùng stem của họ.
            var vCache = mixURL, bCache = mixURL
            for q in [Quality.fast, .hq] {
                let vC = cacheURL(for: mixURL, kind: "vocal", quality: q)
                let bC = cacheURL(for: mixURL, kind: "beat", quality: q)
                try? fm.removeItem(at: vC); try fm.copyItem(at: vocal, to: vC)
                try? fm.removeItem(at: bC); try fm.copyItem(at: beat, to: bC)
                vCache = vC; bCache = bC
            }

            vocalURL = vCache
            beatURL = bCache
            usingUserStems = true
            status = "✅ Đã nhận beat + vocal của bạn."
            return mixURL
        } catch {
            status = "❌ Không đọc được beat/vocal: \(error.localizedDescription)"
            return nil
        }
    }

    /// Quay lại chế độ tách MDX bình thường.
    func clearUserStems() {
        usingUserStems = false
        vocalURL = nil
        beatURL = nil
        status = ""
    }
}
