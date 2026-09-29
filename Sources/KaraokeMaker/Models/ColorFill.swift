import AppKit
import CoreGraphics

/// 1 chặng màu của gradient.
struct ColorStop: Codable, Equatable, Hashable {
    var color: RGBAColor
    var loc: Double        // 0…1
}

/// Cách tô 1 vùng: MỘT màu, hoặc GRADIENT (tuyến tính / toả tròn), 2 hoặc nhiều chặng.
/// Lưu ra file được. Dùng chung cho lớp chữ (overlay) + chữ karaoke.
struct ColorFill: Codable, Equatable, Hashable {
    enum Style: String, Codable { case solid, linear, radial }

    var style: Style = .solid
    /// Màu đơn / chặng ĐẦU (giữ để tương thích ngược).
    var color: RGBAColor = .white
    /// Chặng CUỐI khi chỉ có 2 chặng (giữ để tương thích ngược).
    var color2: RGBAColor = RGBAColor(r: 0.30, g: 0.45, b: 0.95, a: 1)
    /// Hướng gradient tuyến tính theo độ: 0 = trái→phải, 90 = trên→dưới (màn hình).
    var angle: Double = 90
    /// ≥ 2 chặng → đây là danh sách chuẩn; rỗng → suy ra từ `color`/`color2`.
    var stops: [ColorStop] = []

    static func solid(_ c: RGBAColor) -> ColorFill {
        ColorFill(style: .solid, color: c, color2: c, angle: 90, stops: [])
    }

    // MARK: Suy diễn

    /// Danh sách chặng thực tế (luôn ≥ 2, đã sắp theo `loc`).
    var effectiveStops: [ColorStop] {
        if stops.count >= 2 {
            return stops.sorted { $0.loc < $1.loc }
        }
        return [ColorStop(color: color, loc: 0), ColorStop(color: color2, loc: 1)]
    }

    /// Có tô ra 1 màu ĐỒNG NHẤT không? (solid, hoặc mọi chặng cùng màu.)
    var isFlat: Bool {
        if style == .solid { return true }
        let s = effectiveStops
        return s.allSatisfy { $0.color == s[0].color }
    }
    /// Màu khi coi như đồng nhất.
    var flatColor: RGBAColor { style == .solid ? color : (effectiveStops.first?.color ?? color) }
    /// (cũ) — giữ tên `isSolid` cho chỗ gọi cũ.
    var isSolid: Bool { isFlat }
    var primary: RGBAColor { flatColor }
    /// Alpha lớn nhất trong các chặng — để tính "gần như trong suốt".
    var maxAlpha: Double {
        style == .solid ? color.a : (effectiveStops.map { $0.color.a }.max() ?? color.a)
    }

    // MARK: Codable "khoan dung"
    enum CodingKeys: String, CodingKey { case style, color, color2, angle, stops }
    init() {}
    init(style: Style, color: RGBAColor, color2: RGBAColor, angle: Double, stops: [ColorStop] = []) {
        self.style = style; self.color = color; self.color2 = color2; self.angle = angle; self.stops = stops
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style  = (try? c.decode(Style.self, forKey: .style)) ?? .solid
        color  = (try? c.decode(RGBAColor.self, forKey: .color)) ?? .white
        color2 = (try? c.decode(RGBAColor.self, forKey: .color2)) ?? color
        angle  = (try? c.decode(Double.self, forKey: .angle)) ?? 90
        stops  = (try? c.decode([ColorStop].self, forKey: .stops)) ?? []
    }

    // MARK: Vẽ

    private func cgGradient() -> CGGradient? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let s = effectiveStops
        let colors = s.map { CGColor(srgbRed: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: $0.color.a) }
        let locs = s.map { CGFloat(max(0, min(1, $0.loc))) }
        return CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)
    }

    /// 2 điểm mút gradient tuyến tính trong `rect` theo `angle`.
    /// Quy ước: 0° = trái→phải, 90° = TRÊN→DƯỚI trên MÀN HÌNH. `flipY` = true khi context y-UP.
    private func endpoints(in rect: CGRect, flipY: Bool) -> (CGPoint, CGPoint) {
        let rad = CGFloat(angle) * .pi / 180
        let dx = cos(rad)
        let dy = (flipY ? -1 : 1) * sin(rad)
        let cx = rect.midX, cy = rect.midY
        let hx = abs(dx) * rect.width / 2 + 0.0001
        let hy = abs(dy) * rect.height / 2 + 0.0001
        let ext = max(hx, hy)
        return (CGPoint(x: cx - dx * ext, y: cy - dy * ext),
                CGPoint(x: cx + dx * ext, y: cy + dy * ext))
    }

    private func drawGradient(in cg: CGContext, bounds: CGRect, flipY: Bool) {
        guard let g = cgGradient() else { return }
        if style == .radial {
            let c = CGPoint(x: bounds.midX, y: bounds.midY)
            let r = 0.5 * hypot(bounds.width, bounds.height) + 0.5
            cg.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r,
                                  options: [.drawsAfterEndLocation])
        } else {
            let (p0, p1) = endpoints(in: bounds, flipY: flipY)
            cg.drawLinearGradient(g, start: p0, end: p1,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    /// Tô path ĐANG nằm trong `cg` (bên gọi đã `cg.addPath(...)`), kẹp theo path đó.
    func fillCurrentPath(in cg: CGContext, bounds: CGRect, alpha: CGFloat = 1, flipY: Bool = false) {
        if isFlat {
            let c = flatColor
            cg.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * Double(alpha)))
            cg.fillPath()
            return
        }
        cg.saveGState()
        cg.clip()
        if alpha < 0.999 { cg.setAlpha(alpha) }
        drawGradient(in: cg, bounds: bounds, flipY: flipY)
        cg.restoreGState()
    }

    /// Vẽ "bóng đổ / hào quang mềm" của `shape` bằng fill này.
    /// - Đơn sắc → `setShadow` (nhanh, y hệt cũ).
    /// - Gradient → dựng silhouette nhoè làm MẶT NẠ rồi tô gradient xuyên qua (`clip(to:mask:)`).
    /// `shape` phải ở ĐÚNG hệ toạ độ hiện tại của `cg`. `yUp` = context đang y-UP (lớp chữ overlay).
    func drawSoftGlow(shape: CGPath, in cg: CGContext, layerSize: CGSize, bounds: CGRect,
                      offset: CGSize, blur: CGFloat, yUp: Bool, alpha: CGFloat = 1) {
        let c = flatColor
        let cgc = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * Double(alpha))
        if isFlat {
            cg.saveGState()
            cg.setShadow(offset: offset, blur: max(0, blur), color: cgc)
            cg.addPath(shape)
            cg.setFillColor(cgc)
            cg.fillPath()
            cg.restoreGState()
            return
        }
        let w = max(1, Int(layerSize.width.rounded())), h = max(1, Int(layerSize.height.rounded()))
        guard w < 12000, h < 12000,
              let mctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        // Khớp hệ toạ độ với `cg`: bitmap luôn y-UP, nếu `cg` đang y-DOWN thì lật.
        if !yUp { mctx.translateBy(x: 0, y: CGFloat(h)); mctx.scaleBy(x: 1, y: -1) }
        mctx.setShouldAntialias(true)
        mctx.setShadow(offset: offset, blur: max(0, blur), color: CGColor(gray: 1, alpha: 1))
        mctx.addPath(shape)
        mctx.setFillColor(CGColor(gray: 1, alpha: 1))
        mctx.fillPath()
        guard let mask = mctx.makeImage() else { return }

        cg.saveGState()
        if alpha < 0.999 { cg.setAlpha(alpha) }
        cg.clip(to: CGRect(origin: .zero, size: layerSize), mask: mask)
        drawGradient(in: cg, bounds: bounds, flipY: yUp)
        cg.restoreGState()
    }

    /// Tô đầy `rect` (không có path).
    func fill(rect: CGRect, in cg: CGContext, alpha: CGFloat = 1, flipY: Bool = false) {
        if isFlat {
            let c = flatColor
            cg.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * Double(alpha)))
            cg.fill(rect)
            return
        }
        cg.saveGState()
        cg.clip(to: rect)
        if alpha < 0.999 { cg.setAlpha(alpha) }
        drawGradient(in: cg, bounds: rect, flipY: flipY)
        cg.restoreGState()
    }
}
