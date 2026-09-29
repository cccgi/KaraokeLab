import Foundation
import SwiftUI

/// M-A — Cái đang được chọn trong editor. NGUỒN ĐỌC DUY NHẤT.
///
/// Storage vẫn là `currentLineIndex` + `selectedOverlayID` trong `ContentView`
/// (không đổi để tránh regression); giá trị này được TÍNH ra từ chúng, và mọi nơi
/// (command / inspector / menu / context menu) đọc CHUNG qua đây.
enum EditorSelection: Equatable {
    case none
    case lyricLine(index: Int)
    case overlay(id: UUID)
}

/// M-A — Lệnh editor. Toolbar, phím tắt, context menu, menu bar gọi CÙNG một đường:
/// `ContentView.runCommand(_:)`. Không viết lại logic ở nhiều chỗ.
///
/// Zoom timeline CHƯA nằm ở đây (state `pointsPerSecond` còn trong `TimelineEditor`) —
/// sẽ đưa vào khi làm `TimelineMetrics` ở M-C.
enum EditorCommand: Equatable {
    // Playback
    case playPause
    case seekBy(TimeInterval)

    // Điều hướng dòng lời
    case prevLine
    case nextLine

    // Timing dòng lời đang chọn (chỉnh TAY — không đụng aligner)
    case setLineStartAtPlayhead
    case setLineEndAtPlayhead
    case clearLineTiming

    // Thao tác trên cái đang chọn (clip lớp đè hoặc dòng lời)
    case splitAtPlayhead        // chỉ áp cho clip lớp đè
    case deleteSelection
    case duplicateSelection
    case nudgeSelection(TimeInterval)
    case copySelection          // chép clip lớp đè đang chọn
    case pasteClip              // dán clip đã chép tại vạch đỏ
    case pasteClipStyle         // dán CHỈ thuộc tính (màu/biến hình/blend/fade) sang clip đang chọn

    // Zoom timeline (M-C)
    case zoomIn
    case zoomOut
    case zoomToFit

    // Track (M-F / M-G)
    case toggleLyricsHidden
    case toggleMusicMuted

    // Tệp — nằm ở menu bar "File" (bỏ menu "Tệp" thừa trên thanh trên)
    case newProject
    case openProject
    case saveProject
    case saveProjectAs
    case openNewTab
}

// MARK: - M-B · Cầu nối menu bar / context menu ↔ editor đang focus

/// `ContentView` phát cái này ra scene qua `focusedSceneValue`; `KaraokeMakerApp.commands`
/// (menu bar) đọc lại để gọi ĐÚNG editor của tab đang mở. Không nhân bản logic.
///
/// (2026-09-24) SỬA LAG NẶNG TRÊN INTEL: `run`/`canRun` là closure nên struct này TRƯỚC không
/// `Equatable` được — `ContentView.body` chạy lại là tạo closure MỚI (identity mới), SwiftUI
/// không so sánh được nên LUÔN coi là "đã đổi", đẩy ngược lên `KaraokeMakerApp.body` (cấp App,
/// dựng lại menu bar) → kéo `ContentView` dựng lại → tạo `EditorCommandSink` mới → LẶP VÔ HẠN,
/// tự nuôi chính nó dù không có gì thật sự thay đổi. Đo bằng `sample` trên iMac Intel: ~29%
/// luồng chính lúc HOÀN TOÀN RẢNH RỖI nằm trong vòng `NSPerformVisuallyAtomicChange`/AttributeGraph
/// sinh ra bởi việc này; tắt hẳn dòng `.focusedSceneValue` là cách DUY NHẤT trong 4 thực nghiệm
/// (tắt beatSep, hoãn onAppear, tắt dòng này) triệt tiêu được — xác nhận đúng thủ phạm.
/// Sửa: bỏ 2 closure ra khỏi phép so sánh (hành vi luôn giống nhau, không cần so), thêm 2 trường
/// CHỈ-ĐỂ-SO-SÁNH phản ánh đúng những gì `canRun` thực sự phụ thuộc NGOÀI `selection`
/// (`ContentView.canRun`: `store.project.lines.isEmpty`, `copiedOverlay != nil`) — so sánh ĐỦ
/// để SwiftUI biết khi nào cần cập nhật lại menu (tránh vừa lặp vô hạn vừa menu bar bị "trễ").
struct EditorCommandSink: Equatable {
    var run: (EditorCommand) -> Void
    var canRun: (EditorCommand) -> Bool
    var selection: EditorSelection
    var linesEmpty: Bool
    var hasCopiedOverlay: Bool

    static func == (lhs: EditorCommandSink, rhs: EditorCommandSink) -> Bool {
        lhs.selection == rhs.selection
            && lhs.linesEmpty == rhs.linesEmpty
            && lhs.hasCopiedOverlay == rhs.hasCopiedOverlay
    }
}

struct EditorCommandKey: FocusedValueKey {
    typealias Value = EditorCommandSink
}

extension FocusedValues {
    var editorCommands: EditorCommandSink? {
        get { self[EditorCommandKey.self] }
        set { self[EditorCommandKey.self] = newValue }
    }
}
