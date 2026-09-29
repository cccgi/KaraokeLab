import Foundation

/// (U1) Thư viện project — quét thư mục mặc định `~/Movies/KaraokeMaker Projects`,
/// đọc metadata NHẸ của từng file `.kbproj` để vẽ lưới ở màn hình Home.
///
/// Project MỞ TỪ NƠI KHÁC (nút "Mở project khác…", hay project cũ user đã lưu rải
/// rác trước đây) KHÔNG bắt buộc phải nằm trong thư mục này — thư viện chỉ là nơi
/// project MỚI mặc định được lưu vào, không phải nơi duy nhất được phép mở.
enum ProjectLibrary {
    static let folderName = "KaraokeMaker Projects"

    static var rootURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent(folderName, isDirectory: true)
    }
    static var trashURL: URL { rootURL.appendingPathComponent(".trash", isDirectory: true) }
    static var thumbsURL: URL { rootURL.appendingPathComponent(".thumbnails", isDirectory: true) }

    @discardableResult
    static func ensureFolders() -> Bool {
        let fm = FileManager.default
        for url in [rootURL, trashURL, thumbsURL] {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return fm.fileExists(atPath: rootURL.path)
    }

    struct Entry: Identifiable, Equatable {
        var id: String { url.path }
        var url: URL
        var name: String
        var modifiedAt: Date
        var duration: TimeInterval?
        var fileSize: Int64
        /// Ảnh xem trước — U2 sẽ điền thật; giờ luôn `nil` (HomeView tự vẽ khung giữ chỗ).
        var thumbnailURL: URL?
        /// Project nằm NGOÀI thư mục thư viện (chỉ có trong "Gần đây").
        var isExternal: Bool = false
    }

    /// Đọc 1 file `.kbproj` bất kỳ thành `Entry` (dùng cho danh sách "Gần đây").
    static func entry(for url: URL, isExternal: Bool = false) -> Entry? {
        guard var e = readEntry(url) else { return nil }
        e.isExternal = isExternal
        return e
    }

    /// Thư viện + "Gần đây" (project mở/lưu từ nơi khác), gộp & bỏ trùng, mới nhất trước.
    static func listAll() -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for e in listProjects() where seen.insert(e.url.standardizedFileURL.path).inserted {
            out.append(e)
        }
        for url in RecentProjects.externalURLs() where seen.insert(url.standardizedFileURL.path).inserted {
            if let e = entry(for: url, isExternal: true) { out.append(e) }
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Đọc NHẸ 1 file .kbproj thành `Entry` (giải mã cả project — chỉ lấy vài trường cần vẽ thẻ).
    /// `.kbproj` là 1 file ZIP THẬT (mang theo media) — đọc riêng mục `project.json` trong zip,
    /// KHÔNG cần giải nén cả file chỉ để vẽ 1 thẻ. File JSON đơn (cũ) / thư mục trần (bản tạm
    /// sáng 2026-09-13) vẫn nhận ra được.
    private static func readEntry(_ url: URL) -> Entry? {
        let data: Data?
        if ProjectPackage.isZipPackage(url) {
            data = ProjectPackage.readJSONEntry(from: url)
        } else if ProjectPackage.isLooseDirectory(url) {
            data = try? Data(contentsOf: ProjectPackage.jsonURL(inLocalDir: url))
        } else {
            data = try? Data(contentsOf: url)
        }
        guard let data else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let proj = try? decoder.decode(KaraokeProject.self, from: data) else { return nil }
        // Zip / file JSON đơn: `attributesOfItem` đã đúng (1 file thật). Chỉ thư mục trần (bản
        // tạm) mới cần cộng dồn đệ quy.
        let size: Int64
        if ProjectPackage.isLooseDirectory(url) {
            size = folderSize(url)
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        let thumb = thumbsURL.appendingPathComponent(thumbnailFileName(for: url))
        return Entry(url: url, name: proj.name.isEmpty ? url.deletingPathExtension().lastPathComponent : proj.name,
                     modifiedAt: proj.modifiedAt, duration: proj.audio?.duration, fileSize: size,
                     thumbnailURL: FileManager.default.fileExists(atPath: thumb.path) ? thumb : nil)
    }

    /// Tổng dung lượng 1 thư mục (đệ quy) — project dạng GÓI mang cả media theo nên
    /// `attributesOfItem` (chỉ báo kích thước riêng thư mục, không đệ quy) là sai số.
    private static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                    options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let s = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
        }
        return total
    }

    /// "v2" (2026-09-12): thumbnail CŨ bị lộn ngược (bug lật trục ở `ThumbnailRenderer`, đã sửa)
    /// — đổi tên file để KHÔNG bao giờ dùng nhầm ảnh cũ; project chưa có ảnh "v2" sẽ tự vẽ lại
    /// (xem `regenerateMissingThumbnails`).
    private static func thumbnailFileName(for projectURL: URL) -> String {
        projectURL.deletingPathExtension().lastPathComponent + ".v2.png"
    }

    /// Ảnh xem trước cho 1 project — dùng ở U2 (`ThumbnailRenderer` sẽ ghi vào đây).
    static func thumbnailURL(for projectURL: URL) -> URL {
        ensureFolders()
        return thumbsURL.appendingPathComponent(thumbnailFileName(for: projectURL))
    }

    /// Project nào đã cố vẽ lại thumbnail trong PHIÊN NÀY rồi thì thôi — tránh vẽ lại vô hạn
    /// nếu media nền bị mất/hỏng khiến `ThumbnailRenderer` luôn thất bại êm.
    private static var thumbRegenAttempted: Set<String> = []

    /// Vẽ lại thumbnail cho các project CHƯA có ảnh "v2" (project cũ trước bản vá lật ngược,
    /// hoặc project thật sự chưa từng có ảnh) — chạy NỀN, gọi `onProgress` (main thread) khi
    /// xong 1 đợt để bên gọi tự `reload()` lấy ảnh mới.
    static func regenerateMissingThumbnails(_ entries: [Entry], onProgress: @escaping () -> Void) {
        let missing = entries.filter { $0.thumbnailURL == nil && !thumbRegenAttempted.contains($0.url.path) }
        guard !missing.isEmpty else { return }
        for e in missing { thumbRegenAttempted.insert(e.url.path) }
        DispatchQueue.global(qos: .utility).async {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            for e in missing {
                // Zip THẬT → phải giải nén (staging) mới có file media THẬT trên đĩa để vẽ nền;
                // đọc thẳng `project.json` bằng `readJSONEntry` (không giải nén) là KHÔNG đủ ở đây.
                var localDir: URL?
                let jsonURL: URL
                if ProjectPackage.isZipPackage(e.url) {
                    guard let dir = ProjectPackage.extract(e.url) else { continue }
                    localDir = dir; jsonURL = ProjectPackage.jsonURL(inLocalDir: dir)
                } else if ProjectPackage.isLooseDirectory(e.url) {
                    localDir = e.url; jsonURL = ProjectPackage.jsonURL(inLocalDir: e.url)
                } else {
                    jsonURL = e.url
                }
                guard let data = try? Data(contentsOf: jsonURL),
                      var proj = try? decoder.decode(KaraokeProject.self, from: data) else { continue }
                if let localDir { proj.rehomeMediaIfNeeded(inPackage: localDir) }
                ThumbnailRenderer.generate(for: proj, projectURL: e.url)
            }
            DispatchQueue.main.async { onProgress() }
        }
    }

    private static func list(in folder: URL) -> [Entry] {
        ensureFolders()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { $0.pathExtension.lowercased() == ProjectStore.fileExtension }
            .compactMap(readEntry)
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func listProjects() -> [Entry] { list(in: rootURL) }
    static func listTrash() -> [Entry] { list(in: trashURL) }

    /// Đường dẫn file MỚI, chưa tồn tại, cho project vừa "Tạo" — tự đặt tên tránh trùng.
    static func newProjectURL(suggestedName: String = "Dự án mới") -> URL {
        ensureFolders()
        let fm = FileManager.default
        let base = suggestedName.trimmingCharacters(in: .whitespaces).isEmpty ? "Dự án mới" : suggestedName
        var candidate = rootURL.appendingPathComponent("\(base).\(ProjectStore.fileExtension)")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(base) \(n).\(ProjectStore.fileExtension)")
            n += 1
        }
        return candidate
    }

    /// Xoá MỀM: chuyển file (+ thumbnail nếu có) vào `.trash`. Khôi phục được bằng `restore`.
    static func moveToTrash(_ url: URL) {
        ensureFolders()
        let fm = FileManager.default
        let dest = trashURL.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)                       // dọn trùng tên cũ trong thùng rác
        try? fm.moveItem(at: url, to: dest)
        let thumb = thumbsURL.appendingPathComponent(thumbnailFileName(for: url))
        if fm.fileExists(atPath: thumb.path) {
            let thumbDest = trashURL.appendingPathComponent(".thumb-" + thumbnailFileName(for: url))
            try? fm.removeItem(at: thumbDest)
            try? fm.moveItem(at: thumb, to: thumbDest)
        }
    }

    /// Khôi phục 1 project từ thùng rác về thư viện.
    static func restore(_ url: URL) {
        ensureFolders()
        let fm = FileManager.default
        var dest = rootURL.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            let name = url.deletingPathExtension().lastPathComponent
            dest = newProjectURL(suggestedName: name + " (khôi phục)")
        }
        try? fm.moveItem(at: url, to: dest)
        let thumbSrc = trashURL.appendingPathComponent(".thumb-" + thumbnailFileName(for: url))
        if fm.fileExists(atPath: thumbSrc.path) {
            try? fm.moveItem(at: thumbSrc, to: thumbsURL.appendingPathComponent(thumbnailFileName(for: dest)))
        }
    }

    /// Xoá VĨNH VIỄN — chỉ gọi khi CHÍNH NGƯỜI DÙNG bấm "Xoá vĩnh viễn" trong Thùng rác.
    static func deleteForever(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        let thumb = trashURL.appendingPathComponent(".thumb-" + thumbnailFileName(for: url))
        try? FileManager.default.removeItem(at: thumb)
    }
}
