import AppKit
import CoreGraphics

/// Biểu tượng người hát dạng VECTOR (đường Bézier, xem `SingerIconPaths`) — tô được MÀU bất kỳ
/// (màu từng vai trong "Song ca", giống màu chữ karaoke), sắc nét mọi kích cỡ (preview, timeline,
/// xuất video). Toạ độ vẽ theo hệ trục y HƯỚNG XUỐNG (context của renderer + view timeline).
enum SingerIcon {

    private static let lock = NSLock()
    private static var pathCache: [SingerRole: CGPath] = [:]

    /// Tỉ lệ rộng/cao của icon (giữ nguyên tỉ lệ ảnh gốc).
    static func aspect(_ role: SingerRole) -> CGFloat {
        switch role {
        case .male:   return SingerIconPaths.maleAspect
        case .female: return SingerIconPaths.femaleAspect
        case .duet:   return SingerIconPaths.duetAspect
        }
    }

    /// Đường vector trong hộp đơn vị 0…1 (y xuống).
    static func path(_ role: SingerRole) -> CGPath {
        lock.lock(); defer { lock.unlock() }
        if let hit = pathCache[role] { return hit }
        let src: String
        switch role {
        case .male:   src = SingerIconPaths.male
        case .female: src = SingerIconPaths.female
        case .duet:   src = SingerIconPaths.duet
        }
        let p = parse(src)
        pathCache[role] = p
        return p
    }

    /// Tô icon vào `rect` (context y-XUỐNG) bằng `color`. Lỗ (tóc/cổ áo/khe ngón) = quy tắc even-odd.
    static func draw(_ role: SingerRole, in cg: CGContext, rect: CGRect, color: CGColor) {
        guard rect.width > 0, rect.height > 0 else { return }
        var t = CGAffineTransform(a: rect.width, b: 0, c: 0, d: rect.height, tx: rect.minX, ty: rect.minY)
        guard let p = path(role).copy(using: &t) else { return }
        cg.saveGState()
        cg.setFillColor(color)
        cg.addPath(p)
        cg.fillPath(using: .evenOdd)
        cg.restoreGState()
    }

    /// NSImage vẽ vector theo yêu cầu (sắc nét ở mọi cỡ) — cho SwiftUI `Image(nsImage:)`.
    static func image(_ role: SingerRole, height: CGFloat = 40, color: NSColor) -> NSImage {
        let h = max(1, height)
        let cgc = color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor
        return NSImage(size: NSSize(width: h * aspect(role), height: h), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(role, in: ctx, rect: r, color: cgc)
            return true
        }
    }

    // MARK: - Đọc chuỗi lệnh path

    private static func parse(_ s: String) -> CGPath {
        let toks = s.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Double($0) }
        let path = CGMutablePath()
        var i = 0
        func pt() -> CGPoint { defer { i += 2 }; return CGPoint(x: toks[i], y: toks[i + 1]) }
        while i < toks.count {
            let op = Int(toks[i]); i += 1
            switch op {
            case 0:
                guard i + 1 < toks.count else { return path }
                path.move(to: pt())
            case 1:
                guard i + 1 < toks.count else { return path }
                path.addLine(to: pt())
            case 2:
                guard i + 5 < toks.count else { return path }
                let c1 = pt(), c2 = pt(), e = pt()
                path.addCurve(to: e, control1: c1, control2: c2)
            default:
                path.closeSubpath()
            }
        }
        return path
    }
}
