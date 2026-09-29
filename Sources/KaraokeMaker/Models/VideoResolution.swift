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
