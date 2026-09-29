import Foundation

/// Nền hình cho Preview + khi xuất video (Mode C).
/// C1: ảnh tĩnh. C2 (sau): video.
struct BackgroundMedia: Equatable {
    /// `audio` / `text` chỉ dùng cho `OverlayClip` (clip tiếng / lớp chữ trên làn lớp đè) — nền không dùng.
    enum Kind: String, Codable { case image, video, audio, text }

    var kind: Kind = .image
    var lastKnownPath: String = ""
    var bookmark: Data?
    var fileName: String = ""

    /// Phóng to so với mức "phủ kín khung" (aspect-fill). 1 = vừa kín, >1 phóng to.
    var scale: Double = 1.0
    /// Lệch tâm theo tỉ lệ bề rộng / chiều cao khung (-1…1).
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Độ mờ khi vẽ (0…1).
    var opacity: Double = 1.0

    /// Có ghép nền này vào file video khi xuất không (xuất ra .mov nền đục).
    var includeInExport: Bool = true

    /// Chỉnh màu ảnh nền (sáng/tương phản/bão hoà/ấm/tối góc).
    var colorAdjust: ColorAdjust = ColorAdjust()
    /// Ken Burns: tự phóng/lia CHẬM suốt bài cho nền đỡ "chết".
    var kenBurns: Bool = false
    /// Mức phóng thêm khi Ken Burns (0.12 = to dần 12% suốt bài).
    var kenBurnsAmount: Double = 0.12
    /// Lấp 2 bên bằng chính ảnh làm mờ khi ảnh không đúng tỉ lệ khung (thay vì phủ kín cắt cúp).
    var blurFill: Bool = false
    /// Nền tự PHÓNG TO nhẹ theo năng lượng nhạc (điều khiển từ tab "Sóng nhạc") — "thở" theo nhịp.
    var beatZoomEnabled: Bool = false
    /// Phóng thêm tối đa lúc nhạc to nhất (1.15 / 1.25 / 1.5 — chọn trong UI).
    var beatZoomAmount: Double = 1.15

    init(kind: Kind = .image, url: URL) {
        self.kind = kind
        self.lastKnownPath = url.path
        self.fileName = url.lastPathComponent
        self.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    init() {}

    /// Tìm lại file thật trên đĩa: ưu tiên bookmark, rồi đường dẫn cũ.
    func resolveURL() -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: lastKnownPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}

// MARK: - Codable "khoan dung"

extension BackgroundMedia: Codable {
    enum CodingKeys: String, CodingKey {
        case kind, lastKnownPath, bookmark, fileName, scale, offsetX, offsetY, opacity, includeInExport
        case colorAdjust, kenBurns, kenBurnsAmount, blurFill, beatZoomEnabled, beatZoomAmount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        kind            = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? kind
        lastKnownPath   = try c.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? lastKnownPath
        bookmark        = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        fileName        = try c.decodeIfPresent(String.self, forKey: .fileName) ?? fileName
        scale           = try c.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        offsetX         = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? offsetX
        offsetY         = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? offsetY
        opacity         = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        includeInExport = try c.decodeIfPresent(Bool.self, forKey: .includeInExport) ?? includeInExport
        colorAdjust     = try c.decodeIfPresent(ColorAdjust.self, forKey: .colorAdjust) ?? colorAdjust
        kenBurns        = try c.decodeIfPresent(Bool.self, forKey: .kenBurns) ?? kenBurns
        kenBurnsAmount  = try c.decodeIfPresent(Double.self, forKey: .kenBurnsAmount) ?? kenBurnsAmount
        blurFill        = try c.decodeIfPresent(Bool.self, forKey: .blurFill) ?? blurFill
        beatZoomEnabled = try c.decodeIfPresent(Bool.self, forKey: .beatZoomEnabled) ?? beatZoomEnabled
        beatZoomAmount  = try c.decodeIfPresent(Double.self, forKey: .beatZoomAmount) ?? beatZoomAmount
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(lastKnownPath, forKey: .lastKnownPath)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(scale, forKey: .scale)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(includeInExport, forKey: .includeInExport)
        try c.encode(colorAdjust, forKey: .colorAdjust)
        try c.encode(kenBurns, forKey: .kenBurns)
        try c.encode(kenBurnsAmount, forKey: .kenBurnsAmount)
        try c.encode(blurFill, forKey: .blurFill)
        try c.encode(beatZoomEnabled, forKey: .beatZoomEnabled)
        try c.encode(beatZoomAmount, forKey: .beatZoomAmount)
    }
}

// MARK: - Toán vẽ dùng chung Preview + Export

enum BackgroundMediaLayout {
    /// Chữ nhật đích để vẽ ảnh trong khung `canvas`, theo kiểu aspect-fill + scale + offset.
    /// `imageSize` là kích thước pixel thật của ảnh.
    static func destRect(imageSize: CGSize, canvas: CGSize, scale: Double, offsetX: Double, offsetY: Double) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else {
            return CGRect(origin: .zero, size: canvas)
        }
        let fill = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let s = fill * CGFloat(max(0.05, scale))
        let w = imageSize.width * s
        let h = imageSize.height * s
        let cx = canvas.width / 2 + CGFloat(offsetX) * canvas.width
        let cy = canvas.height / 2 + CGFloat(offsetY) * canvas.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}
