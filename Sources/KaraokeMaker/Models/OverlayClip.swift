import Foundation

/// Kiểu nội suy giữa 2 mốc (dùng đường cong của mốc ĐÍCH).
enum KFEase: String, Codable, CaseIterable {
    case linear, easeInOut, easeOut, bounce
    var label: String {
        switch self {
        case .linear: return L("Đều")
        case .easeInOut: return L("Mượt 2 đầu")
        case .easeOut: return L("Chậm dần cuối")
        case .bounce: return L("Nảy")
        }
    }
    /// Ánh xạ tiến độ tuyến tính `u` (0…1) → tiến độ đã bo.
    func apply(_ u: Double) -> Double {
        let x = max(0, min(1, u))
        switch self {
        case .linear: return x
        case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        case .easeOut: return 1 - pow(1 - x, 2)
        case .bounce:
            let n = 7.5625, d = 2.75
            var t = x
            if t < 1 / d { return n * t * t }
            else if t < 2 / d { t -= 1.5 / d; return n * t * t + 0.75 }
            else if t < 2.5 / d { t -= 2.25 / d; return n * t * t + 0.9375 }
            else { t -= 2.625 / d; return n * t * t + 0.984375 }
        }
    }
}

/// 1 mốc CHUYỂN ĐỘNG của lớp đè — thời điểm `t` TƯƠNG ĐỐI so với đầu clip (0 = đầu clip).
struct OverlayKeyframe: Equatable {
    var t: TimeInterval
    var offsetX: Double
    var offsetY: Double
    var scale: Double
    var rotation: Double
    var opacity: Double = 1
    var easeRaw: String = KFEase.easeInOut.rawValue
    var ease: KFEase {
        get { KFEase(rawValue: easeRaw) ?? .easeInOut }
        set { easeRaw = newValue.rawValue }
    }
}

extension OverlayKeyframe: Codable {
    enum CodingKeys: String, CodingKey { case t, offsetX, offsetY, scale, rotation, opacity, easeRaw }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t        = (try? c.decode(Double.self, forKey: .t)) ?? 0
        offsetX  = (try? c.decode(Double.self, forKey: .offsetX)) ?? 0
        offsetY  = (try? c.decode(Double.self, forKey: .offsetY)) ?? 0
        scale    = (try? c.decode(Double.self, forKey: .scale)) ?? 1
        rotation = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        opacity  = (try? c.decode(Double.self, forKey: .opacity)) ?? 1
        easeRaw  = (try? c.decode(String.self, forKey: .easeRaw)) ?? KFEase.easeInOut.rawValue
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(easeRaw, forKey: .easeRaw)
    }
}

/// Nhóm lớp đè — gom nhiều clip lại để bật/tắt/khoá/dời cả cụm, có tên.
struct OverlayGroup: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String = "Nhóm"
    var memberIDs: [UUID] = []
}

/// Một lớp ảnh/logo đè lên trên video karaoke (track phía trên kiểu CapCut).
/// Giai đoạn B: chỉ ảnh tĩnh. Video overlay để đợt sau.
struct OverlayClip: Identifiable, Equatable {
    var id = UUID()
    var name: String = "Overlay"
    var kind: BackgroundMedia.Kind = .image
    var lastKnownPath: String = ""
    var bookmark: Data?

    /// Xuất hiện trong khoảng `[start, end)` (giây).
    var start: TimeInterval = 0
    var duration: TimeInterval = 5
    /// (M-E) Chỉ VIDEO: điểm vào trong nguồn — phát từ giây này của file video.
    var trimStart: TimeInterval = 0
    /// (M-E) Độ dài nguồn video (giây), để kẹp trim. 0 = chưa biết / không phải video.
    var sourceDuration: TimeInterval = 0
    /// Hiện dần / mờ dần ở 2 đầu clip (giây). 0 = tắt.
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 0
    /// Chỉ VIDEO: phát TIẾNG của clip (mặc định TẮT — như trước).
    var videoAudioOn: Bool = false
    /// Tắt tiếng clip này (dùng cho clip AUDIO trên làn lớp đè + nút loa đầu làn).
    var audioMuted: Bool = false

    /// Clip này có mang TIẾNG để trộn không? (audio luôn có; video khi bật `videoAudioOn`.)
    var carriesAudio: Bool {
        (kind == .audio || (kind == .video && videoAudioOn)) && !audioMuted && !isHidden
    }

    // MARK: Lớp CHỮ (kind == .text) — 1 dòng chữ đè, hoạt động như lớp ảnh.
    var text: String = "Văn bản"
    var textFontName: String = "Helvetica Neue"
    var textFontSize: Double = 96            // pt tại khung quy chiếu 1080
    var textBold: Bool = false
    var textItalic: Bool = false
    var textLineSpacing: Double = 0          // px giữa các dòng (quy chiếu 1080)
    var textCharSpacing: Double = 0          // giãn chữ (kern)
    var textWrapFrac: Double = 0.8           // bề rộng ngắt dòng = tỉ lệ bề ngang khung
    var textColor: RGBAColor = .white               // (legacy) = màu đơn; đồng bộ với textFill.color
    var textFill: ColorFill = .solid(.white)        // tô chữ: đơn sắc HOẶC gradient
    var textAlignRaw: String = KaraokeTextAlignment.center.rawValue
    var textOutlineColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 1)      // (legacy)
    var textOutlineWidth: Double = 0        // mặc định KHÔNG viền
    var textBackgroundColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0)   // a==0 = tắt nền (legacy)
    var textOutlineFill: ColorFill = .solid(RGBAColor(r: 0, g: 0, b: 0, a: 1))
    var textBackgroundFill: ColorFill = .solid(RGBAColor(r: 0, g: 0, b: 0, a: 0))
    var textShadowColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0)       // a==0 = tắt bóng (legacy)
    var textShadowRadius: Double = 10
    var textShadowDX: Double = 0
    var textShadowDY: Double = 5                                             // + = xuống
    var textGlowColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0)         // a==0 = tắt glow (legacy)
    var textGlowRadius: Double = 16
    var textShadowFill: ColorFill = .solid(RGBAColor(r: 0, g: 0, b: 0, a: 0))
    var textGlowFill: ColorFill = .solid(RGBAColor(r: 0, g: 0, b: 0, a: 0))
    /// Hiệu ứng chữ VÀO / RA + thời lượng (giây).
    var textEntranceRaw: String = TextEffect.none.rawValue
    var textExitRaw: String = TextEffect.none.rawValue
    var textEffectDur: Double = 0.4

    var textAlign: KaraokeTextAlignment {
        get { KaraokeTextAlignment(rawValue: textAlignRaw) ?? .center }
        set { textAlignRaw = newValue.rawValue }
    }
    var textEntrance: TextEffect {
        get { TextEffect(rawValue: textEntranceRaw) ?? .none }
        set { textEntranceRaw = newValue.rawValue }
    }
    var textExit: TextEffect {
        get { TextEffect(rawValue: textExitRaw) ?? .none }
        set { textExitRaw = newValue.rawValue }
    }

    // Biến hình — theo PHẦN của canvas (0 = giữa). +X phải, +Y xuống.
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Nhân vào kích thước cơ sở "vừa khung" (fit). 1 = vừa khít trong khung.
    var scale: Double = 0.4
    var rotation: Double = 0        // độ
    var opacity: Double = 1

    var blendRaw: String = Compositor.Blend.normal.rawValue
    /// true = đè LÊN chữ (track trên). false = nằm DƯỚI chữ (ví dụ ảnh graded tô màu video).
    var aboveText: Bool = false   // mặc định NẰM DƯỚI chữ karaoke
    var colorAdjust: ColorAdjust = ColorAdjust()
    var isHidden: Bool = false
    var isLocked: Bool = false
    /// Hàng hiển thị trên timeline (xếp chồng để không đè nhau về mặt hình vẽ).
    var lane: Int = 0

    /// Chuyển động (keyframe). RỖNG = tĩnh (dùng `offsetX/offsetY/scale/rotation` cố định).
    /// Luôn giữ sắp theo `t` tăng dần.
    var keyframes: [OverlayKeyframe] = []

    var blend: Compositor.Blend {
        get { Compositor.Blend(rawValue: blendRaw) ?? .normal }
        set { blendRaw = newValue.rawValue }
    }

    var end: TimeInterval { start + max(0.1, duration) }

    // MARK: Chuyển động

    typealias Pose = (offX: Double, offY: Double, scale: Double, rot: Double, opacity: Double)

    /// Biến hình tại thời điểm `lt` (giây, tính từ đầu clip). Rỗng keyframe → giá trị tĩnh.
    func transform(atLocal lt: TimeInterval) -> Pose {
        guard let first = keyframes.first, let last = keyframes.last else {
            return (offsetX, offsetY, scale, rotation, opacity)
        }
        if lt <= first.t { return (first.offsetX, first.offsetY, first.scale, first.rotation, first.opacity) }
        if lt >= last.t { return (last.offsetX, last.offsetY, last.scale, last.rotation, last.opacity) }
        for i in 0..<(keyframes.count - 1) {
            let a = keyframes[i], b = keyframes[i + 1]
            guard lt >= a.t, lt <= b.t else { continue }
            let u = (lt - a.t) / max(0.0001, b.t - a.t)
            let e = b.ease.apply(u)                                  // đường cong của mốc ĐÍCH
            func L(_ x: Double, _ y: Double) -> Double { x + (y - x) * e }
            return (L(a.offsetX, b.offsetX), L(a.offsetY, b.offsetY),
                    L(a.scale, b.scale), L(a.rotation, b.rotation), L(a.opacity, b.opacity))
        }
        return (offsetX, offsetY, scale, rotation, opacity)
    }

    mutating func upsertKeyframe(atLocal lt: TimeInterval, offX: Double, offY: Double,
                                scale: Double, rotation: Double, opacity: Double,
                                ease: KFEase? = nil) {
        let t = max(0, min(max(0.1, duration), lt))
        if let i = keyframes.firstIndex(where: { abs($0.t - t) < 0.05 }) {
            keyframes[i].offsetX = offX; keyframes[i].offsetY = offY
            keyframes[i].scale = scale; keyframes[i].rotation = rotation; keyframes[i].opacity = opacity
            if let ease { keyframes[i].ease = ease }
        } else {
            var kf = OverlayKeyframe(t: t, offsetX: offX, offsetY: offY, scale: scale,
                                    rotation: rotation, opacity: opacity)
            if let ease { kf.ease = ease }
            keyframes.append(kf)
            keyframes.sort { $0.t < $1.t }
        }
    }

    mutating func removeKeyframe(nearLocal lt: TimeInterval, tol: TimeInterval = 0.15) {
        keyframes.removeAll { abs($0.t - lt) < tol }
    }

    init() {}

    init(kind: BackgroundMedia.Kind = .image, url: URL, start: TimeInterval, duration: TimeInterval) {
        self.kind = kind
        self.lastKnownPath = url.path
        self.name = url.deletingPathExtension().lastPathComponent
        self.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        self.start = start
        self.duration = duration
    }

    /// Tìm lại file thật: ưu tiên bookmark, rồi đường dẫn cũ.
    func resolveURL() -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: lastKnownPath)
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }
}

// MARK: - Codable "khoan dung"

extension OverlayClip: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, kind, lastKnownPath, bookmark, start, duration
        case trimStart, sourceDuration, fadeIn, fadeOut, videoAudioOn, audioMuted
        case offsetX, offsetY, scale, rotation, opacity, blendRaw
        case aboveText, colorAdjust, isHidden, isLocked, lane, keyframes
        case text, textFontName, textFontSize, textBold, textItalic, textColor, textFill
        case textLineSpacing, textCharSpacing, textWrapFrac
        case textAlignRaw, textOutlineColor, textOutlineWidth, textBackgroundColor
        case textOutlineFill, textBackgroundFill
        case textShadowColor, textShadowRadius, textShadowDX, textShadowDY
        case textGlowColor, textGlowRadius, textShadowFill, textGlowFill
        case textEntranceRaw, textExitRaw, textEffectDur
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        name          = try c.decodeIfPresent(String.self, forKey: .name) ?? name
        kind          = try c.decodeIfPresent(BackgroundMedia.Kind.self, forKey: .kind) ?? kind
        lastKnownPath = try c.decodeIfPresent(String.self, forKey: .lastKnownPath) ?? lastKnownPath
        bookmark      = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        start         = try c.decodeIfPresent(TimeInterval.self, forKey: .start) ?? start
        duration      = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? duration
        trimStart     = try c.decodeIfPresent(TimeInterval.self, forKey: .trimStart) ?? trimStart
        sourceDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .sourceDuration) ?? sourceDuration
        fadeIn        = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? fadeIn
        fadeOut       = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? fadeOut
        videoAudioOn  = try c.decodeIfPresent(Bool.self, forKey: .videoAudioOn) ?? videoAudioOn
        audioMuted    = try c.decodeIfPresent(Bool.self, forKey: .audioMuted) ?? audioMuted
        offsetX       = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? offsetX
        offsetY       = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? offsetY
        scale         = try c.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        rotation      = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? rotation
        opacity       = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        blendRaw      = try c.decodeIfPresent(String.self, forKey: .blendRaw) ?? blendRaw
        aboveText     = try c.decodeIfPresent(Bool.self, forKey: .aboveText) ?? aboveText
        colorAdjust   = try c.decodeIfPresent(ColorAdjust.self, forKey: .colorAdjust) ?? colorAdjust
        isHidden      = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? isHidden
        isLocked      = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? isLocked
        lane          = try c.decodeIfPresent(Int.self, forKey: .lane) ?? lane
        keyframes     = try c.decodeIfPresent([OverlayKeyframe].self, forKey: .keyframes) ?? keyframes
        text              = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        textFontName      = try c.decodeIfPresent(String.self, forKey: .textFontName) ?? textFontName
        textFontSize      = try c.decodeIfPresent(Double.self, forKey: .textFontSize) ?? textFontSize
        textBold          = try c.decodeIfPresent(Bool.self, forKey: .textBold) ?? textBold
        textItalic        = try c.decodeIfPresent(Bool.self, forKey: .textItalic) ?? textItalic
        textLineSpacing   = try c.decodeIfPresent(Double.self, forKey: .textLineSpacing) ?? textLineSpacing
        textCharSpacing   = try c.decodeIfPresent(Double.self, forKey: .textCharSpacing) ?? textCharSpacing
        textWrapFrac      = try c.decodeIfPresent(Double.self, forKey: .textWrapFrac) ?? textWrapFrac
        textColor         = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? textColor
        textFill          = try c.decodeIfPresent(ColorFill.self, forKey: .textFill) ?? .solid(textColor)
        textAlignRaw      = try c.decodeIfPresent(String.self, forKey: .textAlignRaw) ?? textAlignRaw
        textOutlineColor  = try c.decodeIfPresent(RGBAColor.self, forKey: .textOutlineColor) ?? textOutlineColor
        textOutlineWidth  = try c.decodeIfPresent(Double.self, forKey: .textOutlineWidth) ?? textOutlineWidth
        textBackgroundColor = try c.decodeIfPresent(RGBAColor.self, forKey: .textBackgroundColor) ?? textBackgroundColor
        textOutlineFill    = try c.decodeIfPresent(ColorFill.self, forKey: .textOutlineFill) ?? .solid(textOutlineColor)
        textBackgroundFill = try c.decodeIfPresent(ColorFill.self, forKey: .textBackgroundFill) ?? .solid(textBackgroundColor)
        textShadowColor   = try c.decodeIfPresent(RGBAColor.self, forKey: .textShadowColor) ?? textShadowColor
        textShadowRadius  = try c.decodeIfPresent(Double.self, forKey: .textShadowRadius) ?? textShadowRadius
        textShadowDX      = try c.decodeIfPresent(Double.self, forKey: .textShadowDX) ?? textShadowDX
        textShadowDY      = try c.decodeIfPresent(Double.self, forKey: .textShadowDY) ?? textShadowDY
        textGlowColor     = try c.decodeIfPresent(RGBAColor.self, forKey: .textGlowColor) ?? textGlowColor
        textGlowRadius    = try c.decodeIfPresent(Double.self, forKey: .textGlowRadius) ?? textGlowRadius
        textShadowFill    = try c.decodeIfPresent(ColorFill.self, forKey: .textShadowFill) ?? .solid(textShadowColor)
        textGlowFill      = try c.decodeIfPresent(ColorFill.self, forKey: .textGlowFill) ?? .solid(textGlowColor)
        textEntranceRaw   = try c.decodeIfPresent(String.self, forKey: .textEntranceRaw) ?? textEntranceRaw
        textExitRaw       = try c.decodeIfPresent(String.self, forKey: .textExitRaw) ?? textExitRaw
        textEffectDur     = try c.decodeIfPresent(Double.self, forKey: .textEffectDur) ?? textEffectDur
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(lastKnownPath, forKey: .lastKnownPath)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(start, forKey: .start)
        try c.encode(duration, forKey: .duration)
        try c.encode(trimStart, forKey: .trimStart)
        try c.encode(sourceDuration, forKey: .sourceDuration)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(videoAudioOn, forKey: .videoAudioOn)
        try c.encode(audioMuted, forKey: .audioMuted)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(scale, forKey: .scale)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(blendRaw, forKey: .blendRaw)
        try c.encode(aboveText, forKey: .aboveText)
        try c.encode(colorAdjust, forKey: .colorAdjust)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encode(lane, forKey: .lane)
        try c.encode(keyframes, forKey: .keyframes)
        try c.encode(text, forKey: .text)
        try c.encode(textFontName, forKey: .textFontName)
        try c.encode(textFontSize, forKey: .textFontSize)
        try c.encode(textBold, forKey: .textBold)
        try c.encode(textItalic, forKey: .textItalic)
        try c.encode(textLineSpacing, forKey: .textLineSpacing)
        try c.encode(textCharSpacing, forKey: .textCharSpacing)
        try c.encode(textWrapFrac, forKey: .textWrapFrac)
        try c.encode(textColor, forKey: .textColor)
        try c.encode(textFill, forKey: .textFill)
        try c.encode(textAlignRaw, forKey: .textAlignRaw)
        try c.encode(textOutlineColor, forKey: .textOutlineColor)
        try c.encode(textOutlineWidth, forKey: .textOutlineWidth)
        try c.encode(textBackgroundColor, forKey: .textBackgroundColor)
        try c.encode(textOutlineFill, forKey: .textOutlineFill)
        try c.encode(textBackgroundFill, forKey: .textBackgroundFill)
        try c.encode(textShadowColor, forKey: .textShadowColor)
        try c.encode(textShadowRadius, forKey: .textShadowRadius)
        try c.encode(textShadowDX, forKey: .textShadowDX)
        try c.encode(textShadowDY, forKey: .textShadowDY)
        try c.encode(textGlowColor, forKey: .textGlowColor)
        try c.encode(textGlowRadius, forKey: .textGlowRadius)
        try c.encode(textShadowFill, forKey: .textShadowFill)
        try c.encode(textGlowFill, forKey: .textGlowFill)
        try c.encode(textEntranceRaw, forKey: .textEntranceRaw)
        try c.encode(textExitRaw, forKey: .textExitRaw)
        try c.encode(textEffectDur, forKey: .textEffectDur)
    }
}
