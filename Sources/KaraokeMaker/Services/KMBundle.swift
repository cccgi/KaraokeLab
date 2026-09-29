import Foundation

/// Tìm gói tài nguyên (model `.onnx`, icon người hát) **KHÔNG dùng `Bundle.module`**.
///
/// `Bundle.module` (do SwiftPM sinh ra) sẽ `fatalError` — VĂNG APP — khi không dò được
/// đường dẫn, chuyện hay xảy ra khi copy `.app` sang máy khác: macOS chạy app ở chế độ
/// "cách ly" (App Translocation) từ một thư mục tạm chỉ-đọc, hoặc chạy qua Rosetta trên
/// máy Apple Silicon. Ở đó các đường dẫn ứng viên của `Bundle.module` không khớp.
///
/// `KMBundle` thử nhiều vị trí thật + kiểm tra file tồn tại, và KHÔNG BAO GIỜ crash:
/// bí quá thì trả `nil` để nơi gọi báo lỗi tử tế.
enum KMBundle {

    private static let bundleName = "KaraokeMaker_KaraokeMaker"

    /// Các thư mục có thể chứa gói tài nguyên (hoặc chứa file rời).
    private static var searchDirs: [URL] {
        let fm = FileManager.default
        let app = Bundle.main.bundleURL
        var dirs: [URL] = []

        func add(_ u: URL?) { if let u { dirs.append(u) } }

        // Gói con: <base>/KaraokeMaker_KaraokeMaker.bundle
        let bases: [URL?] = [
            Bundle.main.resourceURL,
            app.appendingPathComponent("Contents/Resources"),
            app.appendingPathComponent("Contents/MacOS"),
            app,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "/").deletingLastPathComponent()
        ]
        for b in bases {
            guard let b else { continue }
            let sub = b.appendingPathComponent(bundleName + ".bundle")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue {
                dirs.append(sub)
            }
        }
        // File rời ngay trong Resources / cạnh binary (phòng khi build không gói bundle).
        add(Bundle.main.resourceURL)
        add(app.appendingPathComponent("Contents/Resources"))
        add(Bundle.main.executableURL?.deletingLastPathComponent())

        return dirs
    }

    /// Trả URL của tài nguyên, hoặc `nil` nếu không thấy ở đâu cả.
    static func url(forResource res: String, withExtension ext: String) -> URL? {
        let file = ext.isEmpty ? res : "\(res).\(ext)"
        let fm = FileManager.default
        for dir in searchDirs {
            let candidate = dir.appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Cuối cùng: nhờ CFBundle của bundle chính (trường hợp tài nguyên đã "phẳng" vào đó).
        return Bundle.main.url(forResource: res, withExtension: ext)
    }
}
