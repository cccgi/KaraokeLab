import Foundation
import AppKit

/// Căn lề chữ karaoke trên khung hình.
enum KaraokeTextAlignment: String, Codable, CaseIterable {
    case leading
    case center
    case trailing

    var nsTextAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}

/// Biến đổi hoa/thường.
enum TextCase: String, Codable, CaseIterable {
    case none      // giữ nguyên
    case upper     // IN HOA
    case lower     // thường
    case title     // Viết Hoa Đầu Từ

    func apply(to text: String) -> String {
        switch self {
        case .none: return text
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .title: return text.capitalized
        }
    }
}

/// Hiệu ứng chữ vào/ra.
enum TextEffect: String, Codable, CaseIterable {
    case none, fade, rise, pop
    var label: String {
        switch self {
        case .none: return L("Không")
        case .fade: return L("Mờ dần")
        case .rise: return L("Trượt lên")
        case .pop:  return L("Bật lên")
        }
    }
}

/// Toàn bộ thiết lập hình thức của chữ karaoke.
/// Preview (Phase 5) và Export video (Phase 7) đều đọc cùng struct này.
struct KaraokeStyle: Equatable {
    // Font
    var fontName: String = "Helvetica Neue"
    var fontSize: Double = 64
    var fontBold: Bool = false
    var fontItalic: Bool = false
    var fontUnderline: Bool = false
    var textCase: TextCase = .none
    var characterSpacing: Double = 0

    // Màu chữ — `*Color` = màu ĐƠN (giữ để tương thích); `*Fill` = tô đơn sắc HOẶC gradient (nguồn thật).
    var textColor: RGBAColor = .white                                  // chữ CHƯA hát
    var highlightColor: RGBAColor = RGBAColor(r: 1.0, g: 0.82, b: 0.10) // chữ ĐANG hát
    var textFill: ColorFill = .solid(.white)
    var highlightFill: ColorFill = .solid(RGBAColor(r: 1.0, g: 0.82, b: 0.10))

    // Viền (outline) — màu riêng cho chữ chưa hát / đang hát
    var outlineEnabled: Bool = true
    var outlineColor: RGBAColor = .black          // viền chữ CHƯA hát (legacy)
    var outlineColorSung: RGBAColor = .black      // viền chữ ĐANG hát
    var outlineWidth: Double = 3
    var outlineFill: ColorFill = .solid(.black)   // viền CHƯA hát — đơn sắc hoặc gradient

    // Đổ bóng (shadow)
    var shadowEnabled: Bool = true
    var shadowColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)   // legacy / màu đơn
    var shadowRadius: Double = 6
    var shadowOffsetX: Double = 0
    var shadowOffsetY: Double = 3
    var shadowFill: ColorFill = .solid(RGBAColor(r: 0, g: 0, b: 0, a: 0.6))

    // Phát sáng (glow)
    var glowEnabled: Bool = false
    var glowColor: RGBAColor = RGBAColor(r: 0.20, g: 0.55, b: 0.98, a: 0.9)   // legacy / màu đơn
    var glowRadius: Double = 16
    var glowFill: ColorFill = .solid(RGBAColor(r: 0.20, g: 0.55, b: 0.98, a: 0.9))

    // Khung nền sau chữ
    var backgroundEnabled: Bool = false
    var backgroundColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)   // legacy
    var backgroundPadding: Double = 18
    var backgroundCornerRadius: Double = 10
    var backgroundFill: ColorFill = .solid(RGBAColor(r: 0, g: 0, b: 0, a: 0.5))

    // Bố cục
    var alignment: KaraokeTextAlignment = .center
    var lineSpacing: Double = 14
    var verticalAnchor: Double = 0.82        // 0 = sát đỉnh, 1 = sát đáy
    var horizontalMarginRatio: Double = 0.08 // lề trái/phải theo bề rộng khung
    var horizontalOffset: Double = 0         // dời cả khối chữ sang ngang (tỉ lệ bề rộng, + = phải)
    /// (Không dùng nữa — so le giờ TỰ động khi câu hiển thị ≥ 2 dòng. Giữ khoá để mở project cũ.)
    var staggerRows: Bool = false

    // Quan hệ với câu kế tiếp — câu kế tiếp dùng CHÍNH style này, chỉ mờ đi.
    // `showNextLine`/`nextLineGap`: (BỎ 2026-09-09) — "nhắc câu tiếp theo" đã gỡ khỏi UI + renderer.
    // Giữ khoá để mở project cũ. `alwaysTwoRows` thay thế: câu ngắn kéo câu kế xuống dòng 2.
    var showNextLine: Bool = true
    var nextLineGap: Double = 0.14           // cách câu chính bao nhiêu (tỉ lệ chiều cao)
    /// Khung chữ LUÔN 2 dòng: câu đang hát chỉ 1 dòng → mượn câu kế tiếp làm dòng 2 (mờ,
    /// KHÔNG quét). Mặc định BẬT ở preset "Karaoke Chuẩn" (`mine0`), TẮT ở "Lyric theo nhạc".
    var alwaysTwoRows: Bool = false

    // Hiệu ứng chữ vào / ra + mép quét mềm
    var entranceEffect: TextEffect = .none
    var exitEffect: TextEffect = .none
    var effectDuration: Double = 0.35        // giây cho mỗi lần vào/ra
    var softWipe: Bool = false               // mép vệt hát loang mềm thay vì cắt gắt
    var wipeGlow: Bool = false               // vệt sáng chạy theo mép hát

    static let `default` = KaraokeStyle()

    // MARK: 2 preset MẶC ĐỊNH — "Kiểu của tôi 0" & "kiểu của tôi 1" (do user lưu, promote thành built-in).

    /// "Karaoke" — MẶC ĐỊNH cho project mới / sau khi tạo karaoke.
    /// 2026-09-13: THAY BẰNG style lấy từ project "karaoke.kbproj" (user chọn làm mặc định mới,
    /// thay cho bản lấy từ "anh lai nho .kbproj" trước đó).
    static let mine0: KaraokeStyle = {
        var s = KaraokeStyle()
        s.fontName = "UTM Erie Black"
        s.fontSize = 77.99208784054485
        s.fontBold = false
        s.fontItalic = false
        s.fontUnderline = false
        s.textCase = .upper
        s.characterSpacing = 0
        s.textColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)
        s.highlightColor = RGBAColor(r: 0.12487742402922607, g: 0.22706550232057104, b: 0.7039432010135135, a: 1)
        s.textFill = .solid(s.textColor)
        s.highlightFill = .solid(s.highlightColor)
        s.outlineEnabled = true
        s.outlineColor = RGBAColor(r: 0, g: 0, b: 0, a: 1)
        s.outlineFill = .solid(s.outlineColor)
        s.outlineColorSung = RGBAColor(r: 1, g: 1, b: 1, a: 1)
        s.outlineWidth = 5.277406350160257
        s.shadowEnabled = true
        s.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)
        s.shadowFill = .solid(s.shadowColor)
        s.shadowRadius = 0
        s.shadowOffsetX = -5.790936748798078
        s.shadowOffsetY = -2.268473933293265
        s.glowEnabled = false
        s.glowColor = RGBAColor(r: 0.20, g: 0.55, b: 0.98, a: 0.9)
        s.glowFill = .solid(s.glowColor)
        s.glowRadius = 16
        s.backgroundEnabled = false
        s.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        s.backgroundFill = .solid(s.backgroundColor)
        s.backgroundPadding = 18
        s.backgroundCornerRadius = 10
        s.alignment = .center
        s.lineSpacing = 12.6392578125
        s.verticalAnchor = 0.8435343650285574
        s.horizontalMarginRatio = 0.0448389892578125
        s.horizontalOffset = -0.012062816088026245
        s.showNextLine = false
        s.nextLineGap = 0.18922017415364584
        s.alwaysTwoRows = true            // "Karaoke": khung chữ luôn 2 dòng
        return s
    }()

    /// "Karaoke" — câu nhắc tiếp theo.
    static let mine0Next: KaraokeStyle = {
        var s = KaraokeStyle()
        s.fontName = "UTM Erie Black"
        s.fontSize = 46.834300130208334
        s.fontItalic = true
        s.textCase = .title
        s.textColor = RGBAColor(r: 0.7429266572, g: 0.9221233726, b: 0.2350486517, a: 1)
        s.highlightColor = RGBAColor(r: 0.88, g: 0.88, b: 0.88, a: 0.85)
        s.textFill = .solid(s.textColor)
        s.highlightFill = .solid(s.highlightColor)
        s.outlineEnabled = true
        s.outlineColor = RGBAColor(r: 0, g: 0, b: 0, a: 1)
        s.outlineFill = .solid(s.outlineColor)
        s.outlineColorSung = RGBAColor(r: 0, g: 0, b: 0, a: 1)
        s.outlineWidth = 4.8689697265625
        s.shadowEnabled = true
        s.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)
        s.shadowFill = .solid(s.shadowColor)
        s.shadowRadius = 4.673518880208333
        s.shadowOffsetX = -0.8228759765625
        s.shadowOffsetY = 2.63427734375
        s.glowEnabled = false
        s.backgroundEnabled = false
        s.alignment = .center
        s.lineSpacing = 14
        s.verticalAnchor = 0.82
        s.horizontalMarginRatio = 0.08
        s.showNextLine = false
        s.nextLineGap = 0.14
        return s
    }()

    /// "Lyric" — MẶC ĐỊNH thứ 2. 2026-09-13: THAY BẰNG style lấy từ project "lyric.kbproj"
    /// (bản trước lấy nhầm màu `color2` của ô tô đơn sắc thay vì `color` — sửa luôn ở đây).
    static let mine1: KaraokeStyle = {
        var s = KaraokeStyle()
        s.fontName = "UTM American Sans"
        s.fontSize = 49.04956380208332
        s.textCase = .upper
        s.characterSpacing = 3.723763020833333
        s.textColor = RGBAColor(r: 1, g: 1, b: 1, a: 1)
        s.highlightColor = RGBAColor(r: 0.11764705882352944, g: 0.6666666666666675, b: 0.9019607843137255, a: 1)
        s.textFill = .solid(s.textColor)
        s.highlightFill = .solid(s.highlightColor)
        s.outlineEnabled = false
        s.outlineColor = RGBAColor(r: 0, g: 0, b: 0, a: 1)
        s.outlineFill = .solid(s.outlineColor)
        s.outlineColorSung = RGBAColor(r: 1, g: 1, b: 1, a: 1)
        s.outlineWidth = 2.3778971354166667
        s.shadowEnabled = true
        s.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.2196377840909091)
        s.shadowFill = .solid(s.shadowColor)
        s.shadowRadius = 10.152083333333334
        s.shadowOffsetX = -2.6515136718750014
        s.shadowOffsetY = 2.954272460937503
        s.glowEnabled = false
        s.glowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.8999999761581421)
        s.glowFill = .solid(s.glowColor)
        s.glowRadius = 12.044921875
        s.backgroundEnabled = false
        s.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        s.backgroundFill = .solid(s.backgroundColor)
        s.backgroundPadding = 14.460156249999999
        s.backgroundCornerRadius = 9.8265625
        s.alignment = .center
        s.lineSpacing = 12.6392578125
        s.verticalAnchor = 0.9259230752856705
        s.horizontalMarginRatio = 0.0448389892578125
        s.showNextLine = false
        s.nextLineGap = 0.18922017415364584
        return s
    }()

    /// "Lyric" — câu nhắc tiếp theo.
    static let mine1Next: KaraokeStyle = {
        var s = KaraokeStyle()
        s.fontName = "UTM American Sans"
        s.fontSize = 34
        s.fontItalic = true
        s.textCase = .title
        s.characterSpacing = 3.723763020833333
        s.textColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.72)
        s.highlightColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.72)
        s.textFill = .solid(s.textColor)
        s.highlightFill = .solid(s.highlightColor)
        s.outlineEnabled = true
        s.outlineColor = RGBAColor(r: 0, g: 0, b: 0, a: 1)
        s.outlineFill = .solid(s.outlineColor)
        s.outlineColorSung = RGBAColor(r: 1, g: 1, b: 1, a: 1)
        s.outlineWidth = 2
        s.shadowEnabled = false
        s.shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.6)
        s.shadowFill = .solid(s.shadowColor)
        s.shadowRadius = 10.152083333333334
        s.shadowOffsetX = -2.6515136718750014
        s.shadowOffsetY = 2.954272460937503
        s.glowEnabled = false
        s.glowColor = RGBAColor(r: 0.12828868627548218, g: 0.5324276685714722, b: 0.6696231961250305, a: 0.9)
        s.glowFill = .solid(s.glowColor)
        s.glowRadius = 12.044921875
        s.backgroundEnabled = false
        s.backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        s.backgroundFill = .solid(s.backgroundColor)
        s.backgroundPadding = 14.460156249999999
        s.backgroundCornerRadius = 9.8265625
        s.alignment = .center
        s.lineSpacing = 12.6392578125
        s.verticalAnchor = 0.82
        s.horizontalMarginRatio = 0.0448389892578125
        s.showNextLine = false
        s.nextLineGap = 0.18922017415364584
        return s
    }()


    /// Nhân các thông số PIXEL với `s` để chữ giữ NGUYÊN tỉ lệ khi đổi độ phân giải
    /// (renderer quy chiếu theo khung 1080). Các thông số tỉ lệ (%) không đụng tới.
    func scaled(by s: Double) -> KaraokeStyle {
        guard s > 0, s != 1 else { return self }
        var c = self
        c.fontSize *= s
        c.characterSpacing *= s
        c.outlineWidth *= s
        c.shadowRadius *= s
        c.shadowOffsetX *= s
        c.shadowOffsetY *= s
        c.glowRadius *= s
        c.backgroundPadding *= s
        c.backgroundCornerRadius *= s
        c.lineSpacing *= s
        return c
    }
}

// MARK: - Codable "khoan dung" (project cũ thiếu khoá vẫn mở được)

extension KaraokeStyle: Codable {
    enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontBold, fontItalic, fontUnderline, textCase, characterSpacing
        case textColor, highlightColor, textFill, highlightFill
        case outlineEnabled, outlineColor, outlineColorSung, outlineWidth, outlineFill
        case shadowEnabled, shadowColor, shadowRadius, shadowOffsetX, shadowOffsetY, shadowFill
        case glowEnabled, glowColor, glowRadius, glowFill
        case backgroundEnabled, backgroundColor, backgroundPadding, backgroundCornerRadius, backgroundFill
        case alignment, lineSpacing, verticalAnchor, horizontalMarginRatio, horizontalOffset, staggerRows
        case showNextLine, nextLineGap, alwaysTwoRows
        case entranceEffect, exitEffect, effectDuration, softWipe, wipeGlow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        fontName             = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        fontSize             = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        fontBold             = try c.decodeIfPresent(Bool.self, forKey: .fontBold) ?? fontBold
        fontItalic           = try c.decodeIfPresent(Bool.self, forKey: .fontItalic) ?? fontItalic
        fontUnderline        = try c.decodeIfPresent(Bool.self, forKey: .fontUnderline) ?? fontUnderline
        textCase             = try c.decodeIfPresent(TextCase.self, forKey: .textCase) ?? textCase
        characterSpacing     = try c.decodeIfPresent(Double.self, forKey: .characterSpacing) ?? characterSpacing
        textColor            = try c.decodeIfPresent(RGBAColor.self, forKey: .textColor) ?? textColor
        highlightColor       = try c.decodeIfPresent(RGBAColor.self, forKey: .highlightColor) ?? highlightColor
        textFill             = try c.decodeIfPresent(ColorFill.self, forKey: .textFill) ?? .solid(textColor)
        highlightFill        = try c.decodeIfPresent(ColorFill.self, forKey: .highlightFill) ?? .solid(highlightColor)
        outlineEnabled       = try c.decodeIfPresent(Bool.self, forKey: .outlineEnabled) ?? outlineEnabled
        outlineColor         = try c.decodeIfPresent(RGBAColor.self, forKey: .outlineColor) ?? outlineColor
        // Project cũ: viền đang hát = viền chưa hát (không đổi hình).
        outlineColorSung     = try c.decodeIfPresent(RGBAColor.self, forKey: .outlineColorSung) ?? outlineColor
        outlineWidth         = try c.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? outlineWidth
        outlineFill          = try c.decodeIfPresent(ColorFill.self, forKey: .outlineFill) ?? .solid(outlineColor)
        shadowEnabled        = try c.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? shadowEnabled
        shadowColor          = try c.decodeIfPresent(RGBAColor.self, forKey: .shadowColor) ?? shadowColor
        shadowRadius         = try c.decodeIfPresent(Double.self, forKey: .shadowRadius) ?? shadowRadius
        shadowOffsetX        = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetX) ?? shadowOffsetX
        shadowOffsetY        = try c.decodeIfPresent(Double.self, forKey: .shadowOffsetY) ?? shadowOffsetY
        shadowFill           = try c.decodeIfPresent(ColorFill.self, forKey: .shadowFill) ?? .solid(shadowColor)
        glowEnabled          = try c.decodeIfPresent(Bool.self, forKey: .glowEnabled) ?? glowEnabled
        glowColor            = try c.decodeIfPresent(RGBAColor.self, forKey: .glowColor) ?? glowColor
        glowRadius           = try c.decodeIfPresent(Double.self, forKey: .glowRadius) ?? glowRadius
        glowFill             = try c.decodeIfPresent(ColorFill.self, forKey: .glowFill) ?? .solid(glowColor)
        backgroundEnabled    = try c.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? backgroundEnabled
        backgroundColor      = try c.decodeIfPresent(RGBAColor.self, forKey: .backgroundColor) ?? backgroundColor
        backgroundPadding    = try c.decodeIfPresent(Double.self, forKey: .backgroundPadding) ?? backgroundPadding
        backgroundCornerRadius = try c.decodeIfPresent(Double.self, forKey: .backgroundCornerRadius) ?? backgroundCornerRadius
        backgroundFill       = try c.decodeIfPresent(ColorFill.self, forKey: .backgroundFill) ?? .solid(backgroundColor)
        alignment            = try c.decodeIfPresent(KaraokeTextAlignment.self, forKey: .alignment) ?? alignment
        lineSpacing          = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? lineSpacing
        verticalAnchor       = try c.decodeIfPresent(Double.self, forKey: .verticalAnchor) ?? verticalAnchor
        horizontalMarginRatio = try c.decodeIfPresent(Double.self, forKey: .horizontalMarginRatio) ?? horizontalMarginRatio
        horizontalOffset     = try c.decodeIfPresent(Double.self, forKey: .horizontalOffset) ?? horizontalOffset
        staggerRows          = try c.decodeIfPresent(Bool.self, forKey: .staggerRows) ?? staggerRows
        showNextLine         = try c.decodeIfPresent(Bool.self, forKey: .showNextLine) ?? showNextLine
        nextLineGap          = try c.decodeIfPresent(Double.self, forKey: .nextLineGap) ?? nextLineGap
        alwaysTwoRows        = try c.decodeIfPresent(Bool.self, forKey: .alwaysTwoRows) ?? alwaysTwoRows
        entranceEffect       = try c.decodeIfPresent(TextEffect.self, forKey: .entranceEffect) ?? entranceEffect
        exitEffect           = try c.decodeIfPresent(TextEffect.self, forKey: .exitEffect) ?? exitEffect
        effectDuration       = try c.decodeIfPresent(Double.self, forKey: .effectDuration) ?? effectDuration
        softWipe             = try c.decodeIfPresent(Bool.self, forKey: .softWipe) ?? softWipe
        wipeGlow             = try c.decodeIfPresent(Bool.self, forKey: .wipeGlow) ?? wipeGlow
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fontName, forKey: .fontName)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(fontBold, forKey: .fontBold)
        try c.encode(fontItalic, forKey: .fontItalic)
        try c.encode(fontUnderline, forKey: .fontUnderline)
        try c.encode(textCase, forKey: .textCase)
        try c.encode(characterSpacing, forKey: .characterSpacing)
        try c.encode(textColor, forKey: .textColor)
        try c.encode(highlightColor, forKey: .highlightColor)
        try c.encode(textFill, forKey: .textFill)
        try c.encode(highlightFill, forKey: .highlightFill)
        try c.encode(outlineEnabled, forKey: .outlineEnabled)
        try c.encode(outlineColor, forKey: .outlineColor)
        try c.encode(outlineColorSung, forKey: .outlineColorSung)
        try c.encode(outlineWidth, forKey: .outlineWidth)
        try c.encode(outlineFill, forKey: .outlineFill)
        try c.encode(shadowEnabled, forKey: .shadowEnabled)
        try c.encode(shadowColor, forKey: .shadowColor)
        try c.encode(shadowRadius, forKey: .shadowRadius)
        try c.encode(shadowOffsetX, forKey: .shadowOffsetX)
        try c.encode(shadowOffsetY, forKey: .shadowOffsetY)
        try c.encode(shadowFill, forKey: .shadowFill)
        try c.encode(glowEnabled, forKey: .glowEnabled)
        try c.encode(glowColor, forKey: .glowColor)
        try c.encode(glowRadius, forKey: .glowRadius)
        try c.encode(glowFill, forKey: .glowFill)
        try c.encode(backgroundEnabled, forKey: .backgroundEnabled)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(backgroundPadding, forKey: .backgroundPadding)
        try c.encode(backgroundCornerRadius, forKey: .backgroundCornerRadius)
        try c.encode(backgroundFill, forKey: .backgroundFill)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(verticalAnchor, forKey: .verticalAnchor)
        try c.encode(horizontalMarginRatio, forKey: .horizontalMarginRatio)
        try c.encode(horizontalOffset, forKey: .horizontalOffset)
        try c.encode(staggerRows, forKey: .staggerRows)
        try c.encode(showNextLine, forKey: .showNextLine)
        try c.encode(nextLineGap, forKey: .nextLineGap)
        try c.encode(alwaysTwoRows, forKey: .alwaysTwoRows)
        try c.encode(entranceEffect, forKey: .entranceEffect)
        try c.encode(exitEffect, forKey: .exitEffect)
        try c.encode(effectDuration, forKey: .effectDuration)
        try c.encode(softWipe, forKey: .softWipe)
        try c.encode(wipeGlow, forKey: .wipeGlow)
    }
}
