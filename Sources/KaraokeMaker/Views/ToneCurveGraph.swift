import SwiftUI

/// C8 — Đồ thị đường cong tông: kéo điểm, double-click thêm/bớt điểm.
struct ToneCurveGraph: View {
    @Binding var curve: ToneCurve

    private let space = "toneCurve"

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1), h = max(geo.size.height, 1)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28))

                Path { p in
                    for i in 1..<4 {
                        let x = w * CGFloat(i) / 4
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                        let y = h * CGFloat(i) / 4
                        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                    }
                }.stroke(Color.white.opacity(0.07), lineWidth: 1)

                Path { p in
                    p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: 0))
                }.stroke(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    let n = 56
                    for i in 0...n {
                        let x = Double(i) / Double(n)
                        let pt = CGPoint(x: CGFloat(x) * w, y: (1 - CGFloat(curve.sample(x))) * h)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }.stroke(Theme.accent, lineWidth: 2)

                ForEach(Array(sortedPts.enumerated()), id: \.offset) { idx, pt in
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 1.5))
                        .position(x: CGFloat(pt.x) * w, y: (1 - CGFloat(pt.y)) * h)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                                .onChanged { g in movePoint(idx, to: g.location, w: w, h: h) }
                        )
                }
            }
            .coordinateSpace(name: space)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2, coordinateSpace: .named(space))
                    .onEnded { e in togglePoint(at: e.location, w: w, h: h) }
            )
        }
    }

    private var sortedPts: [CGPoint] { curve.points.sorted { $0.x < $1.x } }

    private func movePoint(_ i: Int, to loc: CGPoint, w: CGFloat, h: CGFloat) {
        var pts = sortedPts
        guard pts.indices.contains(i) else { return }
        var x = clamp01(Double(loc.x / w))
        let y = clamp01(Double(1 - loc.y / h))
        if i == 0 { x = 0 }
        else if i == pts.count - 1 { x = 1 }
        else {
            x = min(max(x, Double(pts[i - 1].x) + 0.02), Double(pts[i + 1].x) - 0.02)
        }
        pts[i] = CGPoint(x: x, y: y)
        curve.points = pts
    }

    private func togglePoint(at loc: CGPoint, w: CGFloat, h: CGFloat) {
        let x = min(max(Double(loc.x / w), 0.03), 0.97)
        let y = clamp01(Double(1 - loc.y / h))
        var pts = sortedPts
        if let hit = pts.firstIndex(where: { abs(Double($0.x) - x) < 0.045 }),
           hit != 0, hit != pts.count - 1 {
            pts.remove(at: hit)
        } else {
            pts.append(CGPoint(x: x, y: y))
        }
        curve.points = pts.sorted { $0.x < $1.x }
    }

    private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}

/// C11 — Scopes cho 1 clip (ảnh đã chỉnh màu): Histogram / RGB Parade / Vectorscope.
struct ColorScopes: View {
    let provider: () -> CGImage?
    let key: String

    @State private var mode = 0            // 0 hist · 1 parade · 2 vector
    @State private var bars: [SIMD3<Float>] = []
    @State private var samples: (px: [SIMD3<Float>], w: Int, h: Int)?

    var body: some View {
        VStack(spacing: 4) {
            Picker("", selection: $mode) {
                Text(L("Biểu đồ")).tag(0); Text("Parade").tag(1); Text(L("Véc-tơ")).tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini)

            Group {
                switch mode {
                case 1: paradeView
                case 2: vectorView
                default: histView
                }
            }
            .frame(height: 60)
            .background(RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.32)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.08)))
        }
        .task(id: "\(key)|\(mode)") {
            guard let cg = provider() else { bars = []; samples = nil; return }
            if mode == 0 { bars = ColorPipeline.histogram(cg) ?? [] }
            else { samples = ColorPipeline.scopeSamples(cg) }
        }
    }

    private var histView: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let n = max(bars.count, 1)
            ZStack {
                ForEach(0..<3, id: \.self) { ch in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: h))
                        for i in 0..<bars.count {
                            let x = w * CGFloat(i) / CGFloat(max(n - 1, 1))
                            let v = CGFloat(ch == 0 ? bars[i].x : (ch == 1 ? bars[i].y : bars[i].z))
                            p.addLine(to: CGPoint(x: x, y: h - v * h))
                        }
                        p.addLine(to: CGPoint(x: w, y: h))
                    }
                    .fill([Color.red, Color.green, Color.blue][ch].opacity(0.42))
                }
            }
        }
    }

    private var paradeView: some View {
        Canvas { ctx, size in
            guard let s = samples, !s.px.isEmpty else { return }
            let panelW = size.width / 3
            let step = max(1, (s.w * s.h) / 9000)
            for ch in 0..<3 {
                let col: Color = [.red, .green, .blue][ch]
                let x0 = panelW * CGFloat(ch)
                var i = 0
                while i < s.px.count {
                    let col_ = i % s.w
                    let v = CGFloat(ch == 0 ? s.px[i].x : (ch == 1 ? s.px[i].y : s.px[i].z))
                    let x = x0 + panelW * CGFloat(col_) / CGFloat(max(s.w - 1, 1))
                    let y = size.height * (1 - v)
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.1, height: 1.1)),
                             with: .color(col.opacity(0.5)))
                    i += step
                }
            }
        }
    }

    private var vectorView: some View {
        Canvas { ctx, size in
            guard let s = samples, !s.px.isEmpty else { return }
            let cx = size.width / 2, cy = size.height / 2
            let r = min(cx, cy) - 2
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2*r, height: 2*r)),
                       with: .color(.white.opacity(0.12)))
            let step = max(1, (s.w * s.h) / 9000)
            var i = 0
            while i < s.px.count {
                let p = s.px[i]
                let cb = -0.169 * p.x - 0.331 * p.y + 0.5 * p.z
                let cr =  0.5 * p.x - 0.419 * p.y - 0.081 * p.z
                let x = cx + CGFloat(cb) * 2 * r
                let y = cy - CGFloat(cr) * 2 * r
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                         with: .color(.green.opacity(0.5)))
                i += step
            }
        }
    }
}
