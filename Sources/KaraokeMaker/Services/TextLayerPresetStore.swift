import Foundation

/// Ảnh chụp KIỂU của 1 lớp chữ (không gồm nội dung / vị trí / thời lượng) — để lưu & dùng lại.
struct TextLayerStyle: Codable, Equatable {
    var fontName = "Helvetica Neue"
    var fontSize = 96.0
    var bold = false
    var italic = false
    var lineSpacing = 0.0
    var charSpacing = 0.0
    var wrapFrac = 0.8
    var color = RGBAColor.white
    var fill = ColorFill.solid(.white)
    var alignRaw = KaraokeTextAlignment.center.rawValue
    var outlineColor = RGBAColor.black
    var outlineFill = ColorFill.solid(.black)
    var outlineWidth = 0.0
    var backgroundColor = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    var backgroundFill = ColorFill.solid(RGBAColor(r: 0, g: 0, b: 0, a: 0))
    var shadowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    var shadowFill = ColorFill.solid(RGBAColor(r: 0, g: 0, b: 0, a: 0))
    var shadowRadius = 10.0
    var shadowDX = 0.0
    var shadowDY = 5.0
    var glowColor = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    var glowFill = ColorFill.solid(RGBAColor(r: 0, g: 0, b: 0, a: 0))
    var glowRadius = 16.0
    var entranceRaw = TextEffect.none.rawValue
    var exitRaw = TextEffect.none.rawValue
    var effectDur = 0.4

    init() {}

    init(_ c: OverlayClip) {
        fontName = c.textFontName; fontSize = c.textFontSize
        bold = c.textBold; italic = c.textItalic
        lineSpacing = c.textLineSpacing; charSpacing = c.textCharSpacing; wrapFrac = c.textWrapFrac
        color = c.textColor; fill = c.textFill; alignRaw = c.textAlignRaw
        outlineColor = c.textOutlineColor; outlineFill = c.textOutlineFill; outlineWidth = c.textOutlineWidth
        backgroundColor = c.textBackgroundColor; backgroundFill = c.textBackgroundFill
        shadowColor = c.textShadowColor; shadowFill = c.textShadowFill; shadowRadius = c.textShadowRadius
        shadowDX = c.textShadowDX; shadowDY = c.textShadowDY
        glowColor = c.textGlowColor; glowFill = c.textGlowFill; glowRadius = c.textGlowRadius
        entranceRaw = c.textEntranceRaw; exitRaw = c.textExitRaw; effectDur = c.textEffectDur
    }

    func apply(to c: inout OverlayClip) {
        c.textFontName = fontName; c.textFontSize = fontSize
        c.textBold = bold; c.textItalic = italic
        c.textLineSpacing = lineSpacing; c.textCharSpacing = charSpacing; c.textWrapFrac = wrapFrac
        c.textColor = fill.color; c.textFill = fill; c.textAlignRaw = alignRaw
        c.textOutlineColor = outlineFill.color; c.textOutlineFill = outlineFill; c.textOutlineWidth = outlineWidth
        c.textBackgroundColor = backgroundFill.color; c.textBackgroundFill = backgroundFill
        c.textShadowColor = shadowFill.color; c.textShadowFill = shadowFill; c.textShadowRadius = shadowRadius
        c.textShadowDX = shadowDX; c.textShadowDY = shadowDY
        c.textGlowColor = glowFill.color; c.textGlowFill = glowFill; c.textGlowRadius = glowRadius
        c.textEntranceRaw = entranceRaw; c.textExitRaw = exitRaw; c.textEffectDur = effectDur
    }
}

struct NamedTextStyle: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var style: TextLayerStyle
}

/// Kho preset KIỂU lớp chữ do người dùng lưu — dùng chung mọi project (UserDefaults JSON).
@MainActor
final class TextLayerPresetStore: ObservableObject {
    static let shared = TextLayerPresetStore()
    @Published private(set) var presets: [NamedTextStyle] = []
    private let key = "app.textlayer.presets.v5"   // v5: line/char spacing + wrap

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([NamedTextStyle].self, from: data) {
            presets = arr
        }
    }

    func add(name: String, style: TextLayerStyle) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = clean.isEmpty ? "Kiểu \(presets.count + 1)" : clean
        presets.removeAll { $0.name == finalName }
        presets.append(NamedTextStyle(name: finalName, style: style))
        persist()
    }

    func delete(_ id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = clean
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
