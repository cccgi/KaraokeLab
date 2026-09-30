import SwiftUI
import AppKit

/// Điểm khởi động — chặn chế độ kiểm thử `--align-test` trước khi bật giao diện.
@main
enum KMEntry {
    static func main() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--autolyrics-test") {          // kiểm thử "Tự động lấy lời" (không giao diện)
            AutoLyricsTestCLI.main(Array(a[(i + 1)...]))
        }
        if let i = a.firstIndex(of: "--align-test"), a.count > i + 2 {
            AlignTestCLI.run(vocal: a[i + 1], lyricsFile: a[i + 2], mix: a.count > i + 3 ? a[i + 3] : nil)
            exit(0)
        }
        if let i = a.firstIndex(of: "--viz-test"), a.count > i + 1 {
            AlignTestCLI.vizProbe(audio: a[i + 1])
            exit(0)
        }
        if let i = a.firstIndex(of: "--feat-test"), a.count > i + 1 {
            AlignTestCLI.featProbe(audio: a[i + 1], vocalCheck: a.count > i + 2 ? a[i + 2] : nil)
            exit(0)
        }
        if let i = a.firstIndex(of: "--m5-test"), a.count > i + 3 {
            AlignTestCLI.m5Test(vocal: a[i + 1], mix: a[i + 2], lyricsFile: a[i + 3])
            exit(0)
        }
        if let i = a.firstIndex(of: "--regress-test"), a.count > i + 1 {
            AlignTestCLI.regressTest(manifestPath: a[i + 1])
            exit(0)
        }
        if let i = a.firstIndex(of: "--separate"), a.count > i + 2 {
            AlignTestCLI.separate(source: a[i + 1], vocalOut: a[i + 2], hq: a.contains("--hq"))
            exit(0)
        }
        KaraokeMakerApp.main()
    }
}

/// Điểm khởi động ứng dụng.
struct KaraokeMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// (U7) Nhiều project mở cùng lúc dạng tab — thay cho 1 `ProjectStore` singleton.
    @StateObject private var tabs = ProjectTabs()
    @StateObject private var playback = PlaybackController()
    @StateObject private var stylePresets = StylePresetStore()
    @StateObject private var colorPresets = ColorPresetStore()
    /// M-B — editor của tab đang mở phát ra qua `focusedSceneValue`. Menu bar đọc lại.
    @FocusedValue(\.editorCommands) private var editor

    var body: some Scene {
        WindowGroup("KaraokeMaker") {
            // Bản dùng thử (`--demo`) hết hạn → chặn hẳn, không vào màn làm việc.
            // Bản thường (không cờ DEMO_BUILD) — `DemoTrial.isExpired` luôn `false`.
            if DemoTrial.isExpired {
                TrialExpiredView()
            } else {
                RootView()
                    .environmentObject(tabs)
                    .environmentObject(playback)
                    .environmentObject(playback.clock)
                    .environmentObject(stylePresets)
                    .environmentObject(colorPresets)
                    .onAppear { appDelegate.tabs = tabs }   // để hỏi lưu lúc thoát
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1520, height: 940)
        .commands {
            // Menu bar "File" — gộp mọi thao tác Tệp vào đây (bỏ menu "Tệp" trên thanh trên).
            CommandGroup(replacing: .newItem) {
                Button(L("Dự án mới")) { editor?.run(.newProject) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(editor == nil)
                Button(L("Mở…")) { editor?.run(.openProject) }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(editor == nil)
                Button(L("Mở project khác (tab mới)")) { editor?.run(.openNewTab) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(editor == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Lưu")) {
                    let store = tabs.active.store
                    if store.save() == false,
                       let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
                        store.save(to: url)
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                Button(L("Lưu thành…")) {
                    let store = tabs.active.store
                    if let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
                        store.save(to: url)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(L("Hoàn tác")) { tabs.active.store.undoManager.undo() }
                    .disabled(!tabs.active.store.undoManager.canUndo)
                Button(L("Làm lại")) { tabs.active.store.undoManager.redo() }
                    .disabled(!tabs.active.store.undoManager.canRedo)
            }

            // M-B — menu bar, mọi mục gọi CHUNG `EditorCommand` của tab đang mở.
            // Phím Space / ← / → / [ / ] / Delete do `KeyDownMonitor` xử lý (né ô nhập chữ)
            // nên KHÔNG gắn `.keyboardShortcut` ở đây để tránh xung đột / chạy 2 lần.
            CommandMenu(L("Phát")) {
                cmdButton("Phát / Dừng  (Space)", .playPause)
                Divider()
                cmdButton("Lùi 1 giây", .seekBy(-1))
                cmdButton("Tới 1 giây", .seekBy(1))
                cmdButton("Lùi 5 giây", .seekBy(-5))
                cmdButton("Tới 5 giây", .seekBy(5))
            }
            CommandMenu(L("Timeline")) {
                Button(L("Tách tại vạch đỏ")) { editor?.run(.splitAtPlayhead) }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(!(editor?.canRun(.splitAtPlayhead) ?? false))
                cmdButton("Nhân đôi mục đang chọn", .duplicateSelection)
                cmdButton("Sao chép clip", .copySelection)
                cmdButton("Dán clip vào vạch đỏ", .pasteClip)
                cmdButton("Dán thuộc tính (màu/biến hình/fade)", .pasteClipStyle)
                cmdButton("Xoá mục đang chọn  (⌫)", .deleteSelection)
                Divider()
                cmdButton("Dời trái 0,1 giây  (,)", .nudgeSelection(-0.1))
                cmdButton("Dời phải 0,1 giây  (.)", .nudgeSelection(0.1))
            }
            CommandMenu(L("Lời")) {
                cmdButton("Dòng trước  ([)", .prevLine)
                cmdButton("Dòng sau  (])", .nextLine)
                Divider()
                cmdButton("Đặt điểm bắt đầu tại vạch đỏ", .setLineStartAtPlayhead)
                cmdButton("Đặt điểm kết thúc tại vạch đỏ", .setLineEndAtPlayhead)
                cmdButton("Xoá timing dòng đang chọn", .clearLineTiming)
            }
            CommandMenu(L("Xem")) {
                Button(L("Phóng to timeline")) { editor?.run(.zoomIn) }
                    .keyboardShortcut("=", modifiers: .command)
                    .disabled(editor == nil)
                Button(L("Thu nhỏ timeline")) { editor?.run(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(editor == nil)
                Button(L("Timeline vừa khung")) { editor?.run(.zoomToFit) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(editor == nil)
                Divider()
                Button(L("Ẩn / hiện lời")) { editor?.run(.toggleLyricsHidden) }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(editor == nil)
                Button(L("Tắt / bật tiếng nhạc")) { editor?.run(.toggleMusicMuted) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(editor == nil)
            }
        }

        Settings { SettingsView() }
    }

    /// Nút menu bar: gọi `EditorCommand`, tự mờ đi khi lệnh không dùng được.
    @ViewBuilder
    private func cmdButton(_ title: String, _ cmd: EditorCommand) -> some View {
        Button(L(title)) { editor?.run(cmd) }
            .disabled(!(editor?.canRun(cmd) ?? false))
    }
}

/// Bảo đảm app chạy như ứng dụng có cửa sổ bình thường (hiện trên Dock, có menu).
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if KM_GUITEST
    /// Tham chiếu tới delegate thật (SwiftUI bọc delegate nên `NSApp.delegate as? AppDelegate` không dùng được) — chỉ để bộ kiểm thử GUI đọc trạng thái.
    static weak var current: AppDelegate?
    #endif
    weak var tabs: ProjectTabs?
    private var fitObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if KM_GUITEST
        Self.current = self
        #endif
        NSApp.setActivationPolicy(.regular)
        #if KM_GUITEST
        // Bản kiểm thử tự động (Scripts/ui-check.sh) chạy NỀN: không giành bàn phím — nếu không, phím người dùng gõ ở app
        // khác rơi vào bản kiểm thử (đã thấy: tự mở bảng Xuất, số đo CPU sai).
        if GUITestDriver.dir == nil { NSApp.activate(ignoringOtherApps: true) }
        #else
        NSApp.activate(ignoringOtherApps: true)
        #endif
        PerfMonitor.shared.startIfEnabled()
        #if KM_GUITEST
        Task { @MainActor in GUITestDriver.startIfRequested() }   // CHỈ có trong bản dựng kiểm thử (-DKM_GUITEST); bản Release không chứa mã này
        #endif

        // Chờ đúng lúc cửa sổ chính hiện & thành key rồi bung FULL màn hình
        // (trừ menu bar + Dock) — làm mỗi lần mở app.
        fitObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let window = note.object as? NSWindow,
                  window.styleMask.contains(.titled),
                  window.contentView != nil else { return }
            self.fitMainWindow(window)
            if let obs = self.fitObserver {
                NotificationCenter.default.removeObserver(obs)
                self.fitObserver = nil
            }
        }
    }

    private func fitMainWindow(_ window: NSWindow) {
        // Khớp khung SwiftUI của editor (thiết kế lại 2026-09-29: min 1180 × 720) — trước đây 1360 × 780 ghi đè mất.
        window.minSize = NSSize(width: 1180, height: 720)
        // KHÔNG nhớ kích thước cũ — luôn mở bung hết cỡ.
        window.setFrameAutosaveName("")
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true, animate: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Thoát app (Cmd+Q hoặc đóng cửa sổ cuối): nếu còn thay đổi chưa lưu thì hỏi.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: self.confirmQuit())
        }
        return .terminateLater
    }

    /// (U7) Hỏi lưu TỪNG TAB còn thay đổi chưa lưu (không chỉ 1 project như trước).
    @MainActor
    private func confirmQuit() -> Bool {
        guard let tabs else { return true }
        for tab in tabs.unsavedTabs {
            let store = tab.store
            let alert = NSAlert()
            alert.messageText = L("Lưu thay đổi trước khi thoát?")
            alert.informativeText = String(format: L("Dự án “%@” có thay đổi chưa được lưu."), store.project.name)
            alert.addButton(withTitle: L("Lưu"))         // .alertFirstButtonReturn
            alert.addButton(withTitle: L("Không lưu"))   // .alertSecondButtonReturn
            alert.addButton(withTitle: L("Huỷ"))         // .alertThirdButtonReturn

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if store.save() == false {
                    guard let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) else {
                        return false   // huỷ hộp thoại lưu -> không thoát
                    }
                    store.save(to: url)
                }
                if store.hasUnsavedChanges { return false }
            case .alertThirdButtonReturn:
                return false           // Huỷ — dừng lại, không hỏi thêm tab nào nữa
            default:
                break                  // Không lưu tab này — qua tab kế
            }
        }
        return true
    }
}
