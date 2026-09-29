import Foundation

/// Ai hát câu này — hiện icon phía trên câu lúc phát / xuất video.
enum SingerRole: String, Codable, CaseIterable, Identifiable {
    case male, female, duet
    var id: String { rawValue }

    var label: String {
        switch self {
        case .male:   return L("Nam")
        case .female: return L("Nữ")
        case .duet:   return L("Song ca")
        }
    }

    /// SF Symbol phân biệt vai (kèm màu).
    var symbolName: String {
        switch self {
        case .male:   return "music.mic"
        case .female: return "mic.fill"
        case .duet:   return "person.2.fill"
        }
    }

    /// Màu mặc định cho mỗi vai (user chốt).
    static func defaultColor(_ role: SingerRole) -> RGBAColor {
        switch role {
        case .male:   return RGBAColor(r: 0x16 / 255, g: 0x26 / 255, b: 0xFA / 255)   // #1626FA
        case .female: return RGBAColor(r: 0xEF / 255, g: 0x0B / 255, b: 0x0B / 255)   // #EF0B0B
        case .duet:   return RGBAColor(r: 0xEF / 255, g: 0x0B / 255, b: 0x9C / 255)   // #EF0B9C
        }
    }

    static var defaultColors: [String: RGBAColor] {
        [male.rawValue: defaultColor(.male),
         female.rawValue: defaultColor(.female),
         duet.rawValue: defaultColor(.duet)]
    }
}
