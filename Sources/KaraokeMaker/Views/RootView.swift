import SwiftUI
import AppKit

/// (U1+U7) Gốc điều hướng: Home (thư viện project) ⇄ màn làm việc (`ContentView`), nhiều
/// project mở cùng lúc dạng TAB. KHÔNG đổi gì bên trong `ContentView` — chỉ đứng TRƯỚC nó.
struct RootView: View {
    @EnvironmentObject var tabs: ProjectTabs

    /// Tab đang active có đang ở Home hay đã vào màn làm việc — theo TỪNG tab (không phải
    /// 1 cờ toàn app), để tab A đang làm việc, tab B mới mở vẫn ở Home riêng của nó.
    @State private var editingTabIDs: Set<UUID> = []

    private var activeTab: ProjectTab { tabs.active }
    private var inEditor: Bool { editingTabIDs.contains(activeTab.id) }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.items.count > 1 {
                tabBar
                Divider().overlay(Theme.stroke)
            }
            Group {
                if inEditor {
                    // Thanh trên GỘP vào ContentView (1 thanh duy nhất kiểu CapCut) —
                    // ContentView tự vẽ nút "← Thư viện" + "Project mới" qua callback.
                    ContentView(
                        onExitToLibrary: goHome,
                        onOpenNewTab: { tabs.openNewTab() },
                        trialDays: DemoTrial.daysRemaining
                    )
                    .environmentObject(activeTab.store)
                    .id(activeTab.id)   // (U7) danh tính RIÊNG mỗi tab — @State không lẫn nhau
                } else {
                    HomeView(onCreate: createAndOpen, onOpen: open)
                        .environmentObject(activeTab.store)
                        .id(activeTab.id)
                }
            }
        }
        #if KM_GUITEST
        .onReceive(NotificationCenter.default.publisher(for: Self.guiTestOpenProject)) { n in
            if let url = n.object as? URL { open(url) }
        }
        #endif
    }

    // MARK: - Móc kiểm thử GUI

    /// CHỈ dùng bởi bộ kiểm thử GUI (`KM_GUITEST_DIR`): sự kiện chuột tổng hợp không kích được `onTapGesture` của SwiftUI trên macOS này,
    /// nên bộ kiểm thử gọi ĐÚNG hàm mà thẻ project ở Home gọi (`open(_:)`). Không ai khác phát thông báo này.
    #if KM_GUITEST
    static let guiTestOpenProject = Notification.Name("KMGUITest.openProject")
    #endif

    // MARK: - Thanh tab (U7)

    private var tabBar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs.items) { tab in
                        tabChip(tab)
                    }
                }
            }
            Button { tabs.openNewTab() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 8)
            .help(L("Mở project khác trong tab mới"))
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.bg)
    }

    private func tabChip(_ tab: ProjectTab) -> some View {
        let isActive = tab.id == tabs.activeID
        return HStack(spacing: 6) {
            Text(tab.store.project.name)
                .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            if tab.store.hasUnsavedChanges {
                Circle().fill(Color.orange).frame(width: 5, height: 5)
            }
            Button { closeTab(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .opacity(0.6)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(isActive ? Theme.panel : Color.clear)
        .foregroundColor(.white.opacity(isActive ? 0.95 : 0.55))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { tabs.activeID = tab.id }
    }

    private func closeTab(_ id: UUID) {
        guard let tab = tabs.items.first(where: { $0.id == id }) else { return }
        let ok = tabs.closeTab(id) { store in Self.confirmSave(store) }
        if ok { editingTabIDs.remove(tab.id) }
    }

    private func createAndOpen() {
        // KHÔNG ghi file ngay — chỉ đánh dấu "mới". File chỉ được tạo khi người dùng
        // thực sự lưu / rời màn có thay đổi → hết rác "Untitled 4KB" ở Home.
        activeTab.store.newProject()
        activeTab.store.prepareNewInLibrary()
        editingTabIDs.insert(activeTab.id)
    }

    private func open(_ url: URL) {
        activeTab.store.open(from: url)
        editingTabIDs.insert(activeTab.id)
    }

    /// Về thư viện (CHỈ tab đang xem) — hỏi lưu trước nếu còn thay đổi chưa lưu.
    private func goHome() {
        let store = activeTab.store
        guard store.hasUnsavedChanges else {
            editingTabIDs.remove(activeTab.id); return
        }
        if Self.confirmSave(store) { editingTabIDs.remove(activeTab.id) }
    }

    /// Hỏi lưu 1 project (kiểu hộp thoại lúc thoát app) — trả `true` = đã xử lý xong (lưu
    /// hoặc cố ý không lưu), `false` = người dùng bấm Huỷ, GIỮ NGUYÊN không đóng/rời.
    private static func confirmSave(_ store: ProjectStore) -> Bool {
        guard store.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = L("Lưu thay đổi trước khi đóng?")
        alert.informativeText = String(format: L("Dự án “%@” có thay đổi chưa được lưu."), store.project.name)
        alert.addButton(withTitle: L("Lưu"))
        alert.addButton(withTitle: L("Không lưu"))
        alert.addButton(withTitle: L("Huỷ"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if store.save() == false,
               let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
                store.save(to: url)
            }
            return !store.hasUnsavedChanges
        case .alertThirdButtonReturn:
            return false
        default:
            return true
        }
    }
}
