import Combine
import Foundation

/// 1 preset màu do người dùng lưu — chụp nguyên `ColorAdjust`.
struct ColorPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var adjust: ColorAdjust
    var createdAt: Date = Date()
}

/// Kho preset màu (§75) — JSON dùng chung mọi project.
@MainActor
final class ColorPresetStore: ObservableObject {
    @Published private(set) var presets: [ColorPreset] = []

    private var fileURL: URL {
        ProjectLibrary.rootURL.appendingPathComponent(".color-presets.json")
    }

    init() { load() }

    func add(name: String, adjust: ColorAdjust) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = clean.isEmpty ? "Màu \(presets.count + 1)" : clean
        presets.append(ColorPreset(name: final, adjust: adjust))
        save()
    }
    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = clean; save()
    }
    func delete(_ id: UUID) { presets.removeAll { $0.id == id }; save() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let arr = try? JSONDecoder().decode([ColorPreset].self, from: data) else { return }
        presets = arr
    }
    private func save() {
        ProjectLibrary.ensureFolders()
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
