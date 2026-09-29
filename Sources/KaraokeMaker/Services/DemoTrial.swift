import Foundation

/// Giới hạn bản DÙNG THỬ — CHỈ có hiệu lực khi build với cờ biên dịch `DEMO_BUILD`
/// (`swift build -Xswiftc -DDEMO_BUILD`, dùng qua `Scripts/pack-local.sh --demo`).
/// Bản build BÌNH THƯỜNG (không cờ này) — tức app bạn tự dùng hằng ngày — KHÔNG bao giờ
/// bị giới hạn, dù có file đánh dấu hay không.
///
/// Cách tính: đếm từ LẦN MỞ ĐẦU TIÊN trên máy người tải (không phải 1 ngày cố định) —
/// ai tải về cũng có đủ trọn số ngày dùng thử, không bị thiệt vì tải trễ.
///
/// LƯU Ý THẬT: đây là khoá NHẸ (đủ chặn người dùng thường), không phải khoá chống bẻ khoá
/// — người rành kỹ thuật vẫn xoá được file đánh dấu để reset. Không dùng cho mục đích cần
/// bảo mật cao.
enum DemoTrial {
    static let trialDays = 30

    private struct Marker: Codable { var firstLaunch: Date }

    private static var markerURL: URL {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("KaraokeMaker", isDirectory: true)
        return base.appendingPathComponent(".trial")
    }

    /// Số ngày CÒN LẠI của bản dùng thử. `nil` = build này không giới hạn (bản thường).
    static var daysRemaining: Int? {
        #if DEMO_BUILD
        let elapsed = Date().timeIntervalSince(marker().firstLaunch)
        return trialDays - Int(elapsed / 86_400)
        #else
        return nil
        #endif
    }

    static var isExpired: Bool { (daysRemaining ?? 1) <= 0 }

    #if DEMO_BUILD
    private static func marker() -> Marker {
        let fm = FileManager.default
        let dir = markerURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: markerURL),
           let m = try? decoder.decode(Marker.self, from: data) {
            return m
        }
        let m = Marker(firstLaunch: Date())
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(m) {
            try? data.write(to: markerURL, options: .atomic)
            var url = markerURL
            var flags = URLResourceValues(); flags.isHidden = true
            try? url.setResourceValues(flags)
        }
        return m
    }
    #endif
}
