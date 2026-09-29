import SwiftUI
import AppKit

/// Bảng màu + kích thước tối kiểu editor chuyên nghiệp (CapCut / Final Cut).
enum Theme {
    // Bề mặt (tối dần → sáng dần)
    static let bg        = Color(red: 0.09, green: 0.09, blue: 0.10)   // nền cửa sổ
    static let panel     = Color(red: 0.13, green: 0.13, blue: 0.145)  // cột / khu chính
    static let panelAlt  = Color(red: 0.165, green: 0.165, blue: 0.18) // thanh công cụ / mục nổi
    static let elevated  = Color(red: 0.22, green: 0.22, blue: 0.245)  // control / hover
    static let stroke    = Color.white.opacity(0.07)
    static let strokeStrong = Color.white.opacity(0.15)

    /// #2395c5 — MÀU NHẤN DUY NHẤT của app. Dùng cho nút chính, mục đang chọn, vạch đỏ… nhất quán.
    static let accent    = Color(red: 0x23 / 255, green: 0x95 / 255, blue: 0xC5 / 255)
    static let accentSoft = Color(red: 0x23 / 255, green: 0x95 / 255, blue: 0xC5 / 255).opacity(0.16)
    /// #2395c5 cho code AppKit (Core Graphics).
    static let accentNS  = NSColor(srgbRed: 0x23 / 255, green: 0x95 / 255, blue: 0xC5 / 255, alpha: 1)

    static let ink       = Color.white.opacity(0.92)
    static let inkDim     = Color.white.opacity(0.55)

    // Kích thước nhất quán (một hệ, khỏi mỗi chỗ một số)
    enum Metric {
        static let topbarH: CGFloat  = 46      // chiều cao thanh trên
        static let railW: CGFloat    = 96      // bề rộng rail icon cột trái
        static let pad: CGFloat      = 16      // padding khu vực
        static let gap: CGFloat      = 10      // khoảng cách giữa control
        static let radius: CGFloat   = 10      // bo góc thẻ / control
        static let radiusSm: CGFloat = 7
    }
}

extension View {
    /// Tiêu đề một mục trong panel — dùng chung để mọi mục nhìn giống nhau.
    func sectionHeaderStyle() -> some View {
        self.font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.inkDim)
            .textCase(.uppercase)
            .kerning(0.4)
    }
}
