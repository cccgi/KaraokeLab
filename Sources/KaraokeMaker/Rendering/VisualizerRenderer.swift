import AppKit
import CoreGraphics

/// Vẽ "sóng nhạc" vào 1 khung hình — dùng CHUNG cho Preview và Export.
/// `bands`: mảng 0…1 (đã lấy tại đúng thời điểm). `flipped == true` → context y-DOWN.
enum VisualizerRenderer {

    static func draw(in cg: CGContext, canvasSize: CGSize, spec: MusicVisualizer,
                     bands rawBands: [Float], flipped: Bool) {
        guard spec.enabled, canvasSize.width > 2, canvasSize.height > 2 else { return }
        var bands = resample(rawBands, to: max(4, spec.bandCount))
        smooth(&bands, amount: spec.smoothing)
        applySensitivity(&bands, spec.sensitivity)

        cg.saveGState()
        defer { cg.restoreGState() }
        if flipped {                         // → y-UP, gốc dưới-trái
            cg.translateBy(x: 0, y: canvasSize.height)
            cg.scaleBy(x: 1, y: -1)
        }
        cg.setAlpha(CGFloat(max(0, min(1, spec.opacity))))

        let resScale = min(canvasSize.width, canvasSize.height) / 1080.0
        let ctx = Ctx(size: canvasSize, spec: spec, resScale: resScale,
                      glowBlur: CGFloat(spec.glow) * 34 * resScale,
                      glowColor: (spec.glowAuto ? spec.color1 : spec.glowColor).nsColor.cgColor.copy(alpha: 0.9)!)

        switch spec.style {
        case .barsMirror, .barsUp: drawBars(cg, ctx, bands, mirror: spec.style == .barsMirror && spec.mirror)
        case .segments:            drawSegments(cg, ctx, bands)
        case .dots:                drawDots(cg, ctx, bands)
        case .waveLine:            drawWave(cg, ctx, bands, filled: false)
        case .areaGlow:            drawWave(cg, ctx, bands, filled: true)
        case .radial:              drawRadial(cg, ctx, bands, blob: false)
        case .radialBlob:          drawRadial(cg, ctx, bands, blob: true)
        case .ribbonMirror:        drawRibbonMirror(cg, ctx, bands)
        case .radialRing:          drawRadialRing(cg, ctx, bands)
        case .sparkleBars:         drawSparkleBars(cg, ctx, bands)
        case .neonBars:            drawNeonBars(cg, ctx, bands)
        }
    }

    // MARK: - Bối cảnh vẽ

    private struct Ctx {
        let size: CGSize
        let spec: MusicVisualizer
        let resScale: CGFloat
        let glowBlur: CGFloat
        let glowColor: CGColor
        var regionW: CGFloat { size.width * CGFloat(spec.widthFrac) }
        var originX: CGFloat { (size.width - regionW) / 2 + CGFloat(spec.offsetX) * size.width }
        var baseY: CGFloat { CGFloat(spec.baselineY) * size.height }
        var maxH: CGFloat { CGFloat(spec.heightFrac) * size.height }
    }

    /// Tô path hiện tại bằng gradient theo `gradientDir` trong khung `bounds`.
    private static func paint(_ cg: CGContext, _ c: Ctx, bounds: CGRect) {
        let space = CGColorSpaceCreateDeviceRGB()
        cg.saveGState(); cg.clip()
        switch c.spec.gradientDir {
        case .up:
            if let g = CGGradient(colorsSpace: space,
                                  colors: [c.spec.color1.nsColor.cgColor, c.spec.color2.nsColor.cgColor] as CFArray,
                                  locations: [0, 1]) {
                cg.drawLinearGradient(g, start: CGPoint(x: 0, y: bounds.minY),
                                      end: CGPoint(x: 0, y: bounds.maxY),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case .across:
            if let g = CGGradient(colorsSpace: space,
                                  colors: [c.spec.color1.nsColor.cgColor, c.spec.color2.nsColor.cgColor] as CFArray,
                                  locations: [0, 1]) {
                cg.drawLinearGradient(g, start: CGPoint(x: bounds.minX, y: 0),
                                      end: CGPoint(x: bounds.maxX, y: 0),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case .rainbow:
            let n = 24
            var cols: [CGColor] = []
            var locs: [CGFloat] = []
            let a1 = CGFloat(c.spec.color1.a)
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let hue = (CGFloat(c.spec.rainbowShift) + t * CGFloat(c.spec.rainbowSpread)).truncatingRemainder(dividingBy: 1)
                cols.append(NSColor(hue: hue < 0 ? hue + 1 : hue, saturation: 0.85, brightness: 1, alpha: a1).cgColor)
                locs.append(t)
            }
            if let g = CGGradient(colorsSpace: space, colors: cols as CFArray, locations: locs) {
                cg.drawLinearGradient(g, start: CGPoint(x: bounds.minX, y: 0),
                                      end: CGPoint(x: bounds.maxX, y: 0),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        cg.restoreGState()
    }

    private static func glowPass(_ cg: CGContext, _ c: Ctx, _ path: CGPath, stroke: CGFloat? = nil) {
        guard c.glowBlur > 0.5 else { return }
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: c.glowBlur, color: c.glowColor)
        cg.addPath(path)
        if let lw = stroke { cg.setStrokeColor(c.glowColor); cg.setLineWidth(lw); cg.setLineCap(.round); cg.strokePath() }
        else { cg.setFillColor(c.glowColor); cg.fillPath() }
        cg.restoreGState()
    }

    private static func tipDots(_ cg: CGContext, _ c: Ctx, centers: [(CGPoint, CGFloat)]) {
        guard c.spec.tipColor.a > 0.01 else { return }
        cg.saveGState()
        cg.setFillColor(c.spec.tipColor.nsColor.cgColor)
        for (p, r) in centers {
            cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        cg.restoreGState()
    }

    // MARK: - Cột / Cột chia đốt

    private static func barGeom(_ c: Ctx, _ n: Int) -> (slot: CGFloat, gap: CGFloat, bw: CGFloat) {
        let slot = c.regionW / CGFloat(n)
        let gap = slot * CGFloat(max(0, min(0.9, c.spec.barGapFrac)))
        return (slot, gap, max(1, slot - gap))
    }

    private static func drawBars(_ cg: CGContext, _ c: Ctx, _ bands: [Float], mirror: Bool) {
        let n = bands.count
        let (slot, gap, bw) = barGeom(c, n)
        let radius = min(bw / 2, bw * CGFloat(max(0, min(0.5, c.spec.cornerRadiusFrac))))
        let path = CGMutablePath()
        var tips: [(CGPoint, CGFloat)] = []
        for i in 0..<n {
            let h = max(bw * 0.30, c.maxH * CGFloat(bands[i]))
            let x = c.originX + CGFloat(i) * slot + gap / 2
            let r = mirror ? CGRect(x: x, y: c.baseY - h / 2, width: bw, height: h)
                           : CGRect(x: x, y: c.baseY, width: bw, height: h)
            let rad = max(0, min(radius, r.height / 2, r.width / 2))
            path.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
            tips.append((CGPoint(x: r.midX, y: r.maxY), bw * 0.42))
        }
        glowPass(cg, c, path)
        cg.addPath(path)
        let lo = mirror ? c.baseY - c.maxH / 2 : c.baseY
        paint(cg, c, bounds: CGRect(x: c.originX, y: lo, width: c.regionW,
                                    height: mirror ? c.maxH : c.maxH))
        tipDots(cg, c, centers: tips)
    }

    private static func drawSegments(_ cg: CGContext, _ c: Ctx, _ bands: [Float]) {
        let n = bands.count
        let (slot, gap, bw) = barGeom(c, n)
        let segs = max(3, min(40, c.spec.segCount))
        let segGap = c.maxH / CGFloat(segs) * 0.28
        let segH = c.maxH / CGFloat(segs) - segGap
        let rad = min(bw, segH) * 0.35
        let path = CGMutablePath()
        for i in 0..<n {
            let lit = Int((CGFloat(bands[i]) * CGFloat(segs)).rounded(.up))
            let x = c.originX + CGFloat(i) * slot + gap / 2
            for s in 0..<max(0, min(segs, lit)) {
                let y = c.baseY + CGFloat(s) * (segH + segGap)
                path.addRoundedRect(in: CGRect(x: x, y: y, width: bw, height: segH),
                                    cornerWidth: rad, cornerHeight: rad)
            }
        }
        glowPass(cg, c, path)
        cg.addPath(path)
        paint(cg, c, bounds: CGRect(x: c.originX, y: c.baseY, width: c.regionW, height: c.maxH))
    }

    private static func drawDots(_ cg: CGContext, _ c: Ctx, _ bands: [Float]) {
        let n = bands.count
        let (slot, _, bw) = barGeom(c, n)
        let r = max(1.5, min(bw, c.maxH * 0.06) * 0.5)
        let path = CGMutablePath()
        for i in 0..<n {
            let x = c.originX + CGFloat(i) * slot + slot / 2
            let y = c.baseY + max(r, c.maxH * CGFloat(bands[i]))
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        glowPass(cg, c, path)
        cg.addPath(path)
        paint(cg, c, bounds: CGRect(x: c.originX, y: c.baseY, width: c.regionW, height: c.maxH))
    }

    // MARK: - Đường sóng / Dải sóng đầy

    private static func drawWave(_ cg: CGContext, _ c: Ctx, _ bands: [Float], filled: Bool) {
        let n = bands.count
        guard n >= 2 else { return }
        let mid = c.baseY + c.maxH * 0.5
        let amp = c.maxH * 0.5
        func pt(_ i: Int, sign: CGFloat) -> CGPoint {
            let t = CGFloat(i) / CGFloat(n - 1)
            let s = CGFloat(bands[max(0, min(n - 1, i))])
            return CGPoint(x: c.originX + t * c.regionW, y: mid + sign * s * amp)
        }
        func curve(sign: CGFloat, into p: CGMutablePath, start: Bool) {
            if start { p.move(to: pt(0, sign: sign)) }
            for i in 1..<n {
                let a = pt(i - 1, sign: sign), b = pt(i, sign: sign)
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                p.addQuadCurve(to: m, control: a)
                if i == n - 1 { p.addQuadCurve(to: b, control: b) }
            }
        }

        if filled {
            let path = CGMutablePath()
            curve(sign: 1, into: path, start: true)
            if c.spec.mirror {
                // đi ngược lại theo nửa dưới → ruy-băng dội 2 bên
                for i in stride(from: n - 1, through: 0, by: -1) {
                    let b = pt(i, sign: -1)
                    if i == n - 1 { path.addLine(to: b) } else { path.addLine(to: b) }
                }
            } else {
                path.addLine(to: CGPoint(x: c.originX + c.regionW, y: c.baseY))
                path.addLine(to: CGPoint(x: c.originX, y: c.baseY))
            }
            path.closeSubpath()
            glowPass(cg, c, path)
            cg.addPath(path)
            paint(cg, c, bounds: CGRect(x: c.originX, y: c.baseY, width: c.regionW, height: c.maxH))
        } else {
            let path = CGMutablePath()
            curve(sign: 1, into: path, start: true)
            let lw = max(1, CGFloat(c.spec.lineWidthFrac) * c.size.height)
            glowPass(cg, c, path, stroke: lw)
            let stroked = path.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 2)
            cg.addPath(stroked)
            paint(cg, c, bounds: CGRect(x: c.originX, y: c.baseY, width: c.regionW, height: c.maxH))
        }
    }

    // MARK: - Vòng toả tia / Khối tròn

    private static func drawRadial(_ cg: CGContext, _ c: Ctx, _ bands: [Float], blob: Bool) {
        let n = bands.count
        let cx = c.size.width / 2 + CGFloat(c.spec.offsetX) * c.size.width
        let cy = c.baseY + c.maxH                      // tâm vòng
        let base = min(c.size.width, c.size.height)
        let r0 = base * (blob ? 0.09 : 0.11)
        let maxLen = base * CGFloat(c.spec.heightFrac) * (blob ? 0.55 : 0.85)
        let rot = CGFloat(c.spec.rotation) * .pi / 180

        let path = CGMutablePath()
        if blob {
            // Điểm quanh vòng theo biên độ từng dải…
            var pts: [CGPoint] = []
            pts.reserveCapacity(n)
            for k in 0..<n {
                let ang = rot + 2 * .pi * CGFloat(k) / CGFloat(n)
                let rr = r0 + maxLen * CGFloat(0.25 + 0.75 * bands[k])
                pts.append(CGPoint(x: cx + cos(ang) * rr, y: cy + sin(ang) * rr))
            }
            // …rồi nối bằng ĐƯỜNG CONG TRƠN khép kín (qua trung điểm, điểm gốc làm control)
            // → viền bo tròn, không còn gãy góc như nối thẳng.
            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            path.move(to: mid(pts[n - 1], pts[0]))
            for k in 0..<n {
                let cur = pts[k]
                let nxt = pts[(k + 1) % n]
                path.addQuadCurve(to: mid(cur, nxt), control: cur)
            }
            path.closeSubpath()
        } else {
            let bw = max(1, (2 * .pi * r0) / CGFloat(n) * CGFloat(1 - max(0, min(0.9, c.spec.barGapFrac))))
            for i in 0..<n {
                let ang = rot + 2 * .pi * CGFloat(i) / CGFloat(n)
                let len = max(bw, maxLen * CGFloat(bands[i]))
                let d = CGPoint(x: cos(ang), y: sin(ang))
                let seg = CGMutablePath()
                seg.move(to: CGPoint(x: cx + d.x * r0, y: cy + d.y * r0))
                seg.addLine(to: CGPoint(x: cx + d.x * (r0 + len), y: cy + d.y * (r0 + len)))
                path.addPath(seg.copy(strokingWithWidth: bw, lineCap: .round, lineJoin: .round, miterLimit: 1))
            }
        }
        glowPass(cg, c, path)
        cg.saveGState()
        cg.addPath(path); cg.clip()
        if c.spec.gradientDir == .rainbow || c.spec.gradientDir == .across {
            paintRadialSweep(cg, c, cx: cx, cy: cy, r0: r0, rMax: r0 + maxLen)
        } else if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [c.spec.color1.nsColor.cgColor, c.spec.color2.nsColor.cgColor] as CFArray,
                                     locations: [0, 1]) {
            cg.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: r0,
                                  endCenter: CGPoint(x: cx, y: cy), endRadius: r0 + maxLen,
                                  options: [.drawsAfterEndLocation])
        }
        cg.restoreGState()
    }

    private static func paintRadialSweep(_ cg: CGContext, _ c: Ctx, cx: CGFloat, cy: CGFloat, r0: CGFloat, rMax: CGFloat) {
        // xấp xỉ "cầu vồng theo cột" bằng nhiều lát quạt
        let slices = 48
        let a1 = CGFloat(c.spec.color1.a)
        for s in 0..<slices {
            let a0 = CGFloat(s) / CGFloat(slices) * 2 * .pi
            let a1e = CGFloat(s + 1) / CGFloat(slices) * 2 * .pi
            let hue: CGFloat
            if c.spec.gradientDir == .rainbow {
                hue = (CGFloat(c.spec.rainbowShift) + CGFloat(s) / CGFloat(slices) * CGFloat(c.spec.rainbowSpread))
                    .truncatingRemainder(dividingBy: 1)
            } else {
                hue = 0  // .across không hợp radial → xài màu 1
            }
            let col = c.spec.gradientDir == .rainbow
                ? NSColor(hue: hue < 0 ? hue + 1 : hue, saturation: 0.85, brightness: 1, alpha: a1).cgColor
                : c.spec.color1.nsColor.cgColor
            cg.saveGState()
            cg.move(to: CGPoint(x: cx, y: cy))
            cg.addArc(center: CGPoint(x: cx, y: cy), radius: rMax, startAngle: a0, endAngle: a1e, clockwise: false)
            cg.closePath()
            cg.setFillColor(col); cg.fillPath()
            cg.restoreGState()
        }
    }

    // MARK: - Dải sóng phản chiếu (như mặt nước)

    private static func drawRibbonMirror(_ cg: CGContext, _ c: Ctx, _ bands: [Float]) {
        let n = bands.count
        guard n >= 2 else { return }
        func pt(_ i: Int) -> CGPoint {
            let t = CGFloat(i) / CGFloat(n - 1)
            return CGPoint(x: c.originX + t * c.regionW, y: c.baseY + CGFloat(bands[i]) * c.maxH)
        }
        let ridge = CGMutablePath()
        ridge.move(to: pt(0))
        for i in 1..<n {
            let a = pt(i - 1), b = pt(i)
            let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            ridge.addQuadCurve(to: m, control: a)
            if i == n - 1 { ridge.addQuadCurve(to: b, control: b) }
        }
        let fillTop = ridge.mutableCopy()!
        fillTop.addLine(to: CGPoint(x: c.originX + c.regionW, y: c.baseY))
        fillTop.addLine(to: CGPoint(x: c.originX, y: c.baseY))
        fillTop.closeSubpath()

        glowPass(cg, c, fillTop)
        cg.addPath(fillTop)
        paint(cg, c, bounds: CGRect(x: c.originX, y: c.baseY, width: c.regionW, height: c.maxH))

        // Bóng phản chiếu DƯỚI baseline — lật ngược khối vừa vẽ, mờ dần xuống.
        var t = CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(CGAffineTransform(translationX: 0, y: 2 * c.baseY))
        guard let fillBottom = fillTop.copy(using: &t) else { return }
        cg.saveGState()
        cg.addPath(fillBottom); cg.clip()
        let col = c.spec.color1.nsColor.cgColor
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [col.copy(alpha: 0.34) ?? col, col.copy(alpha: 0) ?? col] as CFArray,
                              locations: [0, 1]) {
            cg.drawLinearGradient(g, start: CGPoint(x: 0, y: c.baseY),
                                  end: CGPoint(x: 0, y: c.baseY - c.maxH),
                                  options: [])
        }
        cg.restoreGState()
    }

    // MARK: - Vòng sóng viền (glow, rỗng giữa)

    private static func drawRadialRing(_ cg: CGContext, _ c: Ctx, _ bands: [Float]) {
        let n = bands.count
        guard n >= 3 else { return }
        let cx = c.size.width / 2 + CGFloat(c.spec.offsetX) * c.size.width
        let cy = c.baseY + c.maxH
        let base = min(c.size.width, c.size.height)
        let r0 = base * 0.14
        let maxLen = base * CGFloat(c.spec.heightFrac) * 0.55
        let rot = CGFloat(c.spec.rotation) * .pi / 180

        var pts: [CGPoint] = []
        pts.reserveCapacity(n)
        for k in 0..<n {
            let ang = rot + 2 * .pi * CGFloat(k) / CGFloat(n)
            let rr = r0 + maxLen * CGFloat(0.15 + 0.85 * bands[k])
            pts.append(CGPoint(x: cx + cos(ang) * rr, y: cy + sin(ang) * rr))
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        let path = CGMutablePath()
        path.move(to: mid(pts[n - 1], pts[0]))
        for k in 0..<n {
            let cur = pts[k], nxt = pts[(k + 1) % n]
            path.addQuadCurve(to: mid(cur, nxt), control: cur)
        }
        path.closeSubpath()

        let lw = max(1.5, CGFloat(c.spec.lineWidthFrac) * c.size.height * 1.6)
        glowPass(cg, c, path, stroke: lw)
        let stroked = path.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 2)
        cg.saveGState()
        cg.addPath(stroked); cg.clip()
        if c.spec.gradientDir == .rainbow || c.spec.gradientDir == .across {
            paintRadialSweep(cg, c, cx: cx, cy: cy, r0: r0 * 0.6, rMax: r0 + maxLen)
        } else if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [c.spec.color1.nsColor.cgColor, c.spec.color2.nsColor.cgColor] as CFArray,
                                     locations: [0, 1]) {
            cg.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: r0 * 0.6,
                                  endCenter: CGPoint(x: cx, y: cy), endRadius: r0 + maxLen,
                                  options: [.drawsAfterEndLocation])
        }
        cg.restoreGState()
    }

    // MARK: - Cột lấp lánh / Cột viền neon

    private static func drawSparkleBars(_ cg: CGContext, _ c: Ctx, _ bands: [Float]) {
        drawBars(cg, c, bands, mirror: false)
        let n = bands.count
        let (slot, _, bw) = barGeom(c, n)
        let sparkPath = CGMutablePath()
        for i in 0..<n {
            let amt = CGFloat(bands[i])
            guard amt > 0.18 else { continue }
            let h = max(bw * 0.30, c.maxH * amt)
            let x = c.originX + CGFloat(i) * slot + slot / 2
            let tipY = c.baseY + h
            let count = 1 + Int(amt * 2.2)
            for k in 0..<count {
                let seed = CGFloat((i * 7 + k * 13) % 23) / 23
                let dx = (seed - 0.5) * bw * 1.6
                let dy = 6 + seed * c.maxH * 0.16 * CGFloat(k + 1)
                let r = max(1, bw * 0.10 * (1 - CGFloat(k) * 0.28))
                sparkPath.addEllipse(in: CGRect(x: x + dx - r, y: tipY + dy - r, width: r * 2, height: r * 2))
            }
        }
        guard !sparkPath.isEmpty else { return }
        glowPass(cg, c, sparkPath)
        cg.saveGState()
        cg.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        cg.addPath(sparkPath); cg.fillPath()
        cg.restoreGState()
    }

    private static func drawNeonBars(_ cg: CGContext, _ c: Ctx, _ bands: [Float]) {
        let n = bands.count
        let (slot, gap, bw) = barGeom(c, n)
        let radius = min(bw / 2, bw * CGFloat(max(0, min(0.5, c.spec.cornerRadiusFrac))))
        let lw = max(1.2, bw * 0.16)
        let path = CGMutablePath()
        var tips: [(CGPoint, CGFloat)] = []
        for i in 0..<n {
            let h = max(bw * 0.30, c.maxH * CGFloat(bands[i]))
            let x = c.originX + CGFloat(i) * slot + gap / 2
            let r = CGRect(x: x, y: c.baseY, width: bw, height: h).insetBy(dx: lw / 2, dy: lw / 2)
            let rad = max(0, min(radius, r.height / 2, r.width / 2))
            path.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
            tips.append((CGPoint(x: r.midX, y: r.maxY), bw * 0.42))
        }
        glowPass(cg, c, path, stroke: lw)
        let stroked = path.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 2)
        cg.addPath(stroked)
        paint(cg, c, bounds: CGRect(x: c.originX, y: c.baseY, width: c.regionW, height: c.maxH))
        tipDots(cg, c, centers: tips)
    }

    // MARK: - Tiện ích

    private static func resample(_ src: [Float], to want: Int) -> [Float] {
        guard !src.isEmpty else { return [Float](repeating: 0, count: want) }
        if src.count == want { return src }
        var out = [Float](repeating: 0, count: want)
        for i in 0..<want {
            let a = Int(Double(i) * Double(src.count) / Double(want))
            let b = max(a + 1, Int(Double(i + 1) * Double(src.count) / Double(want)))
            var s: Float = 0; var n = 0
            for k in a..<min(b, src.count) { s += src[k]; n += 1 }
            out[i] = n > 0 ? s / Float(n) : src[min(src.count - 1, a)]
        }
        return out
    }

    private static func smooth(_ v: inout [Float], amount: Double) {
        let a = Float(max(0, min(1, amount)))
        guard a > 0.01, v.count >= 3 else { return }
        let passes = 1 + Int(a * 2)
        for _ in 0..<passes {
            var out = v
            for i in 1..<v.count - 1 {
                out[i] = v[i] * (1 - a) + (v[i - 1] + v[i + 1]) * 0.5 * a
            }
            v = out
        }
    }

    private static func applySensitivity(_ v: inout [Float], _ s: Double) {
        let s = Float(max(0.1, min(4, s)))
        guard s != 1 else { return }
        for i in v.indices { v[i] = min(1.15, v[i] * s) }
    }
}
