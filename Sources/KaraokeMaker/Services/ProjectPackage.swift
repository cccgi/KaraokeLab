import Foundation

/// (2026-09-13) Project `.kbproj` là **1 FILE ZIP THẬT** — KHÔNG PHẢI thư mục (bản đầu tiên
/// trong ngày dùng thư mục trần, user phản hồi ngay "tôi cần nén vào 1 file" — sửa lại đây).
/// Bên trong file zip: `project.json` (JSON như trước) + thư mục `Media/` chứa audio / vocal-beat
/// đã tách / nền / ảnh / video COPY THẲNG vào. Người dùng chỉ thấy ĐÚNG 1 file trên đĩa — copy /
/// AirDrop / đổi tên như file bình thường.
///
/// Sửa project = giải nén ra 1 thư mục "staging" RIÊNG cho project đó (theo đường dẫn, dưới
/// `~/Library/Caches/KaraokeMaker/ProjectStaging/`), sửa/ghi trong thư mục đó, xong NÉN LẠI thành
/// đúng 1 file `.kbproj` (ghi ra file tạm rồi thay thế, không hỏng file cũ nếu lỡ crash giữa
/// chừng). Thư mục staging giữ lại giữa các lần mở/lưu (đánh dấu bằng mtime+size của chính file
/// zip) để không phải giải nén lại từ đầu mỗi lần.
///
/// Đọc/ghi qua `/usr/bin/zip` + `/usr/bin/unzip` (có sẵn trên mọi máy macOS; app không sandbox
/// nên gọi `Process` thoải mái) — Foundation không có API đọc/ghi zip built-in.
///
/// Project CŨ (1 file JSON đơn, media chỉ lưu đường dẫn + security-scoped bookmark) vẫn MỞ được
/// bình thường — chỉ khi LƯU LẠI mới chuyển hẳn sang file zip mới.
enum ProjectPackage {
    static let mediaSubdir = "Media"
    static let jsonFileName = "project.json"

    // MARK: - Nhận diện định dạng

    /// File tại `url` có phải zip THẬT không (đọc 4 byte đầu — chữ ký "PK\x03\x04", hoặc
    /// "PK\x05\x06" cho zip rỗng). Không phải zip → coi là file JSON đơn (định dạng cũ nhất).
    static func isZipPackage(_ url: URL) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 4), head.count == 4 else { return false }
        return head == Data([0x50, 0x4B, 0x03, 0x04]) || head == Data([0x50, 0x4B, 0x05, 0x06])
    }

    /// `.kbproj` là 1 THƯ MỤC TRẦN (định dạng "gói" tạm dùng buổi sáng 2026-09-13, đã bỏ ngay
    /// trong ngày) — vẫn nhận ra để KHÔNG làm mất project đã lỡ lưu bằng bản đó.
    static func isLooseDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func jsonURL(inLocalDir dir: URL) -> URL { dir.appendingPathComponent(jsonFileName) }
    static func mediaDir(for dir: URL) -> URL { dir.appendingPathComponent(mediaSubdir, isDirectory: true) }

    static func name(_ base: String, ext: String) -> String {
        ext.isEmpty ? base : "\(base).\(ext)"
    }

    // MARK: - Thư mục "staging" (giải nén tạm, RIÊNG cho từng project theo đường dẫn)

    private static let stagingRoot: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KaraokeMaker/ProjectStaging", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Thư mục staging cho project tại `url` — khoá theo đường dẫn ĐÃ CHUẨN HOÁ (đổi tên/di
    /// chuyển file thì coi như "project khác", tự giải nén lại từ đầu — an toàn dù chậm hơn 1 lần).
    static func staging(for url: URL) -> URL {
        var safe = url.standardizedFileURL.path
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if safe.count > 180 { safe = String(safe.suffix(180)) }
        return stagingRoot.appendingPathComponent(safe, isDirectory: true)
    }

    private static func markerURL(for staging: URL) -> URL { staging.appendingPathComponent(".source-marker") }

    private static func sourceMarker(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)|\(mtime)"
    }

    // MARK: - Giải nén (mở) / nén lại (lưu)

    /// Giải nén `url` (.kbproj zip) ra thư mục staging riêng cho project này — TÁI DÙNG nếu đã
    /// giải nén đúng bản này rồi (so khớp mtime+size của chính file zip), không thì xoá giải nén
    /// lại từ đầu. Trả `nil` nếu unzip lỗi (file hỏng…).
    static func extract(_ url: URL) -> URL? {
        let dir = staging(for: url)
        let marker = markerURL(for: dir)
        let want = sourceMarker(for: url)
        if let have = try? String(contentsOf: marker, encoding: .utf8), have == want,
           FileManager.default.fileExists(atPath: jsonURL(inLocalDir: dir).path) {
            return dir
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-oq", url.path, "-d", dir.path]
        do {
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
        } catch { return nil }
        try? want.write(to: marker, atomically: true, encoding: .utf8)
        return dir
    }

    /// Nén thư mục staging (đã ghi `project.json` + `Media/` mới) thành đúng 1 file `.kbproj` tại
    /// `url` — ghi ra file TẠM rồi thay vào (crash giữa chừng không hỏng file cũ đang có).
    @discardableResult
    static func compress(staging dir: URL, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: tmp)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -r đệ quy, -q im lặng, -0 KHÔNG nén thêm (audio/video đã nén sẵn — nén lại chỉ tốn thời
        // gian mỗi lần lưu mà gần như không giảm dung lượng), -X bỏ metadata không cần.
        p.arguments = ["-rq0X", tmp.path, jsonFileName, mediaSubdir]
        p.currentDirectoryURL = dir
        do {
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp.path) else {
                try? FileManager.default.removeItem(at: tmp); return false
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try FileManager.default.moveItem(at: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp); return false
        }
        try? sourceMarker(for: url).write(to: markerURL(for: dir), atomically: true, encoding: .utf8)
        return true
    }

    /// Đọc riêng 1 mục `project.json` NGAY TRONG zip, không giải nén cả file — dùng cho danh sách
    /// thư viện Home (nhanh, không cần giải nén hết media chỉ để đọc vài trường hiện thẻ).
    static func readJSONEntry(from url: URL) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, jsonFileName]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 && !data.isEmpty ? data : nil
        } catch {
            return nil
        }
    }

    // MARK: - Copy media vào staging lúc lưu

    /// Copy `source` vào `mediaDir/preferredName` — bỏ qua nếu ĐÃ CÓ và cùng kích thước (khớp
    /// nhau coi như đã copy rồi, tránh copy lại video/nhạc nặng mỗi lần lưu). Trả `nil` nếu copy
    /// lỗi (đĩa đầy, không đọc được nguồn…) — bên gọi tự bỏ qua êm, không chặn lưu project.
    @discardableResult
    static func materialize(source: URL, into mediaDir: URL, preferredName: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        let dest = mediaDir.appendingPathComponent(preferredName)
        // Nguồn CHÍNH LÀ đích (đã copy vào staging từ lần lưu TRƯỚC, `resolveURL()` giờ trỏ
        // thẳng vào đây) → khỏi copy lại, tránh `copyItem` báo lỗi "trùng đường dẫn".
        if source.standardizedFileURL.path == dest.standardizedFileURL.path { return dest }
        if fm.fileExists(atPath: dest.path) {
            let a = try? fm.attributesOfItem(atPath: source.path)
            let b = try? fm.attributesOfItem(atPath: dest.path)
            let sameSize = (a?[.size] as? Int64 ?? -1) == (b?[.size] as? Int64 ?? -2)
            if sameSize { return dest }   // coi như đã copy đúng bản rồi
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.copyItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
