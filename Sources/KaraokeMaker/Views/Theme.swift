import SwiftUI
import AppKit

/// Hệ thiết kế của app — NGUỒN DUY NHẤT cho màu / chữ / khoảng cách / bo góc / chiều cao control.
/// Quy chuẩn đầy đủ: `docs/DESIGN_SYSTEM.md`. Code giao diện không viết số / màu tay (ngoại lệ phải ghi chú).
/// Chỉ chế độ tối (app ép `.dark`). Hiệu năng Intel > hiệu ứng: không bóng / blur cho panel, timeline, preview.
enum Theme {
    // MARK: Bề mặt (tối dần → sáng dần)
    static let bg        = Color(red: 0.09, green: 0.09, blue: 0.10)   // #171719 nền cửa sổ, quanh preview
    static let panel     = Color(red: 0.13, green: 0.13, blue: 0.145)  // #212125 panel trái / inspector / timeline
    static let panelAlt  = Color(red: 0.165, green: 0.165, blue: 0.18) // #2A2A2E toolbar, thanh tiêu đề panel
    static let elevated  = Color(red: 0.22, green: 0.22, blue: 0.245)  // #38383E nền control (field, nút phụ)
    static let stroke    = Color.white.opacity(0.07)                   // đường kẻ giữa panel / mục
    static let strokeStrong = Color.white.opacity(0.14)                // viền field, viền khi hover

    // MARK: Chữ
    static let ink         = Color.white.opacity(0.92)   // chữ chính
    static let inkDim      = Color.white.opacity(0.60)   // chữ phụ, nhãn
    static let inkFaint    = Color.white.opacity(0.40)   // gợi ý, đơn vị, thước timeline
    static let inkDisabled = Color.white.opacity(0.25)   // chữ / icon bị khoá

    // MARK: Nhấn + trạng thái
    /// #2395c5 — MÀU NHẤN DUY NHẤT (màu thương hiệu, chủ dự án chọn): hành động chính, mục đang chọn, dòng đang hát, focus.
    static let accent      = Color(red: 0x23 / 255, green: 0x95 / 255, blue: 0xC5 / 255)
    static let accentSoft  = Color(red: 0x23 / 255, green: 0x95 / 255, blue: 0xC5 / 255).opacity(0.16)
    static let accentHover = Color(red: 0x2F / 255, green: 0xA6 / 255, blue: 0xD8 / 255)
    /// #2395c5 cho code AppKit (Core Graphics).
    static let accentNS    = NSColor(srgbRed: 0x23 / 255, green: 0x95 / 255, blue: 0xC5 / 255, alpha: 1)
    static let hover       = Color.white.opacity(0.06)
    static let pressed     = Color.white.opacity(0.10)
    static let warning     = Color(red: 0xD6 / 255, green: 0xA4 / 255, blue: 0x45 / 255)   // từ chưa chắc, cảnh báo nhẹ
    static let error       = Color(red: 0xE5 / 255, green: 0x53 / 255, blue: 0x4B / 255)   // lỗi, xoá
    static let success     = Color(red: 0x45 / 255, green: 0xB3 / 255, blue: 0x7E / 255)   // "xong" (luôn kèm icon ✓)
    /// Vạch đỏ (playhead) — giữ ĐỎ: mọi hướng dẫn trong app gọi nó là "vạch đỏ".
    static let playhead    = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)

    /// Bản NSColor cho AppKit / Core Graphics — `static let` để không tạo màu mới mỗi lần vẽ.
    enum NS {
        static let bg        = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        static let panel     = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.145, alpha: 1)
        static let panelAlt  = NSColor(srgbRed: 0.165, green: 0.165, blue: 0.18, alpha: 1)
        static let stroke    = NSColor.white.withAlphaComponent(0.07)
        static let ink       = NSColor.white.withAlphaComponent(0.92)
        static let inkDim    = NSColor.white.withAlphaComponent(0.60)
        static let inkFaint  = NSColor.white.withAlphaComponent(0.40)
        static let accent    = Theme.accentNS
        static let warning   = NSColor(srgbRed: 0xD6 / 255, green: 0xA4 / 255, blue: 0x45 / 255, alpha: 1)
        static let error     = NSColor(srgbRed: 0xE5 / 255, green: 0x53 / 255, blue: 0x4B / 255, alpha: 1)
        static let success   = NSColor(srgbRed: 0x45 / 255, green: 0xB3 / 255, blue: 0x7E / 255, alpha: 1)
        static let playhead  = NSColor(srgbRed: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255, alpha: 1)
        // Màu LÀN timeline (bão hoà thấp, luôn đi kèm nhãn / icon) — DESIGN_SYSTEM §14.
        static let trackMedia   = NSColor(srgbRed: 0x6E / 255, green: 0x66 / 255, blue: 0xB0 / 255, alpha: 1) // ảnh / video
        static let trackText    = NSColor(srgbRed: 0x5B / 255, green: 0x7F / 255, blue: 0xA6 / 255, alpha: 1) // lớp chữ
        static let trackAudio   = NSColor(srgbRed: 0x4F / 255, green: 0x8F / 255, blue: 0x6B / 255, alpha: 1) // nhạc thêm
        static let trackKaraoke = NSColor(srgbRed: 0x3E / 255, green: 0x92 / 255, blue: 0x8C / 255, alpha: 1) // clip KARAOKE
        static let stagingLine  = NSColor(srgbRed: 0xC9 / 255, green: 0x85 / 255, blue: 0x3A / 255, alpha: 1) // DÒNG đang chờ
        static let stagingWord  = NSColor(srgbRed: 0x4C / 255, green: 0x8F / 255, blue: 0xD1 / 255, alpha: 1) // CHỮ đang chờ

        /// Ảnh SF Symbol đã tô màu, cache sẵn — để vẽ icon trong Core Graphics (thay emoji).
        private static var symbolCache: [String: NSImage] = [:]
        static func symbol(_ name: String, size: CGFloat, color: NSColor = .white) -> NSImage? {
            let key = "\(name)|\(size)|\(color.hash)"
            if let hit = symbolCache[key] { return hit }
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)) else { return nil }
            let tinted = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
            }
            symbolCache[key] = tinted
            return tinted
        }
    }

    // MARK: Chữ (SF Pro hệ thống) — 9 cỡ chuẩn, không dùng cỡ khác trong editor
    enum Typo {
        static let title      = Font.system(size: 13, weight: .semibold)   // tên dự án, tiêu đề workspace
        static let panelTitle = Font.system(size: 11, weight: .semibold)   // tiêu đề panel / mục (IN HOA — xem sectionHeaderStyle)
        static let label      = Font.system(size: 12)                      // nhãn control, mục danh sách
        static let labelStrong = Font.system(size: 12, weight: .semibold)  // chữ trên nút
        static let body       = Font.system(size: 12)
        static let helper     = Font.system(size: 11)                      // chú thích 1 dòng (màu inkFaint)
        static let mono       = Font.system(size: 12).monospacedDigit()    // mã thời gian, số đo
        static let sheetTitle = Font.system(size: 15, weight: .semibold)   // tiêu đề sheet / hộp thoại
        static let homeTitle  = Font.system(size: 20, weight: .semibold)   // chỉ màn Home
        static let badge      = Font.system(size: 10, weight: .semibold)   // huy hiệu nhỏ
        static let icon       = Font.system(size: 13)                      // icon toolbar
        static let iconSmall  = Font.system(size: 12)                      // icon trong panel
    }

    // MARK: Khoảng cách — thang duy nhất
    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 6, m: CGFloat = 8, l: CGFloat = 12, xl: CGFloat = 16, xxl: CGFloat = 24
    }

    // MARK: Bo góc — panel / preview phẳng; tối đa 8 trong editor
    enum Radius {
        static let none: CGFloat = 0, xs: CGFloat = 3, sm: CGFloat = 4, md: CGFloat = 6, lg: CGFloat = 8
    }

    // MARK: Chiều cao control
    enum ControlH {
        static let small: CGFloat = 22, regular: CGFloat = 26, large: CGFloat = 30
    }

    // MARK: Kích thước khung (giữ tên cũ — code cũ dùng `Theme.Metric.*`)
    enum Metric {
        static let topbarH: CGFloat  = 40      // chiều cao thanh trên
        static let railW: CGFloat    = 96      // bề rộng rail icon cột trái
        static let pad: CGFloat      = 12      // padding khu vực (= Space.l)
        static let gap: CGFloat      = 8       // khoảng cách giữa control (= Space.m)
        static let radius: CGFloat   = 8       // popover / overlay nổi (= Radius.lg)
        static let radiusSm: CGFloat = 6       // nút / thumbnail (= Radius.md)
        static let panelHeaderH: CGFloat = 30  // thanh tiêu đề panel
    }
}

extension View {
    /// Tiêu đề một mục trong panel — dùng chung để mọi mục nhìn giống nhau.
    func sectionHeaderStyle() -> some View {
        self.font(Theme.Typo.panelTitle)
            .foregroundStyle(Theme.inkDim)
            .textCase(.uppercase)
            .kerning(0.4)
    }
}

// MARK: - Nút 3 cấp (DESIGN_SYSTEM §7)

/// Nút CHÍNH — nền nhấn. Tối đa 1 nút chính mỗi vùng (toolbar: Xuất; luồng tạo: Tạo; sheet Xuất: Xuất).
struct KMPrimaryButtonStyle: ButtonStyle {
    var large = false
    func makeBody(configuration: Configuration) -> some View {
        KMButtonBody(configuration: configuration, kind: .primary, height: large ? Theme.ControlH.large : Theme.ControlH.regular)
    }
}

/// Nút PHỤ — nền control xám. `selected` = trạng thái BẬT của nút bật/tắt (nền nhấn nhạt + chữ nhấn).
struct KMSecondaryButtonStyle: ButtonStyle {
    var small = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        KMButtonBody(configuration: configuration, kind: selected ? .selected : .secondary,
                     height: small ? Theme.ControlH.small : Theme.ControlH.regular)
    }
}

/// Nút ICON (cấp 3) — không nền, hiện nền khi hover. Luôn kèm `.help(...)`.
struct KMIconButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        KMButtonBody(configuration: configuration, kind: selected ? .iconSelected : .icon, height: Theme.ControlH.small)
    }
}

extension ButtonStyle where Self == KMPrimaryButtonStyle {
    static var kmPrimary: KMPrimaryButtonStyle { KMPrimaryButtonStyle() }
    static var kmPrimaryLarge: KMPrimaryButtonStyle { KMPrimaryButtonStyle(large: true) }
}
extension ButtonStyle where Self == KMSecondaryButtonStyle {
    static var kmSecondary: KMSecondaryButtonStyle { KMSecondaryButtonStyle() }
    static var kmSecondarySmall: KMSecondaryButtonStyle { KMSecondaryButtonStyle(small: true) }
    static func kmToggle(_ on: Bool, small: Bool = true) -> KMSecondaryButtonStyle { KMSecondaryButtonStyle(small: small, selected: on) }
}
extension ButtonStyle where Self == KMIconButtonStyle {
    static var kmIcon: KMIconButtonStyle { KMIconButtonStyle() }
}

/// Thân nút dùng chung — giữ trạng thái hover cục bộ (không đẩy gì lên view cha → không làm body lớn chạy lại).
private struct KMButtonBody: View {
    enum Kind { case primary, secondary, selected, icon, iconSelected }
    let configuration: ButtonStyle.Configuration
    let kind: Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(kind == .icon || kind == .iconSelected ? Theme.Typo.icon : Theme.Typo.labelStrong)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .icon || kind == .iconSelected ? Theme.Space.xs : Theme.Space.l)
            .frame(minWidth: height, minHeight: height)
            .background(RoundedRectangle(cornerRadius: kind == .icon || kind == .iconSelected ? Theme.Radius.sm : Theme.Radius.md)
                .fill(background))
            .overlay {
                if kind == .secondary && isEnabled {
                    RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(hovering ? Theme.strokeStrong : Theme.stroke)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.inkDisabled }
        switch kind {
        case .primary: return .white
        case .selected, .iconSelected: return Theme.accent
        case .secondary: return Theme.ink
        case .icon: return hovering ? Theme.ink : Theme.inkDim
        }
    }

    private var background: Color {
        let p = configuration.isPressed
        switch kind {
        case .primary:
            guard isEnabled else { return Theme.elevated.opacity(0.6) }
            return p ? Theme.accent.opacity(0.85) : (hovering ? Theme.accentHover : Theme.accent)
        case .secondary:
            guard isEnabled else { return Theme.elevated.opacity(0.4) }
            return p ? Theme.elevated.opacity(0.7) : (hovering ? Theme.elevated.opacity(1) : Theme.elevated.opacity(0.85))
        case .selected, .iconSelected:
            return p ? Theme.accent.opacity(0.26) : Theme.accentSoft
        case .icon:
            guard isEnabled else { return .clear }
            return p ? Theme.pressed : (hovering ? Theme.hover : .clear)
        }
    }
}

// MARK: - Thanh tiêu đề panel (DESIGN_SYSTEM §9)

/// Thanh tiêu đề 30pt dùng chung cho mọi panel / inspector: icon + tiêu đề IN HOA + nút bên phải.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    var iconTint: Color = Theme.inkDim
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(iconTint) }
            Text(title).sectionHeaderStyle().lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Theme.Space.s)
            trailing()
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Metric.panelHeaderH)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, icon: String? = nil, iconTint: Color = Theme.inkDim) {
        self.init(title: title, icon: icon, iconTint: iconTint, trailing: { EmptyView() })
    }
}

// MARK: - Thẻ lựa chọn (chỉ cho các lựa chọn NGANG NHAU, ví dụ 2 đường tạo karaoke — DESIGN_SYSTEM §15)

struct KMChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.l) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(enabled ? Theme.accent : Theme.inkDisabled)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Typo.title).foregroundStyle(enabled ? Theme.ink : Theme.inkDisabled)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle).font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.inkFaint)
            }
            .padding(Theme.Space.l)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovering && enabled ? Theme.elevated : Theme.panelAlt))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(hovering && enabled ? Theme.strokeStrong : Theme.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

// MARK: - Đồng hồ "đã chạy" cho 1 chặng tiến trình (tự đếm từ lúc xuất hiện; chỉ view nhỏ này vẽ lại mỗi giây)

struct ElapsedLabel: View {
    @State private var start = Date()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", s / 60, s % 60))
                .font(Theme.Typo.mono).foregroundStyle(Theme.inkFaint)
        }
    }
}
