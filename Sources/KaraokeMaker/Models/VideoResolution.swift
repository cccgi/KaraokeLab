import Foundation

/// Kích thước và tốc độ khung hình của video xuất ra.
/// KHÔNG khóa cứng — sau này thêm 4K, 9:16, 1:1, custom chỉ là đổi giá trị.
struct VideoResolution: Codable, Equatable, Hashable {
    var width: Int
    var height: Int
    var fps: Double

    init(width: Int, height: Int, fps: Double = 30) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// Mặc định: Full HD 16:9 cho YouTube.
    static let hd1080p = VideoResolution(width: 1920, height: 1080, fps: 30)

    /// Vài preset để sau này đưa vào menu chọn.
    static let presets: [(name: String, value: VideoResolution)] = [
        ("720p (16:9)",  VideoResolution(width: 1280, height: 720,  fps: 30)),
        ("1080p (16:9)", VideoResolution(width: 1920, height: 1080, fps: 30)),
        ("2K (16:9)",    VideoResolution(width: 2560, height: 1440, fps: 30)),
        ("4K (16:9)",    VideoResolution(width: 3840, height: 2160, fps: 30)),
        ("1080x1920 (9:16)", VideoResolution(width: 1080, height: 1920, fps: 30)),
        ("1080x1080 (1:1)",  VideoResolution(width: 1080, height: 1080, fps: 30)),
    ]

    /// 4 tỉ lệ khung xuất (DESIGN_SYSTEM §16) — mỗi tỉ lệ có vài độ phân giải; chọn tỉ lệ = lấy cỡ mặc định của tỉ lệ đó.
    enum Aspect: String, CaseIterable, Identifiable {
        case r16x9 = "16:9", r9x16 = "9:16", r1x1 = "1:1", r12x16 = "12:16"
        var id: String { rawValue }
        var sizes: [(name: String, width: Int, height: Int)] {
            switch self {
            case .r16x9:  return [("720p", 1280, 720), ("1080p", 1920, 1080), ("2K", 2560, 1440), ("4K", 3840, 2160)]
            case .r9x16:  return [("720 × 1280", 720, 1280), ("1080 × 1920", 1080, 1920)]
            case .r1x1:   return [("720 × 720", 720, 720), ("1080 × 1080", 1080, 1080)]
            case .r12x16: return [("810 × 1080", 810, 1080), ("1080 × 1440", 1080, 1440)]
            }
        }
        /// Cỡ mặc định khi bấm chọn tỉ lệ: 1080p cho 16:9, bản rộng 1080 cho các tỉ lệ dọc / vuông.
        var defaultIndex: Int { self == .r16x9 ? 1 : sizes.count - 1 }
    }

    /// Tỉ lệ khớp CHÍNH XÁC (nil = kích thước tuỳ chỉnh).
    var aspect: Aspect? {
        guard width > 0, height > 0 else { return nil }
        if width * 9 == height * 16 { return .r16x9 }
        if width * 16 == height * 9 { return .r9x16 }
        if width == height { return .r1x1 }
        if width * 16 == height * 12 { return .r12x16 }
        return nil
    }

    var aspectLabel: String {
        guard height > 0 else { return "-" }
        let g = gcd(width, height)
        return "\(width / g):\(height / g)"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }
}
