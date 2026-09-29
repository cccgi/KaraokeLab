import SwiftUI
import Combine

/// Bộ nhớ tạm keyframe (copy/paste chuyển động giữa các lớp) — theo phiên.
@MainActor
final class KeyframeClipboard: ObservableObject {
    static let shared = KeyframeClipboard()
    @Published var frames: [OverlayKeyframe]?
    @Published var vizFrames: [VizKeyframe]?
    @Published var textFrames: [TextBlockKeyframe]?
    private init() {}
}

/// (2026-09-17) `BeatSeparation`/`AdvancedKaraoke` (tách nhạc + canh giờ AI) phát tiến độ
/// (`localProgress`/`listenProgress`) NHIỀU LẦN/GIÂY lúc đang chạy. `ContentView` từng giữ 2 object
/// này bằng `@StateObject` TRỰC TIẾP — mỗi lần publish, DÙ CHỈ 1 con số % nhỏ, khiến TOÀN BỘ
/// `ContentView.body` (cây view 3 cột + timeline) bị đánh dấu dựng lại, và (đúng nguyên nhân lag
/// đã tìm ra trước đó — xem `PlaybackController.setClockSeconds`) AppKit chạy lại Auto Layout CẢ
/// CỬA SỔ mỗi lần — rất nặng trên máy Intel cũ suốt lúc tách nhạc/canh giờ chạy. KHÔNG được sửa 2
/// file đó (thuật toán canh lời — cấm đụng, xem `CLAUDE.md`), nên sửa Ở ĐÂY: 1 "proxy" nhân bản
/// lại các trường ít đổi (isRunning/status/URL/phase/resultNote) y nguyên, nhưng THROTTLE riêng
/// trường tiến độ (localProgress/listenProgress) xuống tối đa vài lần/giây — giảm thẳng số lần
/// `ContentView` bị dựng lại trong lúc chạy, không đụng gì tới tốc độ/logic tách nhạc thật.
@MainActor
final class BeatSepProxy: ObservableObject {
    let source = BeatSeparation()
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var throttledProgress: Double = 0
    @Published private(set) var beatURL: URL?
    @Published private(set) var vocalURL: URL?
    @Published private(set) var usingUserStems = false
    var bag = Set<AnyCancellable>()

    init() {
        source.$isRunning.receive(on: DispatchQueue.main).sink { [weak self] in self?.isRunning = $0 }.store(in: &bag)
        source.$status.receive(on: DispatchQueue.main).sink { [weak self] in self?.status = $0 }.store(in: &bag)
        source.$beatURL.receive(on: DispatchQueue.main).sink { [weak self] in self?.beatURL = $0 }.store(in: &bag)
        source.$vocalURL.receive(on: DispatchQueue.main).sink { [weak self] in self?.vocalURL = $0 }.store(in: &bag)
        source.$usingUserStems.receive(on: DispatchQueue.main).sink { [weak self] in self?.usingUserStems = $0 }.store(in: &bag)
        source.$localProgress
            .throttle(for: .seconds(0.3), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.throttledProgress = $0 }
            .store(in: &bag)
    }
}

/// Xem comment ở `BeatSepProxy` — cùng lý do, áp dụng cho `AdvancedKaraoke` (canh giờ AI).
@MainActor
final class AdvancedKaraokeProxy: ObservableObject {
    let source = AdvancedKaraoke()
    @Published private(set) var phase: AdvancedKaraoke.Phase = .idle
    @Published private(set) var resultNote: String = ""
    @Published private(set) var throttledListenProgress: Double = 0
    var isBusy: Bool {
        switch phase {
        case .idle, .done, .failed: return false
        default: return true
        }
    }
    var bag = Set<AnyCancellable>()

    init() {
        source.$phase.receive(on: DispatchQueue.main).sink { [weak self] in self?.phase = $0 }.store(in: &bag)
        source.$resultNote.receive(on: DispatchQueue.main).sink { [weak self] in self?.resultNote = $0 }.store(in: &bag)
        source.$listenProgress
            .throttle(for: .seconds(0.3), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.throttledListenProgress = $0 }
            .store(in: &bag)
    }
}
