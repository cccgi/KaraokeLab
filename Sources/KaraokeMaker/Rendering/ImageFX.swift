import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Bộ thông số chỉnh màu cho một ảnh / video (nền hoặc lớp đè).
///
/// C1 (2026-09-06): mọi field theo thang NỘI BỘ **−1…1** (UI hiển thị −100…100),
/// **neutral = 0**. `vignette` là 0…1. Engine ở `ColorPipeline` (linear working space).
struct ColorAdjust: Equatable {
    var exposure: Double = 0     // −1…1  → EV [−4,4]
    var contrast: Double = 0     // −1…1
    var highlights: Double = 0   // −1…1  (dải sáng RỘNG)
    var shadows: Double = 0      // −1…1  (dải tối RỘNG)
    var whites: Double = 0       // −1…1  (điểm trắng)
    var blacks: Double = 0       // −1…1  (điểm đen)
    var temperature: Double = 0  // −1…1  (âm = lạnh, dương = ấm)
    var tint: Double = 0         // −1…1  (âm = xanh lá, dương = hồng)
    var vibrance: Double = 0     // −1…1  (đẩy màu nhạt nhiều hơn màu đã rực)
    var saturation: Double = 0   // −1…1
    var vignette: Double = 0     // 0…1   (0 = không tối góc)

    var curves = ToneCurves()    // C8
    var hsl = HSLAdjust()        // C9
    var lut: LUTRef? = nil       // C10

    var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0
            && whites == 0 && blacks == 0 && temperature == 0 && tint == 0
            && vibrance == 0 && saturation == 0 && vignette == 0
            && curves.isIdentity && hsl.isIdentity && !(lut?.isActive ?? false)
    }
    /// Khoá cache — đổi thì ảnh phải render lại.
    var key: String {
        [exposure, contrast, highlights, shadows, whites, blacks,
         temperature, tint, vibrance, saturation, vignette]
            .map { String(format: "%.3f", $0) }.joined(separator: "|")
        + "#" + curves.key + "#" + hsl.key
        + "#" + (lut.map { "\($0.path):\(String(format: "%.2f", $0.intensity))" } ?? "-")
    }
}

// MARK: - Codable "khoan dung" + di trú từ định dạng cũ

extension ColorAdjust: Codable {
    enum CodingKeys: String, CodingKey {
        case v                       // schema version (>=2 = thang mới)
        case exposure, contrast, highlights, shadows, whites, blacks
        case temperature, tint, vibrance, saturation, vignette
        case curves, hsl, lut        // C8–C10
        case warmth                  // cũ: −1…1 (map sang temperature)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let ver = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        if ver >= 2 {
            exposure    = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
            contrast    = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
            highlights  = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            shadows     = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            whites      = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
            blacks      = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
            tint        = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
            vibrance    = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
            saturation  = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
            vignette    = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
            curves      = try c.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? ToneCurves()
            hsl         = try c.decodeIfPresent(HSLAdjust.self, forKey: .hsl) ?? HSLAdjust()
            lut         = try c.decodeIfPresent(LUTRef.self, forKey: .lut)
        } else {
            // Định dạng cũ: exposure = EV (−2…2), contrast/saturation = 0…2 (1 = neutral),
            // warmth = −1…1, vignette = 0…1.
            let ev  = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
            let con = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
            let sat = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
            let wrm = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
            let vig = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
            exposure    = min(1, max(-1, ev / 4.0))
            contrast    = min(1, max(-1, con - 1.0))
            saturation  = min(1, max(-1, sat - 1.0))
            temperature = min(1, max(-1, wrm))
            vignette    = min(1, max(0, vig))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(2, forKey: .v)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(whites, forKey: .whites)
        try c.encode(blacks, forKey: .blacks)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(vignette, forKey: .vignette)
        if !curves.isIdentity { try c.encode(curves, forKey: .curves) }
        if !hsl.isIdentity { try c.encode(hsl, forKey: .hsl) }
        try c.encodeIfPresent(lut, forKey: .lut)
    }
}

// MARK: - Điểm áp màu DUY NHẤT (preview = export = still = thumbnail)

enum ImageFX {
    /// Áp `adj` lên `cg`, trả CGImage mới. Identity → nguyên bản.
    static func apply(_ cg: CGImage, _ adj: ColorAdjust) -> CGImage {
        guard !adj.isIdentity else { return cg }
        return ColorPipeline.applyCG(cg, adj)
    }

    /// Làm mờ mạnh (nền "lấp 2 bên bằng ảnh mờ"). KHÔNG liên quan color engine.
    static func blurred(_ cg: CGImage, radius: Double = 40) -> CGImage {
        let src = CIImage(cgImage: cg)
        let out = src.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: src.extent)
        return ColorPipeline.context.createCGImage(out, from: src.extent) ?? cg
    }
}

// MARK: - Cache ảnh NỀN đã xử lý (chỉnh màu + bản mờ)

enum BackgroundImageStore {
    private static var cache: [String: (main: CGImage, blur: CGImage?)] = [:]
    private static let lock = NSLock()

    private static var lastPtr: UnsafeMutableRawPointer?
    private static var lastAdj = ColorAdjust()
    private static var lastBlur = false
    private static var lastOut: (main: CGImage, blur: CGImage?)?

    static func processed(base: CGImage, adjust: ColorAdjust, needBlur: Bool)
        -> (main: CGImage, blur: CGImage?) {
        let ptr = Unmanaged.passUnretained(base).toOpaque()
        if let out = lastOut, lastPtr == ptr, needBlur == lastBlur, adjust == lastAdj {
            return out
        }
        let key = "\(base.width)x\(base.height)|\(adjust.key)|\(needBlur)"
        lock.lock(); let hit = cache[key]; lock.unlock()
        let out: (main: CGImage, blur: CGImage?)
        if let hit {
            out = hit
        } else {
            let main = adjust.isIdentity ? base : ImageFX.apply(base, adjust)
            let blur = needBlur ? ImageFX.blurred(main) : nil
            out = (main, blur)
            lock.lock()
            if cache.count > 8 { cache.removeAll(keepingCapacity: true) }
            cache[key] = out
            lock.unlock()
        }
        lastPtr = ptr; lastAdj = adjust; lastBlur = needBlur; lastOut = out
        return out
    }

    static func flush() {
        lock.lock(); cache.removeAll(); lock.unlock()
        lastPtr = nil; lastOut = nil
    }
}
