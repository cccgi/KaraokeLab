import CoreVideo
import QuartzCore
import Foundation

/// Bọc `CVDisplayLink`: gọi `onTick` trên luồng chính mỗi nhịp màn hình (~60Hz).
/// Chạy trên luồng riêng nên KHÔNG bị luồng chính bận (SwiftUI) làm nghẽn như `Timer`.
///
/// Có **gộp nhịp**: nếu luồng chính chưa xử lý xong nhịp trước thì bỏ nhịp mới
/// (không dồn đống → không kéo lag thêm trên máy yếu).
final class DisplayLink {
    private var link: CVDisplayLink?
    private let onTick: () -> Void
    private let lock = NSLock()
    private var pending = false

    init(_ onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard link == nil else { return }
        var l: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&l)
        guard let l else { return }

        CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, _, _, _ in
            guard let self else { return kCVReturnSuccess }
            self.lock.lock()
            let go = !self.pending
            if go { self.pending = true }
            self.lock.unlock()
            if go {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.pending = false; self.lock.unlock()
                    self.onTick()
                }
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(l)
        link = l
    }

    func stop() {
        if let l = link {
            CVDisplayLinkStop(l)
            link = nil
        }
        lock.lock(); pending = false; lock.unlock()
    }

    deinit { stop() }
}
