import SwiftUI

/// Thanh trượt CHUNG toàn app (DESIGN_SYSTEM §13) — thay 5 biến thể cũ (`colorSlider` / `GradientTrackSlider` /
/// `overlaySlider` / `fadeRow` / `bgSlider` + `DragSlider` của StylePanel; các hàm cũ giờ chỉ gọi vào đây).
/// - Rãnh 3pt `strokeStrong`, phần đã kéo `accent`; khoảng có số 0 ở giữa (vd. −1…1) → tô TỪ 0 ra hai phía.
/// - `track` = rãnh gradient cố định (Nhiệt độ / Sắc / Bão hoà) → không tô accent.
/// - Bấm / kéo bất kỳ đâu trên rãnh; nắm trúng núm thì núm KHÔNG nhảy về chỗ con trỏ.
/// - Bấm đúp (rãnh hoặc số) = về `defaultValue`.
/// - Kéo: núm chạy theo state cục bộ, chỉ ghi ra ngoài ≤ 20 lần/giây + 1 lần lúc thả → ContentView không dựng lại mỗi
///   khung hình (Intel). Thả tay không nhảy: giá trị cuối được ghi đúng giá trị núm đang đứng.
struct KMSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var track: [Color]? = nil
    var accessibilityLabel: String = ""
    var accessibilityText: String = ""
    let onChange: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var live: Double?
    @State private var grabOffset: CGFloat = 0
    @State private var lastPush = Date.distantPast

    private static let knob: CGFloat = 12
    private static let inset: CGFloat = 6          // nửa núm — núm không tràn ra ngoài mép

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - Self.inset * 2)
            let shown = live ?? value
            let x = Self.inset + fraction(shown) * w
            let midY = geo.size.height / 2
            ZStack(alignment: .topLeading) {
                if let track {
                    Capsule().fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                        .frame(width: w, height: 3).position(x: Self.inset + w / 2, y: midY)
                } else {
                    Capsule().fill(Theme.strokeStrong)
                        .frame(width: w, height: 3).position(x: Self.inset + w / 2, y: midY)
                    let ox = Self.inset + fraction(origin) * w
                    Capsule().fill(Theme.accent)
                        .frame(width: max(0, abs(x - ox)), height: 3).position(x: (x + ox) / 2, y: midY)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .position(x: x, y: midY)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if live == nil {
                        // Nắm trúng núm → giữ khoảng lệch; bấm chỗ khác trên rãnh → nhảy tới đó.
                        let kx = Self.inset + fraction(value) * w
                        grabOffset = abs(g.startLocation.x - kx) <= Self.knob * 0.75 ? kx - g.startLocation.x : 0
                    }
                    let v = valueAt(g.location.x + grabOffset, width: w)
                    live = v
                    let now = Date()
                    if now.timeIntervalSince(lastPush) > 0.05 { lastPush = now; onChange(v) }
                }
                .onEnded { _ in
                    if let v = live { onChange(v) }
                    live = nil
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { resetToDefault() })
        }
        .frame(height: 18)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityText)
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 50
            switch dir {
            case .increment: onChange(min(range.upperBound, value + step))
            case .decrement: onChange(max(range.lowerBound, value - step))
            @unknown default: break
            }
        }
    }

    /// Mốc bắt đầu tô: 0 nếu khoảng trượt vắt qua 0 (−…+), ngược lại là đầu trái.
    private var origin: Double {
        range.lowerBound < 0 && range.upperBound > 0 ? 0 : range.lowerBound
    }

    private func fraction(_ v: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(max(0, min(1, (v - range.lowerBound) / span)))
    }

    private func valueAt(_ px: CGFloat, width w: CGFloat) -> Double {
        let f = Double(max(0, min(1, (px - Self.inset) / w)))
        return range.lowerBound + f * (range.upperBound - range.lowerBound)
    }

    private func resetToDefault() {
        guard let d = defaultValue else { return }
        live = nil
        onChange(min(range.upperBound, max(range.lowerBound, d)))
    }
}

/// Hàng trượt chuẩn: nhãn · thanh · số. `stacked` = nhãn + số ở trên, thanh ở dưới (inspector có nhãn dài).
struct KMSliderRow: View {
    let label: String                 // ĐÃ dịch (gọi `L(…)` ở nơi dùng)
    let value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double? = nil
    var track: [Color]? = nil
    var labelWidth: CGFloat = 84
    var valueWidth: CGFloat = 40
    var stacked = false
    let format: (Double) -> String
    let onChange: (Double) -> Void

    var body: some View {
        let text = format(value)
        let edited = defaultValue.map { abs(value - $0) > 1e-9 } ?? true
        let number = Text(text)
            .font(Theme.Typo.mono)
            .foregroundStyle(edited ? Theme.inkDim : Theme.inkFaint)
            .onTapGesture(count: 2) { if let d = defaultValue { onChange(d) } }
            .help(defaultValue == nil ? "" : L("Bấm đúp để về mặc định"))
        let bar = KMSlider(value: value, range: range, defaultValue: defaultValue, track: track,
                           accessibilityLabel: label, accessibilityText: text, onChange: onChange)
        if stacked {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(Theme.Typo.label).foregroundStyle(Theme.ink)
                    Spacer()
                    number
                }
                bar
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                Text(label).font(Theme.Typo.label).foregroundStyle(Theme.inkDim)
                    .frame(width: labelWidth, alignment: .leading)
                    .lineLimit(1).minimumScaleFactor(0.8)
                bar
                number.frame(width: valueWidth, alignment: .trailing)
            }
        }
    }
}

extension KMSliderRow {
    /// Dùng thẳng với `Binding`.
    init(_ label: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, defaultValue: Double? = nil,
         track: [Color]? = nil, labelWidth: CGFloat = 84, valueWidth: CGFloat = 40,
         format: @escaping (Double) -> String) {
        self.init(label: label, value: binding.wrappedValue, range: range, defaultValue: defaultValue, track: track,
                  labelWidth: labelWidth, valueWidth: valueWidth, format: format,
                  onChange: { binding.wrappedValue = $0 })
    }
}
