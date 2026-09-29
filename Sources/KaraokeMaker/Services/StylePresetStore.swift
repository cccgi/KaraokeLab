import AppKit
import Combine
import Foundation

/// 1 preset chữ do NGƯỜI DÙNG lưu — chụp nguyên `KaraokeStyle` câu chính + câu nhắc.
struct UserStylePreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var main: KaraokeStyle
    var next: KaraokeStyle
    var createdAt: Date = Date()
}

/// Kho preset chữ: preset DỰNG SẴN (`StylePreset.all`, luôn có trong code) + preset
/// của người dùng (lưu ra JSON, dùng chung mọi project). Có thể "ẩn" bớt preset dựng
/// sẵn và "Khôi phục mặc định" để hiện lại hết.
@MainActor
final class StylePresetStore: ObservableObject {
    @Published private(set) var user: [UserStylePreset] = []
    @Published private(set) var hiddenBuiltins: Set<String> = []

    private struct Disk: Codable {
        var v: Int = 0                       // 2 = đã dọn preset cũ (2026-09-09)
        var user: [UserStylePreset] = []
        var hiddenBuiltins: [String] = []

        enum CodingKeys: String, CodingKey { case v, user, hiddenBuiltins }
        init(v: Int, user: [UserStylePreset], hiddenBuiltins: [String]) {
            self.v = v; self.user = user; self.hiddenBuiltins = hiddenBuiltins
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = (try? c.decode(Int.self, forKey: .v)) ?? 0
            user = (try? c.decode([UserStylePreset].self, forKey: .user)) ?? []
            hiddenBuiltins = (try? c.decode([String].self, forKey: .hiddenBuiltins)) ?? []
        }
    }
    private static let currentVersion = 2

    private var fileURL: URL {
        ProjectLibrary.rootURL.appendingPathComponent(".style-presets.json")
    }

    init() { load() }

    /// Preset dựng sẵn còn hiển thị (chưa bị ẩn).
    var builtins: [StylePreset] {
        StylePreset.all.filter { !hiddenBuiltins.contains($0.name) }
    }
    var canRestoreDefaults: Bool { !hiddenBuiltins.isEmpty }

    // MARK: - Sửa

    func addCurrent(name: String, main: KaraokeStyle, next: KaraokeStyle) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = clean.isEmpty ? "Kiểu của tôi \(user.count + 1)" : clean
        user.append(UserStylePreset(name: finalName, main: main, next: next))
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = user.firstIndex(where: { $0.id == id }) else { return }
        user[i].name = clean
        save()
    }

    func deleteUser(_ id: UUID) {
        user.removeAll { $0.id == id }
        save()
    }

    /// Ẩn 1 preset dựng sẵn khỏi danh sách (khôi phục được bằng `restoreDefaults`).
    func hideBuiltin(_ name: String) {
        hiddenBuiltins.insert(name)
        save()
    }

    /// Hiện lại TẤT CẢ preset dựng sẵn.
    func restoreDefaults() {
        hiddenBuiltins.removeAll()
        save()
    }

    // MARK: - Đĩa

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let d = try? JSONDecoder().decode(Disk.self, from: data) else { return }
        if d.v < Self.currentVersion {
            // 1 lần: bỏ hết preset của người dùng cũ + mọi "ẩn" cũ — chỉ còn 2 built-in mới.
            user = []
            hiddenBuiltins = []
            save()
            return
        }
        let builtinNames = Set(StylePreset.all.map { $0.name.lowercased() })
        user = d.user.filter { !builtinNames.contains($0.name.lowercased()) }   // đừng để trùng tên built-in
        hiddenBuiltins = Set(d.hiddenBuiltins).intersection(builtinNames)
    }

    private func save() {
        ProjectLibrary.ensureFolders()
        let d = Disk(v: Self.currentVersion, user: user, hiddenBuiltins: Array(hiddenBuiltins))
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Hộp thoại nhập 1 dòng chữ (AppKit — ổn định hơn TextField trong `.alert` trên macOS 13).
enum TextPrompt {
    @MainActor
    static func run(title: String, message: String = "", defaultValue: String = "",
                    okTitle: String = "Lưu") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if !message.isEmpty { alert.informativeText = message }
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: "Huỷ")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        field.placeholderString = "Tên preset"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn
            ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }
}
