import Foundation

/// Project MỞ / LƯU gần đây — để màn hình Home hiện được cả project nằm NGOÀI
/// thư mục thư viện (`~/Movies/KaraokeMaker Projects`), ví dụ `~/Downloads/bai.kbproj`.
///
/// App KHÔNG chạy sandbox (ký ad-hoc, không entitlements) nên mở lại đường dẫn cũ
/// không cần security-scoped bookmark — lưu path thô trong `UserDefaults` là đủ.
enum RecentProjects {
    private static let key = "recentProjectPaths.v1"
    private static let maxCount = 40

    static func paths() -> [String] {
        (UserDefaults.standard.array(forKey: key) as? [String]) ?? []
    }

    /// Ghi nhận 1 project vừa mở / lưu (đưa lên đầu danh sách).
    static func note(_ url: URL) {
        guard url.pathExtension.lowercased() == ProjectStore.fileExtension else { return }
        let p = url.standardizedFileURL.path
        var list = paths().filter { $0 != p }
        list.insert(p, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// Bỏ 1 project khỏi danh sách gần đây (không đụng tới file trên đĩa).
    static func forget(_ url: URL) {
        let p = url.standardizedFileURL.path
        UserDefaults.standard.set(paths().filter { $0 != p }, forKey: key)
    }

    /// Các URL gần đây CÒN trên đĩa và KHÔNG nằm trong thư mục thư viện
    /// (project trong thư viện đã do `ProjectLibrary.listProjects()` quét rồi).
    static func externalURLs() -> [URL] {
        let root = ProjectLibrary.rootURL.standardizedFileURL.path + "/"
        let fm = FileManager.default
        return paths().compactMap { p in
            guard fm.fileExists(atPath: p), !p.hasPrefix(root) else { return nil }
            return URL(fileURLWithPath: p)
        }
    }
}
