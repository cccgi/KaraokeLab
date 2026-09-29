import Foundation
import Combine
import SwiftUI

/// Giữ project đang mở trong bộ nhớ và lo việc LƯU / MỞ file `.kbproj`.
///
/// Toàn app dùng chung một instance (đưa vào môi trường SwiftUI).
@MainActor
final class ProjectStore: ObservableObject {

    /// Đuôi file project.
    static let fileExtension = "kbproj"

    /// Dự án đang chỉnh sửa.
    @Published var project: KaraokeProject

    /// Đường dẫn file đang gắn với project (nil nếu chưa từng lưu).
    @Published private(set) var fileURL: URL?

    /// Danh tính PHIÊN của project đang mở — chỉ trong bộ nhớ (KHÔNG lưu file): đổi mỗi lần tạo mới / mở project khác
    /// trong cùng store. "Lưu thành" thì KHÔNG đổi (vẫn cùng project). Tính năng chạy nền (Tự động lấy lời) dùng nó để
    /// bảo đảm kết quả của project A không bao giờ lọt vào project B.
    @Published private(set) var projectSessionID = UUID()

    /// Có thay đổi chưa lưu hay không.
    @Published var hasUnsavedChanges: Bool = false

    /// Thông báo lỗi gần nhất để hiển thị cho người dùng.
    @Published var lastError: String?

    /// Vị trí vạch đỏ gần nhất (giây) — để thumbnail chụp đúng khung user đang xem.
    /// KHÔNG `@Published` (đọc lúc lưu thôi, không kéo UI dựng lại).
    var lastPreviewTime: TimeInterval = 0

    /// UndoManager riêng của app (đăng ký & gọi undo/redo đều dùng cái này).
    let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 200
        return manager
    }()

    init() {
        self.project = KaraokeProject()
    }

    // MARK: - Thao tác

    /// Dự án MỚI chưa lưu — `save()` sẽ tự đặt file trong thư mục thư viện
    /// (chỉ khi người dùng thực sự lưu / rời màn có thay đổi). Tránh rác "Untitled".
    private(set) var isUnsavedNew = false

    /// Tạo dự án mới, rỗng.
    func newProject() {
        project = KaraokeProject()
        projectSessionID = UUID()
        fileURL = nil
        isUnsavedNew = false
        hasUnsavedChanges = false
        lastError = nil
        undoManager.removeAllActions()
    }

    /// Đánh dấu: đây là dự án mới, khi lưu lần đầu thì tự tạo file trong thư viện.
    func prepareNewInLibrary() { isUnsavedNew = true }

    /// Đánh dấu project vừa bị thay đổi (gọi sau mỗi lần sửa dữ liệu).
    func markDirty() {
        hasUnsavedChanges = true
    }

    /// Thực hiện một thay đổi CÓ THỂ HOÀN TÁC (Cmd+Z).
    /// `block` cứ mutate `project` bình thường; store lo việc chụp ảnh trước/sau
    /// và đăng ký undo/redo.
    func perform(_ actionName: String, _ block: () -> Void) {
        // (2026-09-14) Bọc `animation: nil` — nếu không, MỖI thao tác (gõ chữ, bấm nút,
        // kéo thanh trượt…) đổi `project` (1 khối `@Published` DUY NHẤT, cả app theo dõi)
        // bị SwiftUI coi là animation, kéo CẢ CỬA SỔ vào chế độ đồng bộ vsync liên tục
        // (giống hệt lý do sửa `PlaybackController.clock.seconds` — xem đó) → đây mới là
        // chỗ ăn tần suất LỚN NHẤT vì MỌI mutation project đều qua đây.
        withTransaction(Transaction(animation: nil)) {
            let snapshot = project
            block()
            commit(from: snapshot, name: actionName)
        }
    }

    /// Đăng ký undo cho thay đổi đã xảy ra so với `snapshot` (dùng khi giá trị
    /// thay đổi liên tục — ví dụ kéo slider — rồi mới "chốt" một lần).
    func commit(from snapshot: KaraokeProject, name: String) {
        guard project != snapshot else { return }
        hasUnsavedChanges = true
        registerUndoStep(restoring: snapshot, name: name)
    }

    // Gộp nhiều thay đổi liên tục (kéo slider, chọn màu) thành 1 bước hoàn tác.
    private var debounceSnapshot: KaraokeProject?
    private var debounceWork: DispatchWorkItem?

    func edit(_ name: String, apply: () -> Void) {
        withTransaction(Transaction(animation: nil)) {
            if debounceSnapshot == nil { debounceSnapshot = project }
            apply()
            hasUnsavedChanges = true
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let snapshot = self.debounceSnapshot else { return }
            self.debounceSnapshot = nil
            withTransaction(Transaction(animation: nil)) {
                self.commit(from: snapshot, name: name)
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func registerUndoStep(restoring target: KaraokeProject, name: String) {
        let redoTarget = project
        undoManager.registerUndo(withTarget: self) { store in
            store.registerUndoStep(restoring: redoTarget, name: name)
            store.project = target
            store.hasUnsavedChanges = true
        }
        undoManager.setActionName(name)
    }

    /// Mở project từ file. `.kbproj` giờ là 1 FILE ZIP THẬT (mang theo media, xem
    /// `ProjectPackage`) — giải nén ra thư mục staging riêng rồi đọc `project.json` trong đó.
    /// File JSON đơn (định dạng cũ) vẫn mở thẳng như trước. Thư mục trần (bản "gói" tạm dùng
    /// sáng 2026-09-13, đã bỏ trong ngày) cũng nhận ra để không mất project đã lỡ lưu bằng bản đó.
    func open(from url: URL) {
        do {
            var localDir: URL?
            let jsonSourceURL: URL
            if ProjectPackage.isZipPackage(url) {
                guard let dir = ProjectPackage.extract(url) else {
                    lastError = L("Không mở được file:") + " " + L("Giải nén thất bại.")
                    return
                }
                localDir = dir
                jsonSourceURL = ProjectPackage.jsonURL(inLocalDir: dir)
            } else if ProjectPackage.isLooseDirectory(url) {
                localDir = url
                jsonSourceURL = ProjectPackage.jsonURL(inLocalDir: url)
            } else {
                jsonSourceURL = url
            }
            let data = try Data(contentsOf: jsonSourceURL)
            var decoded = try Self.makeDecoder().decode(KaraokeProject.self, from: data)
            if let localDir { decoded.rehomeMediaIfNeeded(inPackage: localDir) }
            project = decoded
            projectSessionID = UUID()
            fileURL = url
            isUnsavedNew = false
            hasUnsavedChanges = false
            lastError = nil
            undoManager.removeAllActions()
            RecentProjects.note(url)
            // (2026-09-15) Mở project ở máy khác nhưng thiếu media — trước đây im lặng, chữ/nền
            // để trống không rõ vì sao. Báo NGAY để người dùng biết cần chọn lại từ đây.
            let missing = decoded.missingMediaLabels()
            if !missing.isEmpty {
                lastError = L("Project mở được nhưng thiếu:") + " " + missing.joined(separator: ", ")
                    + ". " + L("Có thể do lưu ở máy này lần trước khi các file đó chưa nằm sẵn trong project — chọn lại giúp mình.")
            }
        } catch {
            lastError = L("Không mở được file:") + " \(error.localizedDescription)"
        }
    }

    /// Lưu vào đúng file đang gắn; dự án mới thì tự tạo file trong thư viện.
    /// Trả `false` khi chưa có chỗ lưu (UI mở hộp thoại "Lưu thành…").
    @discardableResult
    func save() -> Bool {
        if let url = fileURL { write(to: url); return true }
        if isUnsavedNew {
            let url = ProjectLibrary.newProjectURL(suggestedName: project.name)
            write(to: url)
            isUnsavedNew = false
            return true
        }
        return false
    }

    /// Lưu ra một file cụ thể (dùng cho "Lưu thành…").
    func save(to url: URL) {
        write(to: url)
    }

    // MARK: - Riêng tư

    private func write(to url: URL) {
        do {
            var snapshot = project
            snapshot.modifiedAt = Date()

            // Luôn lưu dạng ZIP 1 FILE (mang theo media) từ nay — dựng trong 1 thư mục staging
            // riêng rồi NÉN LẠI thành đúng 1 file `.kbproj`, không để lộ ra thư mục.
            let staging = ProjectPackage.staging(for: url)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let missing = snapshot.materializeMedia(intoPackage: staging)

            let data = try Self.makeEncoder().encode(snapshot)
            try data.write(to: ProjectPackage.jsonURL(inLocalDir: staging), options: .atomic)

            guard ProjectPackage.compress(staging: staging, to: url) else {
                lastError = L("Không lưu được file:") + " " + L("Nén file thất bại.")
                return
            }

            project = snapshot
            fileURL = url
            isUnsavedNew = false
            hasUnsavedChanges = false
            // (2026-09-15) Trước đây bỏ qua ÊM nếu 1 món media không copy được vào project (nguồn
            // đã bị xoá/di chuyển) — mang file này sang máy khác thì món đó biến mất mà không ai
            // biết trước. Báo NGAY lúc lưu thay vì để user phát hiện ở máy kia.
            lastError = missing.isEmpty ? nil :
                L("Đã lưu, nhưng KHÔNG mang theo được:") + " " + missing.joined(separator: ", ")
                    + ". " + L("Mở file này ở máy khác sẽ thiếu — kiểm tra lại đường dẫn gốc rồi lưu lại.")
            RecentProjects.note(url)
            // (U2) Ảnh xem trước cho thư viện — chạy NỀN, không chặn lưu; lỗi bỏ qua êm.
            let forThumb = snapshot
            let atTime = lastPreviewTime
            DispatchQueue.global(qos: .utility).async {
                ThumbnailRenderer.generate(for: forThumb, projectURL: url, atTime: atTime)
            }
        } catch {
            lastError = L("Không lưu được file:") + " \(error.localizedDescription)"
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
