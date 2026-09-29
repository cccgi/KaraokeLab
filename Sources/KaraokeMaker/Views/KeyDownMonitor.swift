import SwiftUI
import AppKit

/// Bắt phím tắt ở cấp cửa sổ. Khi con trỏ đang ở trong một ô nhập chữ
/// (TextField / TextEditor) thì KHÔNG can thiệp, để việc gõ chữ bình thường.
struct KeyDownMonitor: ViewModifier {

    struct KeyPress {
        /// Ký tự (không xét phím bổ trợ), đã hạ chữ thường. Space là " ".
        let character: String
        /// Có đang giữ Command / Option / Control không.
        let hasCommandOptionControl: Bool
        /// Có đang giữ Shift không.
        let hasShift: Bool
        /// Có đang giữ Command không.
        let hasCommand: Bool
    }

    /// Trả về `true` nếu đã xử lý phím (nuốt sự kiện, không cho lan tiếp).
    let handler: (KeyPress) -> Bool

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let keyWin = NSApp.keyWindow
                    // Đang ở hộp thoại hệ thống (Lưu / Mở file, chọn màu, font…) hoặc một
                    // sheet → KHÔNG đụng vào, thả phím cho nó (nếu không, gõ tên file có
                    // chữ T/Y/R hay dấu cách sẽ bị nuốt).
                    if keyWin is NSPanel || keyWin?.sheetParent != nil {
                        return event
                    }
                    if let responder = keyWin?.firstResponder,
                       responder is NSText || responder is NSTextView {
                        return event
                    }

                    let modifiers = event.modifierFlags.intersection([.command, .option, .control])
                    let key = KeyPress(
                        character: (event.charactersIgnoringModifiers ?? "").lowercased(),
                        hasCommandOptionControl: !modifiers.isEmpty,
                        hasShift: event.modifierFlags.contains(.shift),
                        hasCommand: event.modifierFlags.contains(.command)
                    )
                    return handler(key) ? nil : event
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }
}

extension View {
    /// Xử lý phím tắt cấp cửa sổ (bỏ qua khi đang gõ trong ô chữ).
    func onWindowKeyDown(_ handler: @escaping (KeyDownMonitor.KeyPress) -> Bool) -> some View {
        modifier(KeyDownMonitor(handler: handler))
    }
}
