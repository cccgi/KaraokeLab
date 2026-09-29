import SwiftUI
import AppKit

/// Hệ đa ngôn ngữ toàn app.
///
/// Nguồn chữ trong code là TIẾNG VIỆT — dùng chính chuỗi tiếng Việt làm "khoá".
/// `L("Xuất")` → tra bảng dịch theo ngôn ngữ đang chạy:
///   • `vi`  → trả nguyên khoá (đã là tiếng Việt).
///   • `en`  → "Export".
///   • ngôn ngữ chưa dịch xong → lùi về `en`.
///
/// Mặc định lần đầu mở app = **English**. Người dùng đổi trong Cài đặt (⌘,) hoặc nút
/// hình quả địa cầu ở màn hình Home. Đổi xong phải **mở lại app** mới áp dụng
/// (chữ được tra 1 lần lúc dựng giao diện, theo `launchLang`).
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case vi, en, zh, ko, ja, es, fr, pt

    var id: String { rawValue }

    /// Tên hiển thị trong danh sách — viết bằng CHÍNH ngôn ngữ đó.
    var nativeName: String {
        switch self {
        case .vi: return "Tiếng Việt"
        case .en: return "English"
        case .zh: return "中文"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .es: return "Español"
        case .fr: return "Français"
        case .pt: return "Português"
        }
    }

    var flag: String {
        switch self {
        case .vi: return "🇻🇳"
        case .en: return "🇬🇧"
        case .zh: return "🇨🇳"
        case .ko: return "🇰🇷"
        case .ja: return "🇯🇵"
        case .es: return "🇪🇸"
        case .fr: return "🇫🇷"
        case .pt: return "🇵🇹"
        }
    }

    /// Đã có bảng dịch đầy đủ. Các thứ tiếng còn lại tạm hiển thị bằng English.
    var fullyTranslated: Bool { self == .vi || self == .en }

    /// Thứ tự trong ô chọn — **Tiếng Việt luôn đứng đầu**, rồi English, rồi phần còn lại.
    static let pickerOrder: [AppLanguage] = [.vi, .en, .zh, .ko, .ja, .es, .fr, .pt]
}

private let kLangDefaultsKey = "app.language"

/// Tra chữ — KHÔNG phụ thuộc main actor (gọi được từ AppKit / nền).
enum LocEngine {
    /// Ngôn ngữ CHỐT lúc app khởi động — mọi chữ trên giao diện tra theo cái này.
    static let launchLang: AppLanguage = {
        UserDefaults.standard.string(forKey: kLangDefaultsKey)
            .flatMap(AppLanguage.init(rawValue:)) ?? .en          // MẶC ĐỊNH = English
    }()

    /// Tra 1 chuỗi. Khoá = chuỗi tiếng Việt gốc trong code.
    static func t(_ vi: String) -> String {
        if launchLang == .vi { return vi }
        return LocTables.all[launchLang]?[vi] ?? LocTables.all[.en]?[vi] ?? vi
    }
}

/// Cách gọi gọn trong code: `L("Xuất")`.
func L(_ vi: String) -> String { LocEngine.t(vi) }

extension String {
    /// `"Xuất".loc` → chuỗi đã dịch theo ngôn ngữ app.
    var loc: String { LocEngine.t(self) }
}

/// Trạng thái ô chọn ngôn ngữ (chỉ phục vụ UI Cài đặt / Home).
@MainActor
final class Loc: ObservableObject {
    static let shared = Loc()

    @Published private(set) var lang: AppLanguage

    private init() { lang = LocEngine.launchLang }

    /// Đổi ngôn ngữ (lưu lại). Áp dụng sau khi mở lại app.
    func select(_ l: AppLanguage) {
        guard l != lang else { return }
        UserDefaults.standard.set(l.rawValue, forKey: kLangDefaultsKey)
        lang = l
    }

    /// Cần mở lại app để lựa chọn mới có hiệu lực?
    var needsRestart: Bool { lang != LocEngine.launchLang }

    /// Mở lại app ngay (nút "Mở lại ngay").
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Ô chọn ngôn ngữ (dùng ở Home + Cài đặt)

/// Menu hình quả địa cầu — bấm ra danh sách ngôn ngữ, Tiếng Việt đứng đầu.
/// Khi đổi khác ngôn ngữ đang chạy → hiện thông báo "mở lại app".
struct LanguagePicker: View {
    @ObservedObject private var loc = Loc.shared
    var compact = true
    @State private var askRestart = false

    var body: some View {
        Menu {
            ForEach(AppLanguage.pickerOrder) { l in
                Button {
                    loc.select(l)
                    askRestart = loc.needsRestart
                } label: {
                    HStack {
                        Text("\(l.flag)  \(l.nativeName)")
                        if l == loc.lang { Spacer(); Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            if compact {
                Label("\(loc.lang.flag) \(loc.lang.nativeName)", systemImage: "globe")
            } else {
                Text("\(loc.lang.flag)  \(loc.lang.nativeName)")
            }
        }
        .help(L("Ngôn ngữ"))
        .alert(L("Đổi ngôn ngữ"), isPresented: $askRestart) {
            Button(L("Mở lại ngay")) { Loc.relaunch() }
            Button(L("Để sau"), role: .cancel) { }
        } message: {
            Text(L("Mở lại app để áp dụng ngôn ngữ mới."))
        }
    }
}

// MARK: - Cửa sổ Cài đặt (⌘,)

struct SettingsView: View {
    @ObservedObject private var loc = Loc.shared
    @State private var askRestart = false

    var body: some View {
        Form {
            Section {
                Picker(L("Ngôn ngữ"), selection: Binding(
                    get: { loc.lang },
                    set: { loc.select($0); askRestart = loc.needsRestart }
                )) {
                    ForEach(AppLanguage.pickerOrder) { l in
                        Text("\(l.flag)  \(l.nativeName)").tag(l)
                    }
                }
                if loc.needsRestart {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise.circle")
                        Text(L("Mở lại app để áp dụng ngôn ngữ mới."))
                        Button(L("Mở lại ngay")) { Loc.relaunch() }
                            .controlSize(.small)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Ngôn ngữ"))
            } footer: {
                Text(L("Tiếng Việt và English đã dịch đầy đủ. Các ngôn ngữ khác tạm hiển thị bằng English."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
        .alert(L("Đổi ngôn ngữ"), isPresented: $askRestart) {
            Button(L("Mở lại ngay")) { Loc.relaunch() }
            Button(L("Để sau"), role: .cancel) { }
        } message: {
            Text(L("Mở lại app để áp dụng ngôn ngữ mới."))
        }
    }
}
