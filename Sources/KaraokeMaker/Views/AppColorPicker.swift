import SwiftUI
import AppKit

// MARK: - Chuyển đổi màu (HSV / HSL / HEX) — dùng chung cho trình chọn màu

extension RGBAColor {
    /// Byte 0…255 (đã kẹp).
    private static func b(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }

    var hexRGB: String { String(format: "%02X%02X%02X", Self.b(r), Self.b(g), Self.b(b)) }
    var hexRGBA: String { String(format: "%02X%02X%02X%02X", Self.b(r), Self.b(g), Self.b(b), Self.b(a)) }

    /// Nhận "#RGB", "#RRGGBB", "#RRGGBBAA" (dấu # tuỳ chọn).
    init?(hex raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        func pair(_ i: Int) -> Double {
            let a = s.index(s.startIndex, offsetBy: i)
            let b = s.index(a, offsetBy: 2)
            return Double(Int(s[a..<b], radix: 16) ?? 0) / 255.0
        }
        switch s.count {
        case 3:
            let cs = s.map { String(repeating: $0, count: 2) }
            self.init(r: Double(Int(cs[0], radix: 16) ?? 0) / 255,
                      g: Double(Int(cs[1], radix: 16) ?? 0) / 255,
                      b: Double(Int(cs[2], radix: 16) ?? 0) / 255, a: 1)
        case 6:  self.init(r: pair(0), g: pair(2), b: pair(4), a: 1)
        case 8:  self.init(r: pair(0), g: pair(2), b: pair(4), a: pair(6))
        default: return nil
        }
    }

    /// HSV (mỗi thành phần 0…1). Alpha giữ nguyên ở `a`.
    var hsv: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 0.00001 {
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    init(h: Double, s: Double, v: Double, a: Double = 1) {
        let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let i = Int(hh)
        let f = hh - Double(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: self.init(r: v, g: t, b: p, a: a)
        case 1: self.init(r: q, g: v, b: p, a: a)
        case 2: self.init(r: p, g: v, b: t, a: a)
        case 3: self.init(r: p, g: q, b: v, a: a)
        case 4: self.init(r: t, g: p, b: v, a: a)
        default: self.init(r: v, g: p, b: q, a: a)
        }
    }

    /// HSL: H 0…360, S/L 0…100.
    var hsl360: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        let l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if d > 0.00001 {
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        return (h * 360, s * 100, l * 100)
    }

    init(hslH h: Double, s: Double, l: Double, a: Double = 1) {
        let H = ((h / 360).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        let S = max(0, min(1, s / 100)), L = max(0, min(1, l / 100))
        if S == 0 { self.init(r: L, g: L, b: L, a: a); return }
        let q = L < 0.5 ? L * (1 + S) : L + S - L * S
        let p = 2 * L - q
        func hue(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        self.init(r: hue(H + 1.0 / 3), g: hue(H), b: hue(H - 1.0 / 3), a: a)
    }
}

// MARK: - "Màu của tôi" — lưu bằng UserDefaults, dùng chung toàn app

@MainActor
final class MyColorsStore: ObservableObject {
    static let shared = MyColorsStore()
    @Published private(set) var colors: [RGBAColor] = []
    private let key = "app.mycolors.v1"

    private init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            colors = arr.compactMap { RGBAColor(hex: $0) }
        }
    }
    func add(_ c: RGBAColor) {
        colors.removeAll { $0.hexRGBA == c.hexRGBA }
        colors.insert(c, at: 0)
        if colors.count > 42 { colors = Array(colors.prefix(42)) }
        persist()
    }
    func remove(_ c: RGBAColor) {
        colors.removeAll { $0.hexRGBA == c.hexRGBA }
        persist()
    }
    private func persist() {
        UserDefaults.standard.set(colors.map { $0.hexRGBA }, forKey: key)
    }
}

// MARK: - Bộ nhớ tạm màu (copy/paste giữa các ô)

@MainActor
final class ColorClipboard: ObservableObject {
    static let shared = ColorClipboard()
    @Published var fill: ColorFill?
    private init() {}
}

// MARK: - "Kiểu tô của tôi" — lưu các bộ GRADIENT dùng lại (UserDefaults JSON)

@MainActor
final class MyFillsStore: ObservableObject {
    static let shared = MyFillsStore()
    @Published private(set) var fills: [ColorFill] = []
    private let key = "app.myfills.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([ColorFill].self, from: data) {
            fills = arr
        }
    }
    func add(_ f: ColorFill) {
        fills.removeAll { $0 == f }
        fills.insert(f, at: 0)
        if fills.count > 24 { fills = Array(fills.prefix(24)) }
        persist()
    }
    func remove(_ f: ColorFill) {
        fills.removeAll { $0 == f }
        persist()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(fills) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Ô màu (bấm mở bảng chọn) — DÙNG CHUNG cho MỌI chỗ chọn màu trong app

/// Nút ô màu nhỏ; bấm mở `AppColorPopover`. Bấm ra ngoài popover là tự đóng (không có nút ✕).
/// Chuột phải: Sao chép / Dán / Về mặc định.
struct AppColorField: View {
    var color: RGBAColor
    var supportsOpacity: Bool = true
    /// Nhãn phụ hiển thị bên trái (tuỳ chọn).
    var label: String? = nil
    var swatchWidth: CGFloat = 46
    /// Giá trị "Về mặc định" (ẩn mục menu nếu nil).
    var defaultValue: RGBAColor? = nil
    let onChange: (RGBAColor) -> Void

    @State private var open = false
    @ObservedObject private var clip = ColorClipboard.shared

    var body: some View {
        HStack(spacing: 8) {
            if let label { Text(L(label)).font(.callout); Spacer(minLength: 4) }
            Button { open = true } label: {
                ZStack {
                    AppCheckerboard().clipShape(RoundedRectangle(cornerRadius: 5))
                    RoundedRectangle(cornerRadius: 5).fill(color.color)
                }
                .frame(width: swatchWidth, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AppColorPopover(initial: color, supportsOpacity: supportsOpacity, onChange: onChange)
            }
            .contextMenu {
                Button(L("Sao chép màu")) { clip.fill = .solid(color) }
                Button(L("Dán màu")) { if let f = clip.fill { onChange(f.flatColor) } }
                    .disabled(clip.fill == nil)
                if let d = defaultValue {
                    Divider()
                    Button(L("Về mặc định")) { onChange(d) }
                }
            }
        }
    }
}

// MARK: - Ô TÔ (đơn sắc HOẶC gradient) — dùng cho chữ karaoke + lớp chữ

/// Như `AppColorField` nhưng chọn được `ColorFill` (đơn sắc / gradient tuyến tính / toả tròn, nhiều chặng).
struct AppFillField: View {
    var fill: ColorFill
    var label: String? = nil
    var swatchWidth: CGFloat = 46
    var defaultValue: ColorFill? = nil
    let onChange: (ColorFill) -> Void

    @State private var open = false
    @ObservedObject private var clip = ColorClipboard.shared

    private var previewStops: [Gradient.Stop] {
        fill.effectiveStops.map { .init(color: $0.color.color, location: $0.loc) }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let label { Text(L(label)).font(.callout); Spacer(minLength: 4) }
            Button { open = true } label: {
                ZStack {
                    AppCheckerboard().clipShape(RoundedRectangle(cornerRadius: 5))
                    if fill.isFlat {
                        RoundedRectangle(cornerRadius: 5).fill(fill.flatColor.color)
                    } else if fill.style == .radial {
                        RoundedRectangle(cornerRadius: 5).fill(
                            RadialGradient(gradient: Gradient(stops: previewStops),
                                           center: .center, startRadius: 0, endRadius: swatchWidth * 0.6))
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(
                            LinearGradient(gradient: Gradient(stops: previewStops),
                                           startPoint: .leading, endPoint: .trailing))
                    }
                }
                .frame(width: swatchWidth, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AppFillPopover(initial: fill, onChange: onChange)
            }
            .contextMenu {
                Button(L("Sao chép màu")) { clip.fill = fill }
                Button(L("Dán màu")) { if let f = clip.fill { onChange(f) } }
                    .disabled(clip.fill == nil)
                if let d = defaultValue {
                    Divider()
                    Button(L("Về mặc định")) { onChange(d) }
                }
            }
        }
    }
}

/// Vá lỗi "bấm vào popover bị đứng, phải bấm ra rồi bấm lại mới ăn": trên macOS, `NSPopover`
/// đôi khi hiện lên nhưng cửa sổ của nó CHƯA (hoặc KHÔNG CÒN) là key ngay — cú bấm bị AppKit
/// nuốt mất chỉ để kích hoạt cửa sổ (giống lỗi thiếu `acceptsFirstMouse`), không tới được
/// nút/kéo bên trong. `NSHostingView` do SwiftUI dựng nên không override `acceptsFirstMouse`
/// trực tiếp được — ép `.makeKey()`, y hệt cách `KaraokePreviewCanvas`/`TimelineCanvasView` đã
/// làm bằng `acceptsFirstMouse` cho canvas AppKit.
///
/// CHỈ ép lúc `makeNSView` (mở popover lần đầu) là CHƯA đủ: mỗi lần chọn 1 màu, `onChange` chạy
/// tới `store.edit(...)` ở NGOÀI popover (đổi tiêu đề cửa sổ "đã sửa", cập nhật menu Undo…) —
/// việc đó có thể khiến cửa sổ CHÍNH giành lại key window, làm popover mất key. Bấm màu KẾ TIẾP
/// vì vậy lại bị nuốt y như lần đầu. `updateNSView` chạy lại mỗi khi nội dung popover vẽ lại
/// (tức là sau MỖI lần chọn màu) nên ép `.makeKey()` lại ở đây luôn, không chỉ lúc mở popover.
private struct PopoverFirstClickFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        reassertKey(v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        reassertKey(nsView)
    }
    private func reassertKey(_ v: NSView) {
        DispatchQueue.main.async {
            guard let w = v.window, !w.isKeyWindow else { return }
            w.makeKey()
        }
    }
}

struct AppFillPopover: View {
    let initial: ColorFill
    let onChange: (ColorFill) -> Void

    @State private var f: ColorFill
    @State private var selIdx = 0
    @State private var seeded = false
    @ObservedObject private var myFills = MyFillsStore.shared

    init(initial: ColorFill, onChange: @escaping (ColorFill) -> Void) {
        self.initial = initial
        self.onChange = onChange
        _f = State(initialValue: initial)
    }

    private var isGradient: Bool { f.style != .solid }
    private var activeColor: RGBAColor {
        if !isGradient { return f.color }
        return f.stops.indices.contains(selIdx) ? f.stops[selIdx].color : f.color
    }
    private var editorID: String { "\(f.style.rawValue)-\(selIdx)-\(f.stops.count)" }

    private var previewStops: [Gradient.Stop] {
        f.effectiveStops.map { .init(color: $0.color.color, location: $0.loc) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: Binding(get: { f.style }, set: { setStyle($0) })) {
                Text(L("Đơn sắc")).tag(ColorFill.Style.solid)
                Text(L("Tuyến tính")).tag(ColorFill.Style.linear)
                Text(L("Toả tròn")).tag(ColorFill.Style.radial)
            }
            .pickerStyle(.segmented).labelsHidden()

            if isGradient {
                // Thanh gradient — bấm để THÊM chặng, kéo tay nắm để đổi vị trí (2 đầu cố định).
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        (f.style == .radial
                            ? AnyView(RoundedRectangle(cornerRadius: 5).fill(
                                RadialGradient(gradient: Gradient(stops: previewStops),
                                               center: .center, startRadius: 0, endRadius: 120)))
                            : AnyView(RoundedRectangle(cornerRadius: 5).fill(
                                LinearGradient(gradient: Gradient(stops: previewStops),
                                               startPoint: .leading, endPoint: .trailing))))
                            .frame(height: 16).padding(.top, 3)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2))
                                .frame(height: 16).padding(.top, 3))
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                                if abs(g.translation.width) < 5, abs(g.translation.height) < 5 {
                                    addStopAt(Double(g.location.x / max(1, geo.size.width)))
                                }
                            })

                        ForEach(f.stops.indices, id: \.self) { i in
                            Circle()
                                .fill(f.stops[i].color.color)
                                .frame(width: 13, height: 13)
                                .overlay(Circle().strokeBorder(
                                    i == selIdx ? Theme.accent : Color.white, lineWidth: i == selIdx ? 2.5 : 1.5))
                                .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5))
                                .position(x: min(max(7, CGFloat(f.stops[i].loc) * geo.size.width),
                                                 geo.size.width - 7), y: 11)
                                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                                    selIdx = i
                                    guard i > 0, i < f.stops.count - 1 else { return }
                                    let lo = f.stops[i - 1].loc + 0.02
                                    let hi = f.stops[i + 1].loc - 0.02
                                    f.stops[i].loc = max(lo, min(hi, Double(g.location.x / max(1, geo.size.width))))
                                    push()
                                })
                        }
                    }
                }
                .frame(height: 22)

                // Hàng chặng màu
                HStack(spacing: 6) {
                    ForEach(f.stops.indices, id: \.self) { i in
                        Button { selIdx = i } label: {
                            RoundedRectangle(cornerRadius: 4).fill(f.stops[i].color.color)
                                .frame(width: 26, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(i == selIdx ? Theme.accent : Color.primary.opacity(0.25),
                                            lineWidth: i == selIdx ? 2 : 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { addStop() } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain).help(L("Thêm chặng màu"))
                    Button { removeStop() } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).help(L("Bỏ chặng đang chọn"))
                        .disabled(f.stops.count <= 2 || selIdx == 0 || selIdx == f.stops.count - 1)
                    Spacer(minLength: 0)
                    Button { f.stops = f.stops.enumerated().map { ColorStop(color: f.stops[f.stops.count-1-$0.offset].color, loc: $0.element.loc) }; push() } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .buttonStyle(.plain).help(L("Đảo thứ tự màu"))
                }

                // Vị trí chặng giữa (2 đầu cố định 0% / 100%)
                if selIdx > 0, selIdx < f.stops.count - 1 {
                    HStack(spacing: 6) {
                        Text(L("Vị trí")).font(.caption2).foregroundStyle(.secondary)
                        Slider(value: Binding(
                            get: { f.stops[selIdx].loc },
                            set: { v in
                                let lo = f.stops[selIdx - 1].loc + 0.02
                                let hi = f.stops[selIdx + 1].loc - 0.02
                                f.stops[selIdx].loc = max(lo, min(hi, v)); push()
                            }), in: 0...1)
                        Text("\(Int(f.stops[selIdx].loc * 100))%").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    }
                }

                if f.style == .linear {
                    HStack(spacing: 6) {
                        Text(L("Góc")).font(.caption2).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { f.angle }, set: { f.angle = $0.rounded(); push() }), in: 0...360)
                        ForEach([("→", 0.0), ("↓", 90.0), ("↘", 45.0)], id: \.1) { sym, deg in
                            Button(sym) { f.angle = deg; push() }
                                .buttonStyle(.plain)
                                .foregroundStyle(abs(f.angle - deg) < 0.5 ? Theme.accent : Color.secondary)
                        }
                        Text("\(Int(f.angle))°").font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                    }
                }

                // Kiểu tô đã lưu
                HStack(spacing: 6) {
                    Text(L("Kiểu tô của tôi")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Button { myFills.add(f) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.plain).help(L("Lưu bộ gradient hiện tại"))
                    Spacer(minLength: 0)
                }
                if !myFills.fills.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(myFills.fills.enumerated()), id: \.offset) { _, sf in
                                Button {
                                    applySavedFill(sf)
                                } label: {
                                    RoundedRectangle(cornerRadius: 4).fill(
                                        LinearGradient(gradient: Gradient(stops:
                                            sf.effectiveStops.map { .init(color: $0.color.color, location: $0.loc) }),
                                            startPoint: .leading, endPoint: .trailing))
                                        .frame(width: 34, height: 18)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.2)))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu { Button(L("Xoá"), role: .destructive) { myFills.remove(sf) } }
                            }
                        }
                    }
                }
            }

            AppColorPopover(initial: activeColor, supportsOpacity: true) { c in
                if isGradient, f.stops.indices.contains(selIdx) { f.stops[selIdx].color = c }
                else { f.color = c }
                push()
            }
            .id(editorID)
        }
        .padding(12)
        .frame(width: 268)
        .background(PopoverFirstClickFix())
        .onAppear { if !seeded { seeded = true; f = initial; normalize() } }
    }

    private func normalize() {
        if isGradient, f.stops.count < 2 {
            f.stops = [ColorStop(color: f.color, loc: 0), ColorStop(color: f.color2, loc: 1)]
        }
        if !f.stops.isEmpty {
            f.stops.sort { $0.loc < $1.loc }
            f.stops[0].loc = 0
            f.stops[f.stops.count - 1].loc = 1
        }
        selIdx = min(selIdx, max(0, f.stops.count - 1))
    }

    private func setStyle(_ s: ColorFill.Style) {
        f.style = s
        if s != .solid {
            if f.stops.count < 2 {
                let end = f.color == f.color2 ? RGBAColor(r: 0.30, g: 0.45, b: 0.95, a: f.color.a) : f.color2
                f.stops = [ColorStop(color: f.color, loc: 0), ColorStop(color: end, loc: 1)]
            }
            selIdx = 0
        }
        normalize()
        push()
    }

    private func addStop() {
        guard f.stops.count >= 2 else { return }
        var bestGap = -1.0, at = 0
        for i in 0..<(f.stops.count - 1) {
            let g = f.stops[i + 1].loc - f.stops[i].loc
            if g > bestGap { bestGap = g; at = i }
        }
        let l = (f.stops[at].loc + f.stops[at + 1].loc) / 2
        let c = RGBAColor.lerp(f.stops[at].color, f.stops[at + 1].color, 0.5)
        f.stops.insert(ColorStop(color: c, loc: l), at: at + 1)
        selIdx = at + 1
        push()
    }

    private func removeStop() {
        guard f.stops.count > 2, selIdx > 0, selIdx < f.stops.count - 1 else { return }
        f.stops.remove(at: selIdx)
        selIdx = min(selIdx, f.stops.count - 1)
        push()
    }

    /// Thêm 1 chặng ngay tại vị trí `loc` (0…1) bấm trên thanh.
    private func addStopAt(_ loc: Double) {
        guard f.stops.count >= 2 else { return }
        let l = max(0.03, min(0.97, loc))
        var at = f.stops.count - 2
        for i in 0..<(f.stops.count - 1) where l < f.stops[i + 1].loc { at = i; break }
        let span = max(0.001, f.stops[at + 1].loc - f.stops[at].loc)
        let c = RGBAColor.lerp(f.stops[at].color, f.stops[at + 1].color, (l - f.stops[at].loc) / span)
        f.stops.insert(ColorStop(color: c, loc: l), at: at + 1)
        selIdx = at + 1
        push()
    }

    private func push() {
        if isGradient, f.stops.count >= 2 {
            f.color = f.stops.first!.color
            f.color2 = f.stops.last!.color
        }
        onChange(f)
    }

    /// Áp 1 "Kiểu tô của tôi" đã lưu — dựng lại stops cho chắc rồi đẩy ra ngoài.
    private func applySavedFill(_ sf: ColorFill) {
        var nf = sf
        if nf.style == .solid { nf.style = .linear }
        if nf.stops.count < 2 {
            nf.stops = [ColorStop(color: nf.color, loc: 0), ColorStop(color: nf.color2, loc: 1)]
        }
        nf.stops.sort { $0.loc < $1.loc }
        nf.stops[0].loc = 0
        nf.stops[nf.stops.count - 1].loc = 1
        f = nf
        selIdx = 0
        push()
    }
}

/// Ô caro nền (cho alpha).
struct AppCheckerboard: View {
    var cell: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            let cols = Int(ceil(geo.size.width / cell))
            let rows = Int(ceil(geo.size.height / cell))
            Path { p in
                for row in 0..<max(1, rows) {
                    for col in 0..<max(1, cols) where (row + col) % 2 == 0 {
                        p.addRect(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell,
                                         width: cell, height: cell))
                    }
                }
            }
            .fill(Color.gray.opacity(0.45))
            .background(Color.white.opacity(0.85))
        }
    }
}

// MARK: - Bảng chọn màu (giống CapCut: ô SV + thanh sắc + ống hút + HEX/RGB/HSL + Màu của tôi)

struct AppColorPopover: View {
    let initial: RGBAColor
    var supportsOpacity: Bool
    let onChange: (RGBAColor) -> Void

    init(initial: RGBAColor, supportsOpacity: Bool, onChange: @escaping (RGBAColor) -> Void) {
        self.initial = initial
        self.supportsOpacity = supportsOpacity
        self.onChange = onChange
    }

    enum Fmt: String, CaseIterable, Identifiable { case hex = "HEX", rgb = "RGB", hsl = "HSL"; var id: String { rawValue } }

    @State private var h = 0.0            // 0…1
    @State private var s = 0.0            // 0…1
    @State private var v = 0.0            // 0…1
    @State private var a = 1.0            // 0…1
    @State private var fmt: Fmt = .hex
    @State private var f1 = ""
    @State private var f2 = ""
    @State private var f3 = ""
    @State private var seeded = false

    @ObservedObject private var mine = MyColorsStore.shared

    private var rgba: RGBAColor { RGBAColor(h: h, s: s, v: v, a: a) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            svSquare.frame(height: 148)
            HStack(spacing: 8) {
                Button { pickFromScreen() } label: { Image(systemName: "eyedropper") }
                    .buttonStyle(.plain).help(L("Hút màu trên màn hình"))
                hueBar.frame(height: 14)
            }
            if supportsOpacity { alphaBar.frame(height: 14) }

            formatRow

            Divider()

            HStack {
                Text(L("Màu của tôi")).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            swatchGrid
        }
        .padding(12)
        .frame(width: 244)
        .background(PopoverFirstClickFix())
        .onAppear {
            guard !seeded else { return }
            seeded = true
            let x = initial.hsv
            h = x.h; s = x.s; v = x.v; a = initial.a
            syncFields()
        }
    }

    // MARK: ô Saturation × Value

    private var svSquare: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(Color(hue: h, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle()
                    .strokeBorder(Color.white, lineWidth: 2)
                    .background(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 3.5))
                    .frame(width: 15, height: 15)
                    .position(x: CGFloat(s) * geo.size.width,
                              y: CGFloat(1 - v) * geo.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                s = clamp01(Double(g.location.x / max(1, geo.size.width)))
                v = clamp01(1 - Double(g.location.y / max(1, geo.size.height)))
                nudgeAlphaIfInvisible()
                pushLive()
            })
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }

    /// Đang chọn màu mà độ mờ = 0 (ô đang "tắt") → tự bật độ mờ lên 1 cho thấy màu.
    private func nudgeAlphaIfInvisible() { if a < 0.004 { a = 1 } }

    private var hueBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(gradient: Gradient(colors: (0...12).map {
                    Color(hue: Double($0) / 12, saturation: 1, brightness: 1)
                }), startPoint: .leading, endPoint: .trailing)
                Capsule().fill(.white)
                    .frame(width: 6, height: 20)
                    .overlay(Capsule().stroke(.black.opacity(0.35)))
                    .position(x: CGFloat(h) * geo.size.width, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                h = clamp01(Double(g.location.x / max(1, geo.size.width)))
                nudgeAlphaIfInvisible()
                pushLive()
            })
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.15)))
    }

    private var alphaBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                AppCheckerboard()
                LinearGradient(colors: [rgba.color.opacity(0), rgba.color.opacity(1)],
                               startPoint: .leading, endPoint: .trailing)
                Capsule().fill(.white)
                    .frame(width: 6, height: 20)
                    .overlay(Capsule().stroke(.black.opacity(0.35)))
                    .position(x: CGFloat(a) * geo.size.width, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                a = clamp01(Double(g.location.x / max(1, geo.size.width)))
                pushLive()
            })
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.15)))
    }

    // MARK: HEX / RGB / HSL

    private var formatRow: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(Fmt.allCases) { ff in
                    Button(ff.rawValue) { fmt = ff; syncFields() }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(fmt.rawValue).font(.caption2.weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                }
                .frame(width: 52)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 58)

            if fmt == .hex {
                TextField("RRGGBB", text: $f1)
                    .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    .onSubmit { applyFields() }
            } else {
                numField($f1); numField($f2); numField($f3)
            }
        }
    }

    private func numField(_ b: Binding<String>) -> some View {
        TextField("", text: b)
            .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
            .frame(width: 46)
            .multilineTextAlignment(.center)
            .onSubmit { applyFields() }
    }

    // MARK: lưới "Màu của tôi" + bảng cố định

    private var swatchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 6), count: 9), spacing: 6) {
            Button { mine.add(rgba) } label: {
                RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.35), lineWidth: 1)
                    .overlay(Image(systemName: "plus").font(.system(size: 9, weight: .bold)))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).help(L("Lưu màu hiện tại vào “Màu của tôi”"))

            ForEach(Array(mine.colors.enumerated()), id: \.offset) { _, c in
                swatchCell(c, removable: true)
            }
            ForEach(Array(Self.basePalette.enumerated()), id: \.offset) { _, c in
                swatchCell(c, removable: false)
            }
        }
    }

    private func swatchCell(_ c: RGBAColor, removable: Bool) -> some View {
        Button {
            let x = c.hsv
            h = x.h; s = x.s; v = x.v
            if supportsOpacity { a = c.a }
            pushLive()
        } label: {
            RoundedRectangle(cornerRadius: 4).fill(c.color)
                .frame(width: 20, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.18)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if removable { Button(L("Xoá khỏi Màu của tôi"), role: .destructive) { mine.remove(c) } }
        }
    }

    // MARK: helpers

    private func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

    private func pushLive() {
        syncFields()
        onChange(rgba)
    }

    /// Cập nhật các ô nhập theo h/s/v/a hiện tại.
    private func syncFields() {
        let c = rgba
        switch fmt {
        case .hex:
            f1 = supportsOpacity && a < 0.999 ? c.hexRGBA : c.hexRGB
        case .rgb:
            f1 = "\(Int((c.r * 255).rounded()))"
            f2 = "\(Int((c.g * 255).rounded()))"
            f3 = "\(Int((c.b * 255).rounded()))"
        case .hsl:
            let x = c.hsl360
            f1 = "\(Int(x.h.rounded()))"
            f2 = "\(Int(x.s.rounded()))"
            f3 = "\(Int(x.l.rounded()))"
        }
    }

    /// Đọc các ô nhập → đổi màu.
    private func applyFields() {
        switch fmt {
        case .hex:
            if let c = RGBAColor(hex: f1) {
                let x = c.hsv; h = x.h; s = x.s; v = x.v
                if supportsOpacity, f1.replacingOccurrences(of: "#", with: "").count == 8 { a = c.a }
                else { nudgeAlphaIfInvisible() }
                onChange(rgba)
            }
        case .rgb:
            let r = (Double(f1) ?? 0) / 255, g = (Double(f2) ?? 0) / 255, bl = (Double(f3) ?? 0) / 255
            let c = RGBAColor(r: max(0, min(1, r)), g: max(0, min(1, g)), b: max(0, min(1, bl)), a: a)
            let x = c.hsv; h = x.h; s = x.s; v = x.v
            nudgeAlphaIfInvisible()
            onChange(rgba)
        case .hsl:
            let c = RGBAColor(hslH: Double(f1) ?? 0, s: Double(f2) ?? 0, l: Double(f3) ?? 0, a: a)
            let x = c.hsv; h = x.h; s = x.s; v = x.v
            nudgeAlphaIfInvisible()
            onChange(rgba)
        }
        syncFields()
    }

    private func pickFromScreen() {
        let sampler = NSColorSampler()
        sampler.show { picked in
            guard let picked, let srgb = picked.usingColorSpace(.sRGB) else { return }
            let c = RGBAColor(r: Double(srgb.redComponent), g: Double(srgb.greenComponent),
                              b: Double(srgb.blueComponent), a: a)
            let x = c.hsv; h = x.h; s = x.s; v = x.v
            nudgeAlphaIfInvisible()
            pushLive()
        }
    }

    /// Bảng màu cố định (trắng→đen, cầu vồng, pastel, nổi).
    static let basePalette: [RGBAColor] = {
        func c(_ r: Int, _ g: Int, _ b: Int) -> RGBAColor {
            RGBAColor(r: Double(r) / 255, g: Double(g) / 255, b: Double(b) / 255)
        }
        return [
            c(255,255,255), c(210,210,210), c(150,150,150), c(90,90,90), c(40,40,40), c(0,0,0),
            c(230,40,40), c(255,120,30), c(255,205,20), c(120,210,40), c(30,190,120), c(30,170,230),
            c(60,90,230), c(150,60,220), c(255,60,150), c(120,80,40),
            c(150,20,20), c(190,80,10), c(200,150,10), c(60,140,20), c(15,120,90), c(15,100,160),
            c(35,50,150), c(95,30,150),
            c(255,170,170), c(255,210,150), c(255,240,150), c(190,240,160),
            c(160,235,215), c(170,215,255), c(180,190,255), c(220,180,250),
            c(255,0,255), c(0,255,180), c(255,215,0), c(0,220,255),
        ]
    }()
}
