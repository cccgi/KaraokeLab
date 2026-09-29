import SwiftUI
import AppKit

/// Khi đang gõ trong một ô chữ, nếu người dùng nhấp chuột ra NGOÀI ô đó
/// thì lập tức thả con trỏ (bỏ chế độ sửa). Đây là cách xử lý ở tầng AppKit,
/// đáng tin hơn việc bắt tap bằng SwiftUI trên macOS.
struct OutsideClickDismiss: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                    handleClick(event)
                    return event
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }

    private func handleClick(_ event: NSEvent) {
        guard let window = event.window else { return }

        // Chỉ can thiệp khi đang gõ trong một ô chữ:
        // - field editor  = TextField 1 dòng
        // - NSTextView    = TextEditor nhiều dòng
        guard let editingView = window.firstResponder as? NSTextView else { return }

        let point = event.locationInWindow
        if let hit = window.contentView?.hitTest(point) {
            // Nhấp lại vào chính ô đang gõ -> giữ nguyên.
            if hit === editingView || hit.isDescendant(of: editingView) {
                return
            }
            // Nhấp sang một ô chữ khác -> để nó tự nhận con trỏ.
            if hit is NSTextField || hit.superview is NSTextField {
                return
            }
            if let otherTextView = hit as? NSTextView, otherTextView !== editingView {
                return
            }
        }

        // Nhấp ra vùng ngoài -> thả con trỏ.
        DispatchQueue.main.async {
            window.makeFirstResponder(nil)
        }
    }
}

extension View {
    /// Nhấp ra ngoài ô chữ đang gõ -> thoát chế độ sửa.
    func dismissesTextEditingOnOutsideClick() -> some View {
        modifier(OutsideClickDismiss())
    }
}
