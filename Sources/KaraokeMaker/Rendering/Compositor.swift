import AppKit
import CoreGraphics
import ImageIO
import AVFoundation

/// Ghép các LỚP của một khung hình — dùng CHUNG cho Preview và Export.
///
/// - Lớp **nền** (`backgroundLayers…`) vẽ TRƯỚC chữ karaoke.
/// - Lớp **overlay** (`overlayLayers`) vẽ SAU chữ (đè lên trên, kiểu track phía trên của CapCut).
///
/// Mọi blend mode / chỉnh vị trí / nhiều lớp về sau chỉ cắm vào đây, không rải rác
/// giữa `KaraokePreview` và `VideoFrameWriter`.
enum Compositor {

    // MARK: - Kiểu dữ liệu lớp

    /// Chế độ hoà trộn lớp.
    enum Blend: String, CaseIterable, Equatable {
        case normal, multiply, screen, overlay, softLight, hardLight
        case lighten, darken, difference, exclusion

        var cg: CGBlendMode {
            switch self {
            case .normal:     return .normal
            case .multiply:   return .multiply
            case .screen:     return .screen
            case .overlay:    return .overlay
            case .softLight:  return .softLight
            case .hardLight:  return .hardLight
            case .lighten:    return .lighten
            case .darken:     return .darken
            case .difference: return .difference
            case .exclusion:  return .exclusion
            }
        }

        /// Nhãn tiếng Việt cho picker.
        var label: String {
            switch self {
            case .normal: return "Thường"
            case .multiply: return "Multiply"
            case .screen: return "Screen"
            case .overlay: return "Overlay"
            case .softLight: return "Soft Light"
            case .hardLight: return "Hard Light"
            case .lighten: return "Lighten"
            case .darken: return "Darken"
            case .difference: return "Difference"
            case .exclusion: return "Exclusion"
            }
        }
    }

    /// Cách khớp ảnh vào khung.
    /// fill = phủ kín (nền) · fit = vừa khung (overlay/logo) · native = pixel ảnh quy chiếu
    /// theo khung 1080 (dùng cho lớp CHỮ: giữ đúng cỡ pt, không phóng đầy khung).
    enum Fit { case fill, fit, native }

    struct Layer {
        enum Content {
            case solid(CGColor)
            case checker
            case image(CGImage)
        }
        var content: Content
        var opacity: CGFloat = 1
        var blend: Blend = .normal
        // Chỉ dùng cho `.image`:
        var fit: Fit = .fill
        var scale: CGFloat = 1            // nhân thêm vào kích thước cơ sở (fill/fit)
        var offsetX: CGFloat = 0          // lệch tâm theo PHẦN bề rộng canvas (-1…1)
        var offsetY: CGFloat = 0          // lệch tâm theo PHẦN chiều cao canvas
        var rotationDeg: CGFloat = 0
    }

    // MARK: - Dựng danh sách lớp NỀN

    static func previewBackgroundLayers(project: KaraokeProject?,
                                        background: PreviewBackground,
                                        backgroundImage: CGImage?,
                                        suppressMediaFill: Bool,
                                        time: TimeInterval = 0,
                                        duration: TimeInterval = 0,
                                        beatEnergy: Float = 0) -> [Layer] {
        switch background {
        case .dark:
            return [Layer(content: .solid(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))]
        case .gray:
            return [Layer(content: .solid(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)))]
        case .checker:
            return [Layer(content: .checker)]
        case .media:
            if suppressMediaFill { return [] }
            var layers: [Layer] = [Layer(content: .solid(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))]
            if let img = backgroundImage, let m = project?.backgroundMedia {
                layers.append(contentsOf: mediaImageLayers(img, m, time: time, duration: duration, beatEnergy: beatEnergy))
            }
            return layers
        }
    }

    static func exportBackgroundLayers(project: KaraokeProject,
                                       solidBackground: CGColor?,
                                       backdrop: CGImage?,
                                       time: TimeInterval = 0,
                                       duration: TimeInterval = 0,
                                       beatEnergy: Float = 0) -> [Layer] {
        guard solidBackground != nil || backdrop != nil else { return [] }
        var layers: [Layer] = [
            Layer(content: .solid(solidBackground ?? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
        ]
        if let backdrop, let m = project.backgroundMedia {
            layers.append(contentsOf: mediaImageLayers(backdrop, m, time: time, duration: duration, beatEnergy: beatEnergy))
        } else if let backdrop {
            layers.append(Layer(content: .image(backdrop), fit: .fill))
        }
        return layers
    }

    /// Ảnh nền → 1–2 lớp: (mờ lấp 2 bên nếu bật) + ảnh chính, kèm chỉnh màu + Ken Burns.
    /// `beatEnergy` (0…1, mượt) = năng lượng nhạc tại `time` — nhân thêm vào scale khi
    /// `m.beatZoomEnabled` (nền "thở" theo nhịp, xem `SpectrumData.energy`).
    private static func mediaImageLayers(_ base: CGImage, _ m: BackgroundMedia,
                                         time: TimeInterval, duration: TimeInterval,
                                         beatEnergy: Float = 0) -> [Layer] {
        let proc = BackgroundImageStore.processed(base: base, adjust: m.colorAdjust, needBlur: m.blurFill)

        // Ken Burns: phóng + lia CHẬM tuyến tính theo tiến độ bài.
        var kbScale: CGFloat = 1, kbX: CGFloat = 0, kbY: CGFloat = 0
        if m.kenBurns, duration > 0.5 {
            let p = CGFloat(max(0, min(1, time / duration)))
            let amt = CGFloat(m.kenBurnsAmount)
            kbScale = 1 + amt * p
            kbX = amt * 0.18 * (p - 0.5)
            kbY = amt * 0.10 * (p - 0.5)
        }
        // Zoom theo nhạc: phóng thêm 0…(amount−1) theo năng lượng hiện tại (đã mượt sẵn).
        let beatScale: CGFloat = m.beatZoomEnabled
            ? 1 + CGFloat(max(0, m.beatZoomAmount - 1)) * CGFloat(max(0, min(1, beatEnergy)))
            : 1
        let scale = CGFloat(m.scale) * kbScale * beatScale
        let offX = CGFloat(m.offsetX) + kbX
        let offY = CGFloat(m.offsetY) + kbY

        var out: [Layer] = []
        if m.blurFill, let blur = proc.blur {
            out.append(Layer(content: .image(blur), opacity: 1, blend: .normal,
                             fit: .fill, scale: scale * 1.06, offsetX: offX, offsetY: offY))
        }
        out.append(Layer(content: .image(proc.main), opacity: CGFloat(m.opacity), blend: .normal,
                         fit: m.blurFill ? .fit : .fill, scale: scale, offsetX: offX, offsetY: offY))
        return out
    }

    // MARK: - Dựng danh sách lớp OVERLAY

    /// Các clip overlay đang hiện tại `time` (không ẩn, đang trong `[start,end]`), theo thứ tự lane rồi z.
    /// Chọn lớp đè theo vị trí so với chữ.
    enum OverlayZone { case all, belowText, aboveText }

    /// `videoFrame`: khi XUẤT, bên gọi truyền hàm lấy khung video CHÍNH XÁC (đọc tuần tự).
    /// Không truyền (Preview) → dùng `OverlayVideoFrameStore` (trích xuất nền, có cache).
    static func overlayLayers(project: KaraokeProject, time: TimeInterval,
                              zone: OverlayZone = .all, excluding: Set<UUID> = [],
                              videoFrame: ((OverlayClip, TimeInterval) -> CGImage?)? = nil) -> [Layer] {
        if project.overlays.isEmpty { return [] }          // khỏi filter/sort mỗi khung
        let active = project.overlays
            .filter {
                !$0.isHidden && !excluding.contains($0.id) && time >= $0.start && time < $0.end
                && (zone == .all || (zone == .aboveText) == $0.aboveText)
            }
            .sorted { $0.lane != $1.lane ? $0.lane < $1.lane : ($0.start < $1.start) }
        var out: [Layer] = []
        for clip in active {
            var img: CGImage?
            if clip.kind == .video {
                // (M-E) cộng điểm vào nguồn `trimStart`.
                let vt = max(0, clip.trimStart + (time - clip.start))
                if let provide = videoFrame {
                    img = provide(clip, vt)
                } else if let url = clip.resolveURL() {
                    img = OverlayVideoFrameStore.frame(path: clip.lastKnownPath, url: url, t: vt)
                } else {
                    img = nil
                }
                // C6 — chỉnh màu cho khung VIDEO (ảnh tĩnh đã xử trong OverlayImageStore).
                if let f = img, !clip.colorAdjust.isIdentity {
                    img = ImageFX.apply(f, clip.colorAdjust)
                }
            } else if clip.kind == .text {
                img = OverlayTextStore.image(for: clip)
            } else {
                img = OverlayImageStore.image(for: clip)
            }
            guard let img else { continue }
            let inLocal = time - clip.start
            let toEnd = clip.end - time
            // Chuyển động (keyframe) — nội suy biến hình + độ mờ theo thời điểm trong clip.
            let kf = clip.transform(atLocal: inLocal)

            // Độ mờ = độ mờ cơ sở (keyframe HOẶC tĩnh) × hiện/mờ dần 2 đầu.
            var op = CGFloat(kf.opacity)
            if clip.fadeIn > 0.01, inLocal < clip.fadeIn {
                op *= CGFloat(max(0, min(1, inLocal / clip.fadeIn)))
            }
            if clip.fadeOut > 0.01, toEnd < clip.fadeOut {
                op *= CGFloat(max(0, min(1, toEnd / clip.fadeOut)))
            }

            // Lớp CHỮ: hiệu ứng VÀO / RA (fade / trượt lên / bật) — biến hình theo thời gian.
            var exScale: CGFloat = 1, exDX: CGFloat = 0, exDY: CGFloat = 0
            if clip.kind == .text {
                let dur = max(0.05, clip.textEffectDur)
                if clip.textEntrance != .none, inLocal >= 0, inLocal < dur {
                    let (a, dx, dy, sc) = Self.textEffectXform(clip.textEntrance, p: inLocal / dur)
                    op *= a; exDX += dx; exDY += dy; exScale *= sc
                } else if clip.textExit != .none, toEnd >= 0, toEnd < dur {
                    let (a, dx, dy, sc) = Self.textEffectXform(clip.textExit, p: toEnd / dur)
                    op *= a; exDX += dx; exDY += dy; exScale *= sc
                }
            }
            out.append(Layer(content: .image(img),
                             opacity: op, blend: clip.blend,
                             fit: clip.kind == .text ? .native : .fit,
                             scale: CGFloat(kf.scale) * exScale,
                             offsetX: CGFloat(kf.offX) + exDX, offsetY: CGFloat(kf.offY) + exDY,
                             rotationDeg: CGFloat(kf.rot)))
        }
        return out
    }

    /// Biến hình hiệu ứng chữ VÀO/RA theo tiến độ `p` (0→1 = chưa hiện → hiện đủ).
    /// Trả (alpha, lệchX-phần-canvas, lệchY-phần-canvas, nhân-cỡ).
    private static func textEffectXform(_ e: TextEffect, p rawP: Double)
        -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let p = max(0, min(1, rawP))
        let k = CGFloat(1 - pow(1 - p, 2))          // easeOut
        switch e {
        case .none: return (1, 0, 0, 1)
        case .fade: return (k, 0, 0, 1)
        case .rise: return (k, 0, (1 - k) * 0.08, 1)   // bắt đầu thấp hơn ~8% chiều cao rồi trượt lên
        case .pop:  return (k, 0, 0, 0.72 + 0.28 * k)
        }
    }

    /// Chữ nhật của một lớp đè trong TOẠ ĐỘ VIEW (y-DOWN, gốc trên-trái) — để hit-test + vẽ gizmo.
    static func overlayViewRect(image: CGImage?, canvasSize: CGSize,
                                scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat,
                                fit: Fit = .fit) -> CGRect {
        let imgSize: CGSize
        if let image { imgSize = CGSize(width: image.width, height: image.height) }
        else { imgSize = CGSize(width: 400, height: 400) }   // chưa có ảnh → ô vuông tạm
        let up = destRect(imageSize: imgSize, canvas: canvasSize, fit: fit,
                          scale: scale, offsetX: offsetX, offsetY: offsetY)
        return CGRect(x: up.minX, y: canvasSize.height - up.maxY, width: up.width, height: up.height)
    }

    // MARK: - Vẽ

    /// `flipped == true`  → context đang y-DOWN (view `isFlipped` Preview, hoặc export SAU khi lật cho chữ).
    /// `flipped == false` → context đang y-UP, gốc dưới-trái (export TRƯỚC khi lật).
    static func draw(_ layers: [Layer], in cg: CGContext, canvasSize: CGSize, flipped: Bool) {
        guard canvasSize.width > 0, canvasSize.height > 0, !layers.isEmpty else { return }
        let full = CGRect(origin: .zero, size: canvasSize)

        for layer in layers {
            cg.saveGState()
            cg.setAlpha(layer.opacity)
            cg.setBlendMode(layer.blend.cg)

            switch layer.content {
            case .solid(let c):
                cg.setFillColor(c); cg.fill(full)

            case .checker:
                drawChecker(in: cg, size: canvasSize)

            case .image(let img):
                if flipped {
                    cg.translateBy(x: 0, y: canvasSize.height)
                    cg.scaleBy(x: 1, y: -1)
                }
                // Hệ toạ độ giờ là y-UP. Tính chữ nhật đích trong y-UP.
                let dest = destRect(imageSize: CGSize(width: img.width, height: img.height),
                                    canvas: canvasSize, fit: layer.fit, scale: layer.scale,
                                    offsetX: layer.offsetX, offsetY: layer.offsetY)
                if layer.rotationDeg != 0 {
                    let cx = dest.midX, cy = dest.midY
                    cg.translateBy(x: cx, y: cy)
                    cg.rotate(by: layer.rotationDeg * .pi / 180)
                    cg.translateBy(x: -cx, y: -cy)
                }
                cg.draw(img, in: dest)
            }
            cg.restoreGState()
        }
    }

    /// Chữ nhật đích (hệ y-UP) cho một ảnh.
    private static func destRect(imageSize: CGSize, canvas: CGSize, fit: Fit,
                                 scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGRect(origin: .zero, size: canvas) }
        let base: CGFloat
        switch fit {
        case .fill: base = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        case .fit:  base = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        case .native: base = min(canvas.width, canvas.height) / 1080
        }
        let s = base * max(0.02, scale)
        let w = imageSize.width * s
        let h = imageSize.height * s
        // Giữ ĐÚNG quy ước cũ của BackgroundMedia: +offsetX = phải, +offsetY = XUỐNG.
        let cx = canvas.width / 2 + offsetX * canvas.width
        let cy = canvas.height / 2 - offsetY * canvas.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    static func drawChecker(in cg: CGContext, size: CGSize) {
        let tile: CGFloat = 14
        let light = CGColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1)
        let dark = CGColor(srgbRed: 0.68, green: 0.68, blue: 0.68, alpha: 1)
        var y: CGFloat = 0, row = 0
        while y < size.height {
            var x: CGFloat = 0, col = 0
            while x < size.width {
                cg.setFillColor((row + col) % 2 == 0 ? light : dark)
                cg.fill(CGRect(x: x, y: y, width: tile, height: tile))
                x += tile; col += 1
            }
            y += tile; row += 1
        }
    }
}

// MARK: - Cache ảnh overlay (giải mã 1 lần / đường dẫn)

enum OverlayImageStore {
    private static var raw: [String: CGImage] = [:]        // path -> ảnh giải mã
    private static var adjusted: [String: CGImage] = [:]   // "path#adjKey" -> ảnh đã chỉnh màu
    private static let lock = NSLock()

    static func image(for clip: OverlayClip) -> CGImage? {
        guard clip.kind == .image, !clip.lastKnownPath.isEmpty else { return nil }
        let path = clip.lastKnownPath
        let adj = clip.colorAdjust
        let akey = path + "#" + adj.key

        lock.lock()
        if let a = adjusted[akey] { lock.unlock(); return a }
        var base = raw[path]
        lock.unlock()

        if base == nil {
            guard let url = clip.resolveURL(),
                  let cg = decode(url) else { return nil }
            base = cg
            lock.lock()
            if raw.count > 24 { raw.removeAll(keepingCapacity: true) }
            raw[path] = cg
            lock.unlock()
        }
        guard let b = base else { return nil }
        let out = adj.isIdentity ? b : ImageFX.apply(b, adj)
        lock.lock()
        if adjusted.count > 24 { adjusted.removeAll(keepingCapacity: true) }
        adjusted[akey] = out
        lock.unlock()
        return out
    }

    static func flush() {
        lock.lock(); raw.removeAll(); adjusted.removeAll(); lock.unlock()
        OverlayVideoFrameStore.flush()
        VideoFilmstripStore.flush()
        OverlayTextStore.flush()
    }

    /// Giải mã ảnh lớp đè, chặn cạnh dài 3840px — vẽ lại mỗi khung preview nhẹ hơn hẳn.
    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - Cache LỚP CHỮ (kind == .text) — rasterise 1 lần / nội dung, an toàn chạy nền

enum OverlayTextStore {
    private static var cache: [String: CGImage] = [:]
    private static let lock = NSLock()

    static func flush() { lock.lock(); cache.removeAll(); lock.unlock() }

    private static func fillSig(_ f: ColorFill) -> String {
        f.style.rawValue + ":" + f.effectiveStops.map { "\($0.color.hexRGBA)@\(Int($0.loc * 100))" }
            .joined(separator: ",") + "|\(Int(f.angle))"
    }

    private static func sig(_ c: OverlayClip) -> String {
        [c.text, c.textFontName, "\(Int(c.textFontSize * 100))", "\(c.textBold)", "\(c.textItalic)",
         "\(Int(c.textLineSpacing * 10))", "\(Int(c.textCharSpacing * 10))", "\(Int(c.textWrapFrac * 100))",
         fillSig(c.textFill), fillSig(c.textOutlineFill), "\(Int(c.textOutlineWidth * 100))",
         c.textAlignRaw,
         fillSig(c.textBackgroundFill),
         fillSig(c.textShadowFill), "\(Int(c.textShadowRadius * 10))",
         "\(Int(c.textShadowDX * 10))", "\(Int(c.textShadowDY * 10))",
         fillSig(c.textGlowFill), "\(Int(c.textGlowRadius * 10))"].joined(separator: "\u{1}")
    }

    static func image(for clip: OverlayClip) -> CGImage? {
        guard clip.kind == .text else { return nil }
        let key = sig(clip)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let img = render(clip) else { return nil }
        lock.lock()
        if cache.count > 48 { cache.removeAll(keepingCapacity: true) }
        cache[key] = img
        lock.unlock()
        return img
    }

    /// Vẽ chữ bằng Core Text vào bitmap CGContext thuần (không NSGraphicsContext) — an toàn
    /// khi chạy nền (xuất video). Ảnh trả về top-down như các CGImage khác trong app.
    private static func render(_ clip: OverlayClip) -> CGImage? {
        let raw = clip.text.isEmpty ? " " : clip.text
        var font = NSFont(name: clip.textFontName, size: CGFloat(max(4, clip.textFontSize)))
            ?? NSFont.systemFont(ofSize: CGFloat(max(4, clip.textFontSize)))
        let fm = NSFontManager.shared
        if clip.textBold { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        if clip.textItalic { font = fm.convert(font, toHaveTrait: .italicFontMask) }

        let para = NSMutableParagraphStyle()
        para.alignment = clip.textAlign.nsTextAlignment
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = CGFloat(max(0, clip.textLineSpacing))

        let fill = clip.textFill
        let oFill = clip.textOutlineFill
        let hasOutline = clip.textOutlineWidth > 0.01 && oFill.maxAlpha > 0.001
        let ow = CGFloat(max(0, clip.textOutlineWidth))
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: para, .foregroundColor: fill.primary.nsColor,
        ]
        if clip.textCharSpacing != 0 { attrs[.kern] = CGFloat(clip.textCharSpacing) }
        // Viền LUÔN vẽ bằng path-stroke bo góc tròn (giống chữ karaoke) — hết "gãy góc".
        let attr = NSAttributedString(string: raw, attributes: attrs)

        let maxW: CGFloat = CGFloat(max(0.15, min(1.0, clip.textWrapFrac))) * 1920
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let sz = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil, CGSize(width: maxW, height: 6000), nil)
        let tw = max(2, ceil(sz.width)), th = max(2, ceil(sz.height))

        let bgFill = clip.textBackgroundFill
        let hasBg = bgFill.maxAlpha > 0.001
        let bgPad: CGFloat = hasBg ? CGFloat(clip.textFontSize) * 0.32 : 0
        let shFill = clip.textShadowFill
        let glFill = clip.textGlowFill
        let hasSh = shFill.maxAlpha > 0.001
        let hasGl = glFill.maxAlpha > 0.001
        let shPad: CGFloat = hasSh
            ? CGFloat(clip.textShadowRadius) + max(abs(CGFloat(clip.textShadowDX)), abs(CGFloat(clip.textShadowDY))) : 0
        let glPad: CGFloat = hasGl ? CGFloat(clip.textGlowRadius) * 1.6 : 0
        let pad = ceil(ow + 16 + bgPad + max(shPad, glPad))
        let W = Int(tw + pad * 2), H = Int(th + pad * 2)
        guard W > 2, H > 2, W < 8000, H < 8000 else { return nil }

        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: info) else { return nil }
        cg.setShouldAntialias(true)
        cg.setShouldSmoothFonts(true)

        // CTFrameDraw cần context y-UP (origin dưới-trái) — vẽ trực tiếp, KHÔNG lật.
        // `CGBitmapContext.makeImage()` trả CGImage top-down như ảnh file → `Compositor.draw`
        // (đường `.image`) vẽ đúng chiều y hệt lớp ảnh thường.
        let boxRect = CGRect(x: pad, y: pad, width: tw, height: th)
        let box = CGPath(rect: boxRect, transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), box, nil)

        if hasBg {
            let r = boxRect.insetBy(dx: -bgPad, dy: -bgPad)
            cg.saveGState()
            cg.addPath(CGPath(roundedRect: r, cornerWidth: bgPad, cornerHeight: bgPad, transform: nil))
            if bgFill.isSolid || bgFill.color == bgFill.color2 {
                cg.setFillColor(bgFill.flatColor.nsColor.cgColor); cg.fillPath()
            } else {
                bgFill.fillCurrentPath(in: cg, bounds: r, flipY: true)
            }
            cg.restoreGState()
        }
        // Glow: đơn sắc = 2 lượt CTFrameDraw + setShadow; gradient = mask mềm + gradient.
        if hasGl, clip.textGlowRadius > 0 {
            if glFill.isFlat {
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: CGFloat(clip.textGlowRadius),
                             color: glFill.flatColor.nsColor.cgColor)
                for _ in 0..<2 { CTFrameDraw(frame, cg) }
                cg.restoreGState()
            } else {
                glFill.drawSoftGlow(shape: framePath(frame, origin: boxRect.origin), in: cg, layerSize: CGSize(width: W, height: H),
                                    bounds: boxRect, offset: .zero,
                                    blur: CGFloat(clip.textGlowRadius), yUp: true)
            }
        }
        // Bóng đổ (y-UP: + DY của người dùng = XUỐNG = -y).
        if hasSh {
            let off = CGSize(width: CGFloat(clip.textShadowDX), height: -CGFloat(clip.textShadowDY))
            if shFill.isFlat {
                cg.saveGState()
                cg.setShadow(offset: off, blur: CGFloat(max(0, clip.textShadowRadius)),
                             color: shFill.flatColor.nsColor.cgColor)
                CTFrameDraw(frame, cg)
                cg.restoreGState()
            } else {
                shFill.drawSoftGlow(shape: framePath(frame, origin: boxRect.origin), in: cg, layerSize: CGSize(width: W, height: H),
                                    bounds: boxRect, offset: off,
                                    blur: CGFloat(max(0, clip.textShadowRadius)), yUp: true)
            }
        }

        let gpath = framePath(frame, origin: boxRect.origin)
        // Viền: làm dày path glyph (nối góc TRÒN + đầu TRÒN như chữ karaoke) rồi tô.
        if hasOutline {
            cg.saveGState()
            cg.addPath(gpath)
            cg.setLineWidth(ow * 2); cg.setLineJoin(.round); cg.setLineCap(.round)
            cg.replacePathWithStrokedPath()
            if oFill.isFlat {
                cg.setFillColor(oFill.flatColor.nsColor.cgColor); cg.fillPath()
            } else {
                oFill.fillCurrentPath(in: cg, bounds: boxRect, flipY: true)
            }
            cg.restoreGState()
        }
        // Tô chữ ĐÈ LÊN viền: đơn sắc → CTFrameDraw (nét mượt); gradient → kẹp path glyph.
        if fill.isFlat {
            CTFrameDraw(frame, cg)
        } else {
            cg.saveGState()
            cg.addPath(gpath)
            fill.fillCurrentPath(in: cg, bounds: boxRect, flipY: true)
            cg.restoreGState()
        }
        return cg.makeImage()
    }

    /// Gộp path mọi glyph của 1 CTFrame (hệ toạ độ context, y-UP).
    /// `origin` = gốc của khung path đưa vào `CTFramesetterCreateFrame` — line-origin của
    /// Core Text tính TỪ (0,0), phải cộng lại thì mới TRÙNG với `CTFrameDraw`.
    private static func framePath(_ frame: CTFrame, origin: CGPoint = .zero) -> CGPath {
        let combined = CGMutablePath()
        let linesCF = CTFrameGetLines(frame)
        let n = CFArrayGetCount(linesCF)
        guard n > 0 else { return combined }
        var origins = [CGPoint](repeating: .zero, count: n)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for li in 0..<n {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(linesCF, li), to: CTLine.self)
            let lo = origins[li]
            let runs = CTLineGetGlyphRuns(line)
            for ri in 0..<CFArrayGetCount(runs) {
                let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, ri), to: CTRun.self)
                let gc = CTRunGetGlyphCount(run)
                guard gc > 0 else { continue }
                guard let fv = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String]
                else { continue }
                let runFont = fv as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: gc)
                var pos = [CGPoint](repeating: .zero, count: gc)
                CTRunGetGlyphs(run, CFRange(location: 0, length: gc), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: gc), &pos)
                for i in 0..<gc {
                    guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                    combined.addPath(gp, transform: CGAffineTransform(
                        translationX: origin.x + lo.x + pos[i].x, y: origin.y + lo.y + pos[i].y))
                }
            }
        }
        return combined
    }
}

// MARK: - Khung video lớp đè cho PREVIEW (trích xuất nền + cache, không chặn render)

enum OverlayVideoFrameStore {
    /// FPS lưới cache khung preview (30 = mượt như video; export dùng đường đọc tuần tự riêng).
    private static let grid = 30.0

    private final class Entry {
        let gen: AVAssetImageGenerator
        var cache: [Int: CGImage] = [:]     // key = Int(t*grid) → khung
        var pending: Set<Int> = []
        init(url: URL) {
            let asset = AVURLAsset(url: url)
            gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
            gen.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 60)
            gen.maximumSize = CGSize(width: 1920, height: 1920)
        }
    }
    private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()
    private static let q = DispatchQueue(label: "km.overlay.videoframe", qos: .userInitiated, attributes: .concurrent)

    /// Khung gần nhất ĐANG CÓ cho video `path` tại `t` giây (t = thời gian TRONG video).
    /// Chưa có khung đúng → trả khung gần nhất (đỡ nhấp nháy) + trích xuất nền + NHÌN TRƯỚC ~0.4s.
    static func frame(path: String, url: URL, t: Double) -> CGImage? {
        let key = max(0, Int((t * grid).rounded()))
        lock.lock()
        let e: Entry
        if let existing = entries[path] { e = existing }
        else { e = Entry(url: url); entries[path] = e }
        let exact = e.cache[key]
        let near = exact ?? e.cache.min(by: { abs($0.key - key) < abs($1.key - key) })?.value
        // Xếp hàng khung hiện tại + vài khung kế (nhìn trước).
        var toFetch: [Int] = []
        for k in key...(key + 12) where e.cache[k] == nil && !e.pending.contains(k) {
            e.pending.insert(k); toFetch.append(k)
        }
        lock.unlock()
        if exact != nil, toFetch.isEmpty { return near }

        for k in toFetch {
            q.async {
                let cmt = CMTime(seconds: Double(k) / grid, preferredTimescale: 600)
                let img = try? e.gen.copyCGImage(at: cmt, actualTime: nil)
                lock.lock()
                e.pending.remove(k)
                if let img {
                    if e.cache.count > 240 {
                        // giữ vùng quanh key hiện tại, bỏ phần xa.
                        e.cache = e.cache.filter { abs($0.key - key) < 120 }
                    }
                    e.cache[k] = img
                }
                lock.unlock()
            }
        }
        return near
    }

    static func flush() { lock.lock(); entries.removeAll(); lock.unlock() }
}

// MARK: - Filmstrip NHIỀU khung cho clip video trên TIMELINE (khác cache scrubbing ở trên —
// cache đó ưu tiên đè khung xa lúc phát, không hợp để giữ nhiều khung rải khắp clip cùng lúc).

enum VideoFilmstripStore {
    /// Số khung lấy cho MỖI clip — cố định, không phụ thuộc độ rộng vẽ (đỡ phải lấy lại khi
    /// zoom/cuộn timeline). Vẽ sẽ tự rải đều số khung này ra bao nhiêu "lát" đang hiển thị.
    static let frameCount = 6

    private final class Entry {
        var frames: [Int: CGImage] = [:]
        var requested = false
    }
    private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()
    private static let q = DispatchQueue(label: "km.overlay.filmstrip", qos: .utility)

    /// Khung tại lát thứ `index` (0..<frameCount) của clip `path`, lấy đều trong đoạn
    /// [trimStart, trimEnd] giây TRONG video gốc. Chưa có → xếp hàng lấy CẢ BỘ 1 lần (chỉ 1 lần
    /// cho mỗi clip, kể cả khi nhiều lát cùng gọi lúc vẽ).
    static func frame(path: String, url: URL, trimStart: Double, trimEnd: Double, index: Int) -> CGImage? {
        lock.lock()
        let e: Entry
        if let existing = entries[path] { e = existing } else { e = Entry(); entries[path] = e }
        let img = e.frames[index]
        let alreadyRequested = e.requested
        e.requested = true
        lock.unlock()
        guard !alreadyRequested else { return img }

        let dur = max(0.05, trimEnd - trimStart)
        let times: [NSValue] = (0..<frameCount).map { i in
            let frac = frameCount == 1 ? 0.0 : Double(i) / Double(frameCount - 1)
            return NSValue(time: CMTime(seconds: trimStart + frac * dur, preferredTimescale: 600))
        }
        q.async {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 200)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            gen.generateCGImagesAsynchronously(forTimes: times) { requestedTime, cg, _, result, _ in
                guard let cg, result == .succeeded,
                      let i = times.firstIndex(where: { $0.timeValue == requestedTime }) else { return }
                lock.lock()
                entries[path]?.frames[i] = cg
                lock.unlock()
            }
        }
        return img
    }

    static func flush() { lock.lock(); entries.removeAll(); lock.unlock() }
}
