import Foundation

/// (U7) 1 project đang mở trong 1 TAB — mỗi tab có `ProjectStore` RIÊNG (project/undo riêng,
/// sửa tab này không ảnh hưởng tab kia).
@MainActor
final class ProjectTab: ObservableObject, Identifiable {
    let id = UUID()
    let store = ProjectStore()
}

/// (U7) Quản lý các tab project đang mở cùng lúc — thay cho 1 `ProjectStore` singleton dùng
/// chung toàn app. CHỈ 1 tab "sống" (đang phát nhạc) tại 1 thời điểm — đổi tab thì `ContentView`
/// tự nạp lại audio đúng project đó (xem `.onAppear` trong `ContentView`), không phát chồng
/// nhiều bài cùng lúc.
@MainActor
final class ProjectTabs: ObservableObject {
    @Published private(set) var items: [ProjectTab]
    @Published var activeID: UUID

    init() {
        let first = ProjectTab()
        items = [first]
        activeID = first.id
    }

    var active: ProjectTab { items.first { $0.id == activeID } ?? items[0] }

    /// Mở 1 tab MỚI (không đóng tab đang có) rồi chuyển sang nó — tab mới RỖNG, để màn Home
    /// (trong tab đó) cho người dùng chọn "Tạo project" hay "Mở project khác…".
    func openNewTab() {
        let tab = ProjectTab()
        items.append(tab)
        activeID = tab.id
    }

    /// Đóng 1 tab. `confirmSave` hỏi lưu nếu còn thay đổi chưa lưu — trả `false` nghĩa là
    /// người dùng huỷ, KHÔNG đóng tab.
    @discardableResult
    func closeTab(_ id: UUID, confirmSave: (ProjectStore) -> Bool) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return true }
        guard confirmSave(items[i].store) else { return false }
        items.remove(at: i)
        if items.isEmpty { items.append(ProjectTab()) }
        if activeID == id { activeID = items[max(0, min(i, items.count - 1))].id }
        return true
    }

    /// Tab nào còn thay đổi chưa lưu — dùng lúc thoát app (hỏi lưu từng tab một).
    var unsavedTabs: [ProjectTab] { items.filter { $0.store.hasUnsavedChanges } }
}
