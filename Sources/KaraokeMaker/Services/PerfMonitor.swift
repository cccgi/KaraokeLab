import Foundation
import QuartzCore
import AppKit

/// Đo độ nghẽn LUỒNG CHÍNH. Bật bằng biến môi trường `KMK_PERF=1`.
///
/// Đặt một Timer 60Hz trên luồng chính; nếu nó fire muộn hơn dự kiến (~16.7ms)
/// nghĩa là luồng chính vừa bị bận (SwiftUI dựng lại view, undo chụp ảnh project…).
/// In ra Terminal: mỗi lần nghẽn > 40ms + tóm tắt mỗi 2 giây.
final class PerfMonitor {
    static let shared = PerfMonitor()

    private var timer: Timer?
    private var last = CACurrentMediaTime()
    private var maxGap = 0.0
    private var hitches = 0
    private var ticks = 0
    private var lastReport = CACurrentMediaTime()

    /// Nhãn trạng thái để biết đang làm gì lúc nghẽn (do UI đặt vào).
    var note = "-"

    var enabled: Bool { ProcessInfo.processInfo.environment["KMK_PERF"] != nil }

    func startIfEnabled() {
        guard enabled, timer == nil else { return }
        last = CACurrentMediaTime()
        lastReport = last
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .default)
        timer = t
        write("[perf] BẬT — làm từng thao tác một, xem dòng 'nghẽn' và tóm tắt 2s\n")
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let gap = now - last
        last = now
        ticks += 1
        if gap > maxGap { maxGap = gap }

        let typing = (NSApp.keyWindow?.firstResponder is NSText)
            || (NSApp.keyWindow?.firstResponder is NSTextView)
        let label = (typing ? "gõ " : "") + note

        if gap > 0.040 {
            hitches += 1
            write(String(format: "[perf] nghẽn %4.0f ms   (%@)\n", gap * 1000, label))
        }
        if now - lastReport >= 2.0 {
            write(String(format: "[perf] 2s: %3d nhịp · %2d lần nghẽn>40ms · đỉnh %4.0f ms   (%@)\n",
                         ticks, hitches, maxGap * 1000, label))
            ticks = 0; hitches = 0; maxGap = 0; lastReport = now
        }
    }

    private func write(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
}
