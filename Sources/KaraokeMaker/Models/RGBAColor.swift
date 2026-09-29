import SwiftUI
import AppKit

/// Màu lưu được ra file (JSON). Dùng cho style chữ karaoke.
/// Các giá trị r/g/b/a trong khoảng 0.0 ... 1.0.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0, a: 1)
    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)

    /// Trộn tuyến tính 2 màu (t = 0 → a, t = 1 → b).
    static func lerp(_ a: RGBAColor, _ b: RGBAColor, _ t: Double) -> RGBAColor {
        let u = max(0, min(1, t))
        return RGBAColor(r: a.r + (b.r - a.r) * u, g: a.g + (b.g - a.g) * u,
                         b: a.b + (b.b - a.b) * u, a: a.a + (b.a - a.a) * u)
    }

    /// Từ SwiftUI.Color (dùng cho ColorPicker).
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        self.init(
            r: Double(ns.redComponent),
            g: Double(ns.greenComponent),
            b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent)
        )
    }

    /// Chuyển sang SwiftUI.Color để hiển thị.
    var color: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Chuyển sang NSColor để vẽ bằng Core Graphics / Core Text.
    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
