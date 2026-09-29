import Foundation

/// Bộ "sóng nhạc" (audio visualizer) — vẽ theo AUDIO GỐC (file người dùng bỏ vào, chưa tách).
/// Dùng chung cho Preview + Export. `nil` trong project = không bật.
struct MusicVisualizer: Equatable {

    enum Style: String, Codable, CaseIterable, Identifiable {
        case barsMirror   // cột đối xứng (dội 2 bên đường giữa)
        case barsUp       // cột mọc từ đáy lên
        case segments     // cột chia đốt (LED / VU meter)
        case dots         // mỗi dải 1 chấm nảy lên
        case waveLine     // đường sóng mảnh
        case areaGlow     // dải sóng tô đầy (ruy-băng) — dội 2 bên
        case radial       // cột toả tia quanh vòng tròn
        case radialBlob   // khối tròn nhấp nhô (đa giác hữu cơ)
        case ribbonMirror // dải sóng + bóng phản chiếu mờ dần phía dưới (như mặt nước)
        case radialRing   // vòng sóng viền (glow, rỗng ở giữa) quanh tâm
        case sparkleBars  // cột kèm hạt lấp lánh bay lên ở ngọn khi biên độ mạnh
        case neonBars     // cột chỉ viền neon rực sáng, rỗng bên trong
        var id: String { rawValue }
        var label: String {
            switch self {
            case .barsMirror: return L("Cột đối xứng")
            case .barsUp:     return L("Cột từ đáy")
            case .segments:   return L("Cột chia đốt")
            case .dots:       return L("Chấm nảy")
            case .waveLine:   return L("Đường sóng")
            case .areaGlow:   return L("Dải sóng đầy")
            case .radial:     return L("Vòng toả tia")
            case .radialBlob: return L("Khối tròn nhấp nhô")
            case .ribbonMirror: return L("Dải sóng phản chiếu")
            case .radialRing:   return L("Vòng sóng viền")
            case .sparkleBars:  return L("Cột lấp lánh")
            case .neonBars:     return L("Cột viền neon")
            }
        }
    }

    /// Hướng chuyển màu.
    enum GradientDir: String, Codable, CaseIterable, Identifiable {
        case up        // dọc theo chiều cao (gốc → ngọn)
        case across    // ngang theo bề rộng (trái → phải)
        case rainbow   // đổi màu theo TỪNG cột (cầu vồng)
        var id: String { rawValue }
        var label: String {
            switch self {
            case .up: return L("Dọc (gốc→ngọn)")
            case .across: return L("Ngang (trái→phải)")
            case .rainbow: return L("Cầu vồng theo cột")
            }
        }
    }

    var enabled: Bool = false
    var style: Style = .barsMirror
    var bandCount: Int = 56

    // ---- Hình học (theo PHẦN canvas) ----
    var widthFrac: Double = 1.0        // 1 = full bề ngang
    var heightFrac: Double = 0.30      // chiều cao TỐI ĐA của sóng
    var offsetX: Double = 0            // -0.5…0.5 — dời ngang
    var baselineY: Double = 0.07       // 0 = sát đáy; tăng = nâng lên (phần chiều cao)
    var rotation: Double = 0           // độ — góc xoay ban đầu (kiểu radial)

    // ---- Màu ----
    var color1: RGBAColor = RGBAColor(r: 0.09, g: 0.78, b: 1.00, a: 1)   // gốc (đáy / trong)
    var color2: RGBAColor = RGBAColor(r: 0.78, g: 0.22, b: 1.00, a: 1)   // ngọn (đỉnh / ngoài)
    var gradientDir: GradientDir = .up
    var rainbowSpread: Double = 1.0    // số vòng màu quét qua cả dàn (0.2…3)
    var rainbowShift: Double = 0.55    // xoay màu bắt đầu (0…1)
    var glowAuto: Bool = true          // true = quầng sáng dùng color1
    var glowColor: RGBAColor = RGBAColor(r: 0.20, g: 0.80, b: 1.00, a: 1)
    var tipColor: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 0)          // a=0 → tắt; a>0 → chấm sáng ở ngọn

    // ---- Hình thức ----
    var opacity: Double = 1
    var glow: Double = 0.35            // 0…1 — quầng sáng
    var barGapFrac: Double = 0.35      // khe giữa cột (phần bề rộng 1 cột)
    var cornerRadiusFrac: Double = 0.5 // bo đầu cột (0…0.5 bề rộng cột)
    var segCount: Int = 14             // số đốt (kiểu segments)
    var sensitivity: Double = 1.0      // nhân biên độ (0.2…3)
    var smoothing: Double = 0.55       // 0 = giật, 1 = rất mượt (làm mượt THÊM lúc vẽ)
    var mirror: Bool = true            // dùng cho barsMirror / areaGlow
    var lineWidthFrac: Double = 0.007  // cho waveLine (phần canvas.height)
    var aboveText: Bool = false        // true = đè LÊN chữ; false = nằm DƯỚI chữ (mặc định)

    /// Chuyển động (keyframe) — nội suy VỊ TRÍ / CỠ / ĐỘ MỜ theo GIỜ BÀI. Rỗng = tĩnh.
    var keyframes: [VizKeyframe] = []

    static let `default` = MusicVisualizer()

    // MARK: Chuyển động

    /// Bản sao với hình học/độ mờ đã nội suy tại `lt` (giây trong bài). Rỗng keyframe → chính nó.
    func resolved(atSong lt: TimeInterval) -> MusicVisualizer {
        guard let a0 = keyframes.first, let b0 = keyframes.last else { return self }
        var c = self
        func pick(_ f: (VizKeyframe) -> Double) -> Double {
            if lt <= a0.t { return f(a0) }
            if lt >= b0.t { return f(b0) }
            for i in 0..<(keyframes.count - 1) {
                let a = keyframes[i], b = keyframes[i + 1]
                guard lt >= a.t, lt <= b.t else { continue }
                let u = (lt - a.t) / max(0.0001, b.t - a.t)
                let e = b.ease.apply(u)
                return f(a) + (f(b) - f(a)) * e
            }
            return f(a0)
        }
        c.widthFrac  = pick { $0.widthFrac }
        c.heightFrac = pick { $0.heightFrac }
        c.offsetX    = pick { $0.offsetX }
        c.baselineY  = pick { $0.baselineY }
        c.rotation   = pick { $0.rotation }
        c.opacity    = pick { $0.opacity }
        return c
    }

    mutating func upsertKeyframe(atSong lt: TimeInterval) {
        let t = max(0, lt)
        let kf = VizKeyframe(t: t, widthFrac: widthFrac, heightFrac: heightFrac, offsetX: offsetX,
                             baselineY: baselineY, rotation: rotation, opacity: opacity)
        if let i = keyframes.firstIndex(where: { abs($0.t - t) < 0.05 }) { keyframes[i] = kf }
        else { keyframes.append(kf); keyframes.sort { $0.t < $1.t } }
    }

    mutating func removeKeyframe(nearSong lt: TimeInterval, tol: TimeInterval = 0.15) {
        keyframes.removeAll { abs($0.t - lt) < tol }
    }

    /// Bật lần đầu → bộ mặc định "đẹp sẵn", full bề ngang.
    static func freshDefault() -> MusicVisualizer {
        var v = MusicVisualizer()
        v.enabled = true
        return v
    }
}

/// 1 mốc chuyển động cho sóng nhạc (giờ = giây trong BÀI).
struct VizKeyframe: Equatable {
    var t: TimeInterval
    var widthFrac: Double
    var heightFrac: Double
    var offsetX: Double
    var baselineY: Double
    var rotation: Double
    var opacity: Double
    var easeRaw: String = KFEase.easeInOut.rawValue
    var ease: KFEase {
        get { KFEase(rawValue: easeRaw) ?? .easeInOut }
        set { easeRaw = newValue.rawValue }
    }
}

extension VizKeyframe: Codable {
    enum CodingKeys: String, CodingKey {
        case t, widthFrac, heightFrac, offsetX, baselineY, rotation, opacity, easeRaw
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t          = (try? c.decode(Double.self, forKey: .t)) ?? 0
        widthFrac  = (try? c.decode(Double.self, forKey: .widthFrac)) ?? 1
        heightFrac = (try? c.decode(Double.self, forKey: .heightFrac)) ?? 0.3
        offsetX    = (try? c.decode(Double.self, forKey: .offsetX)) ?? 0
        baselineY  = (try? c.decode(Double.self, forKey: .baselineY)) ?? 0.07
        rotation   = (try? c.decode(Double.self, forKey: .rotation)) ?? 0
        opacity    = (try? c.decode(Double.self, forKey: .opacity)) ?? 1
        easeRaw    = (try? c.decode(String.self, forKey: .easeRaw)) ?? KFEase.easeInOut.rawValue
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t); try c.encode(widthFrac, forKey: .widthFrac)
        try c.encode(heightFrac, forKey: .heightFrac); try c.encode(offsetX, forKey: .offsetX)
        try c.encode(baselineY, forKey: .baselineY); try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity); try c.encode(easeRaw, forKey: .easeRaw)
    }
}

// MARK: - Codable "khoan dung"

extension MusicVisualizer: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, style, bandCount
        case widthFrac, heightFrac, offsetX, baselineY, rotation
        case color1, color2, gradientDir, rainbowSpread, rainbowShift
        case glowAuto, glowColor, tipColor
        case opacity, glow, barGapFrac, cornerRadiusFrac, segCount
        case sensitivity, smoothing, mirror, lineWidthFrac, aboveText, keyframes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled          = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        style            = try c.decodeIfPresent(Style.self, forKey: .style) ?? style
        bandCount        = try c.decodeIfPresent(Int.self, forKey: .bandCount) ?? bandCount
        widthFrac        = try c.decodeIfPresent(Double.self, forKey: .widthFrac) ?? widthFrac
        heightFrac       = try c.decodeIfPresent(Double.self, forKey: .heightFrac) ?? heightFrac
        offsetX          = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? offsetX
        baselineY        = try c.decodeIfPresent(Double.self, forKey: .baselineY) ?? baselineY
        rotation         = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? rotation
        color1           = try c.decodeIfPresent(RGBAColor.self, forKey: .color1) ?? color1
        color2           = try c.decodeIfPresent(RGBAColor.self, forKey: .color2) ?? color2
        gradientDir      = try c.decodeIfPresent(GradientDir.self, forKey: .gradientDir) ?? gradientDir
        rainbowSpread    = try c.decodeIfPresent(Double.self, forKey: .rainbowSpread) ?? rainbowSpread
        rainbowShift     = try c.decodeIfPresent(Double.self, forKey: .rainbowShift) ?? rainbowShift
        glowAuto         = try c.decodeIfPresent(Bool.self, forKey: .glowAuto) ?? glowAuto
        glowColor        = try c.decodeIfPresent(RGBAColor.self, forKey: .glowColor) ?? glowColor
        tipColor         = try c.decodeIfPresent(RGBAColor.self, forKey: .tipColor) ?? tipColor
        opacity          = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        glow             = try c.decodeIfPresent(Double.self, forKey: .glow) ?? glow
        barGapFrac       = try c.decodeIfPresent(Double.self, forKey: .barGapFrac) ?? barGapFrac
        cornerRadiusFrac = try c.decodeIfPresent(Double.self, forKey: .cornerRadiusFrac) ?? cornerRadiusFrac
        segCount         = try c.decodeIfPresent(Int.self, forKey: .segCount) ?? segCount
        sensitivity      = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? sensitivity
        smoothing        = try c.decodeIfPresent(Double.self, forKey: .smoothing) ?? smoothing
        mirror           = try c.decodeIfPresent(Bool.self, forKey: .mirror) ?? mirror
        lineWidthFrac    = try c.decodeIfPresent(Double.self, forKey: .lineWidthFrac) ?? lineWidthFrac
        aboveText        = try c.decodeIfPresent(Bool.self, forKey: .aboveText) ?? aboveText
        keyframes        = try c.decodeIfPresent([VizKeyframe].self, forKey: .keyframes) ?? keyframes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(style, forKey: .style)
        try c.encode(bandCount, forKey: .bandCount)
        try c.encode(widthFrac, forKey: .widthFrac)
        try c.encode(heightFrac, forKey: .heightFrac)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(baselineY, forKey: .baselineY)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(color1, forKey: .color1)
        try c.encode(color2, forKey: .color2)
        try c.encode(gradientDir, forKey: .gradientDir)
        try c.encode(rainbowSpread, forKey: .rainbowSpread)
        try c.encode(rainbowShift, forKey: .rainbowShift)
        try c.encode(glowAuto, forKey: .glowAuto)
        try c.encode(glowColor, forKey: .glowColor)
        try c.encode(tipColor, forKey: .tipColor)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(glow, forKey: .glow)
        try c.encode(barGapFrac, forKey: .barGapFrac)
        try c.encode(cornerRadiusFrac, forKey: .cornerRadiusFrac)
        try c.encode(segCount, forKey: .segCount)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(mirror, forKey: .mirror)
        try c.encode(lineWidthFrac, forKey: .lineWidthFrac)
        try c.encode(aboveText, forKey: .aboveText)
        try c.encode(keyframes, forKey: .keyframes)
    }
}
