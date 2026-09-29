import CoreGraphics
import Foundation

// MARK: - C8 · Tone curves

/// 1 đường cong tông. Điểm (x,y) ∈ [0,1], x tăng dần. Mặc định = identity.
struct ToneCurve: Equatable, Codable {
    var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]

    var isIdentity: Bool {
        points.count == 2
            && abs(points[0].x) < 1e-4 && abs(points[0].y) < 1e-4
            && abs(points[1].x - 1) < 1e-4 && abs(points[1].y - 1) < 1e-4
    }

    /// Lấy mẫu tại `x` bằng nội suy MONOTONE CUBIC (Fritsch–Carlson) — không overshoot.
    func sample(_ x: Double) -> Double {
        let pts = points.sorted { $0.x < $1.x }
        guard pts.count >= 2 else { return x }
        let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
        let n = xs.count
        if x <= xs[0] { return clamp01(ys[0]) }
        if x >= xs[n - 1] { return clamp01(ys[n - 1]) }

        // độ dốc từng đoạn
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let h = xs[i + 1] - xs[i]
            d[i] = h > 1e-9 ? (ys[i + 1] - ys[i]) / h : 0
        }
        // tiếp tuyến tại từng điểm
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 { m[i] = 0 }
            else { m[i] = (d[i - 1] + d[i]) / 2 }
        }
        for i in 0..<(n - 1) where abs(d[i]) < 1e-12 { m[i] = 0; m[i + 1] = 0 }
        for i in 0..<(n - 1) where abs(d[i]) >= 1e-12 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 { let t = 3 / sqrt(s); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        // đoạn chứa x
        var i = 0
        while i < n - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        let t = (x - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        let y = h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]
        return clamp01(y)
    }

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}

struct ToneCurves: Equatable, Codable {
    var master = ToneCurve()
    var red = ToneCurve()
    var green = ToneCurve()
    var blue = ToneCurve()

    var isIdentity: Bool {
        master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }
    var key: String {
        [master, red, green, blue]
            .map { c in c.points.map { "\(Int($0.x*999)),\(Int($0.y*999))" }.joined(separator: ";") }
            .joined(separator: "|")
    }
}

// MARK: - C9 · HSL / selective

/// 8 dải màu; mỗi dải: hue shift / saturation / luminance, thang −1…1 (0 = không đổi).
struct HSLAdjust: Equatable, Codable {
    var hue = [Double](repeating: 0, count: 8)
    var sat = [Double](repeating: 0, count: 8)
    var lum = [Double](repeating: 0, count: 8)

    var isIdentity: Bool { (hue + sat + lum).allSatisfy { $0 == 0 } }
    var key: String { (hue + sat + lum).map { String(format: "%.3f", $0) }.joined(separator: ",") }

    static let bandNames = ["Đỏ", "Cam", "Vàng", "Lục", "Lam nhạt", "Lam", "Tím", "Hồng"]
    /// Tâm hue (độ) của 8 dải.
    static let bandCenters: [Double] = [0, 30, 60, 120, 190, 240, 285, 320]
}

// MARK: - C10 · LUT

struct LUTRef: Equatable, Codable {
    var path: String = ""
    var name: String = ""
    var intensity: Double = 1        // 0 = không áp, 1 = full
    var isActive: Bool { !path.isEmpty && intensity > 0.001 }
}
