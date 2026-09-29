import SwiftUI
import AppKit
import QuartzCore

enum PreviewBackground: String, CaseIterable, Identifiable {
    case dark = "Đen"
    case gray = "Xám"
    case checker = "Ô caro (trong suốt)"
    case media = "Ảnh/Video nền"
    var id: String { rawValue }
}

/// Khung xem thử karaoke.
/// - Kéo chữ chính / câu nhắc lên–xuống để đổi vị trí dọc.
/// - Lớp đè đang chọn: hiện khung + 4 tay cầm → kéo thân = dời, kéo góc = phóng to/thu nhỏ.
struct KaraokePreview: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var playback: PlaybackController
    /// (2026-09-17) CHỈ để đọc `seekGeneration` — xem comment ở `PlaybackClock` trong
    /// `PlaybackController.swift`: tách khỏi `playback` để KHÔNG kéo `ContentView` dựng lại mỗi
    /// lần tua (`ContentView` không giữ `@EnvironmentObject var clock`, chỉ view này mới cần).
    @EnvironmentObject var clock: PlaybackClock

    /// Tiếng của clip VIDEO lớp đè (chỉ khi bật) — tách hẳn khỏi bài hát chính.
    @StateObject private var overlayAudio = OverlayAudioMixer()

    let background: PreviewBackground
    var backgroundImage: CGImage? = nil
    var videoURL: URL? = nil
    var previewQuality: PreviewQuality = .medium
    var selectedOverlayID: UUID? = nil
    var selectedOverlayIDs: Set<UUID> = []
    var showSafeArea: Bool = false
    var onSelectOverlay: (UUID?) -> Void = { _ in }
    var onEditTextOverlay: (UUID) -> Void = { _ in }

    private var aspect: CGFloat {
        let r = store.project.resolution
        return r.height > 0 ? CGFloat(r.width) / CGFloat(r.height) : 16.0 / 9.0
    }

    private var videoActive: Bool {
        background == .media && store.project.backgroundMedia?.kind == .video && videoURL != nil
    }

    /// Clip lớp đè CÓ TIẾNG để trộn khi xem thử: clip AUDIO, hoặc clip VIDEO đã bật tiếng
    /// (đều bỏ nếu ẩn / đã tắt loa).
    private var audioOverlayClips: [OverlayClip] {
        store.project.overlays.filter { $0.carriesAudio }
    }
    private func pushOverlayAudio() {
        overlayAudio.sync(clips: audioOverlayClips, time: playback.renderTime, playing: playback.isPlaying)
    }

    var body: some View {
        ZStack {
            Color.black

            if videoActive, let url = videoURL, let media = store.project.backgroundMedia {
                VideoBackgroundView(
                    url: url,
                    isPlaying: playback.isPlaying,
                    currentTime: playback.currentTime,
                    quality: previewQuality,
                    scale: media.scale, offsetX: media.offsetX,
                    offsetY: media.offsetY, opacity: media.opacity,
                    colorAdjust: media.colorAdjust
                )
            }

            KaraokePreviewRepresentable(
                project: store.project,
                playback: playback,
                isPlaying: playback.isPlaying,
                seekGen: clock.seekGeneration,
                background: background,
                backgroundImage: videoActive ? nil : backgroundImage,
                suppressMediaFill: videoActive,
                selectedOverlayID: selectedOverlayID,
                selectedOverlayIDs: selectedOverlayIDs,
                showSafeArea: showSafeArea,
                onSetVerticalAnchor: { v in
                    let a = min(0.95, max(0.05, v))
                    if store.project.textKeyframes.isEmpty {
                        store.edit(L("Kéo vị trí chữ chính")) { store.project.style.verticalAnchor = a }
                    } else {
                        let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
                        let cur = store.project.textBlockTransform(atSong: songT,
                            baseAnchor: store.project.style.verticalAnchor, baseHOffset: store.project.style.horizontalOffset)
                        store.edit(L("Keyframe chữ")) { store.project.upsertTextKeyframe(atSong: songT, anchor: a, hOffset: cur.hOffset, fontScale: cur.fontScale) }
                    }
                },
                onSetHorizontalOffset: { v in
                    var x = min(0.45, max(-0.45, v))
                    if abs(x) < 0.008 { x = 0 }
                    if store.project.textKeyframes.isEmpty {
                        store.edit(L("Kéo chữ ngang")) { store.project.style.horizontalOffset = x }
                    } else {
                        let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
                        let cur = store.project.textBlockTransform(atSong: songT,
                            baseAnchor: store.project.style.verticalAnchor, baseHOffset: store.project.style.horizontalOffset)
                        store.edit(L("Keyframe chữ")) { store.project.upsertTextKeyframe(atSong: songT, anchor: cur.anchor, hOffset: x, fontScale: cur.fontScale) }
                    }
                },
                onScaleFont: { f in
                    if store.project.textKeyframes.isEmpty {
                        store.edit(L("Phóng cỡ chữ")) {
                            store.project.style.fontSize = min(400, max(10, store.project.style.fontSize * f))
                        }
                    } else {
                        let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
                        let cur = store.project.textBlockTransform(atSong: songT,
                            baseAnchor: store.project.style.verticalAnchor, baseHOffset: store.project.style.horizontalOffset)
                        let ns = min(4, max(0.25, cur.fontScale * f))
                        store.edit(L("Keyframe cỡ chữ")) {
                            store.project.upsertTextKeyframe(atSong: songT, anchor: cur.anchor, hOffset: cur.hOffset, fontScale: ns)
                        }
                    }
                },
                onSetNextGap: { v in
                    store.edit(L("Kéo vị trí câu kế")) {
                        // Cho phép câu nhắc nằm TRÊN câu chính (gap âm); giữ khoảng hở tối thiểu
                        // để 2 khối không đè hẳn lên nhau (kéo/chọn lại được).
                        var g = min(0.42, max(-0.42, v))
                        if abs(g) < 0.035 { g = g < 0 ? -0.035 : 0.035 }
                        store.project.style.nextLineGap = g
                    }
                },
                onSelectOverlay: onSelectOverlay,
                onEditTextOverlay: onEditTextOverlay,
                onOverlayTransform: { id, offX, offY, scale, rot in
                    store.perform(L("Biến hình lớp đè")) {
                        guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
                        if store.project.overlays[i].keyframes.isEmpty {
                            store.project.overlays[i].offsetX = offX
                            store.project.overlays[i].offsetY = offY
                            store.project.overlays[i].scale = scale
                            store.project.overlays[i].rotation = rot
                        } else {
                            // Clip có chuyển động → cập nhật / thêm keyframe tại vạch đỏ.
                            let lt = playback.currentTime - store.project.overlays[i].start
                            let cur = store.project.overlays[i].transform(atLocal: lt)
                            store.project.overlays[i].upsertKeyframe(atLocal: lt, offX: offX, offY: offY,
                                                                    scale: scale, rotation: rot, opacity: cur.opacity)
                        }
                    }
                },
                onVisualizerTransform: { spec in
                    store.perform(L("Kéo sóng nhạc")) {
                        if store.project.visualizer?.keyframes.isEmpty == false {
                            // Có chuyển động → cập nhật/thêm mốc tại vạch đỏ, GIỮ nguyên keyframes.
                            var v = store.project.visualizer ?? spec
                            v.widthFrac = spec.widthFrac; v.heightFrac = spec.heightFrac
                            v.offsetX = spec.offsetX; v.baselineY = spec.baselineY; v.rotation = spec.rotation
                            let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
                            v.upsertKeyframe(atSong: songT)
                            store.project.visualizer = v
                        } else {
                            store.project.visualizer = spec
                        }
                    }
                }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .onAppear {
            overlayAudio.clipsProvider = { audioOverlayClips }
            overlayAudio.clockProvider = { (playback.renderTime, playback.isPlaying) }
            if !audioOverlayClips.isEmpty { overlayAudio.activate() }
        }
        .onDisappear { overlayAudio.deactivate() }
        .onChange(of: playback.isPlaying) { _ in pushOverlayAudio() }
        .onChange(of: clock.seekGeneration) { _ in pushOverlayAudio() }
        .onChange(of: audioOverlayClips.map(\.id)) { ids in
            if ids.isEmpty { overlayAudio.deactivate() } else { overlayAudio.activate(); pushOverlayAudio() }
        }
    }
}

// MARK: - Cầu nối AppKit

private struct KaraokePreviewRepresentable: NSViewRepresentable {
    let project: KaraokeProject
    let playback: PlaybackController   // strong: `unowned` từng crash khi SwiftUI copy struct lúc teardown
    let isPlaying: Bool
    /// Chỉ để BUỘC `updateNSView` chạy lại khi tua/nạp — canvas tự đọc `renderTime`.
    let seekGen: Int
    let background: PreviewBackground
    let backgroundImage: CGImage?
    var suppressMediaFill: Bool = false
    let selectedOverlayID: UUID?
    var selectedOverlayIDs: Set<UUID> = []
    var showSafeArea: Bool = false
    let onSetVerticalAnchor: (Double) -> Void
    let onSetHorizontalOffset: (Double) -> Void
    let onScaleFont: (Double) -> Void
    let onSetNextGap: (Double) -> Void
    let onSelectOverlay: (UUID?) -> Void
    var onEditTextOverlay: (UUID) -> Void = { _ in }
    let onOverlayTransform: (UUID, Double, Double, Double, Double) -> Void
    let onVisualizerTransform: (MusicVisualizer) -> Void

    func makeNSView(context: Context) -> KaraokePreviewCanvas {
        KaraokePreviewCanvas()
    }

    func updateNSView(_ view: KaraokePreviewCanvas, context: Context) {
        view.project = project
        view.background = background
        view.backgroundImage = backgroundImage
        view.suppressMediaFill = suppressMediaFill
        view.selectedOverlayID = selectedOverlayID
        view.selectedOverlayIDs = selectedOverlayIDs
        view.showSafeArea = showSafeArea
        view.onSetVerticalAnchor = onSetVerticalAnchor
        view.onSetHorizontalOffset = onSetHorizontalOffset
        view.onScaleFont = onScaleFont
        view.onSetNextGap = onSetNextGap
        view.onSelectOverlay = onSelectOverlay
        view.onEditTextOverlay = onEditTextOverlay
        view.onOverlayTransform = onOverlayTransform
        view.onVisualizerTransform = onVisualizerTransform
        view.timeProvider = { [weak playback] in playback?.renderTime ?? 0 }
        view.setPlaying(isPlaying)
        _ = seekGen
        if !isPlaying { view.time = playback.renderTime }
        view.syncAfterCommit()   // model đã cập nhật → bỏ preview gizmo (khớp liền, không giật)
        view.needsDisplay = true
    }
}

private final class KaraokePreviewCanvas: NSView {
    var project: KaraokeProject?
    var time: TimeInterval = 0
    /// Bước 2c — `time` = giờ-timeline. Karaoke (nền + chữ + sóng) chạy tại `time − mốc clip ★`.
    private var karTime: TimeInterval { max(0, time - (project?.karaokeClipStart ?? 0)) }
    private var karStarted: Bool { time >= (project?.karaokeClipStart ?? 0) - 0.001 }
    var background: PreviewBackground = .dark
    var backgroundImage: CGImage?
    var suppressMediaFill = false
    var selectedOverlayID: UUID?
    var selectedOverlayIDs: Set<UUID> = []
    var showSafeArea = false
    var onSetVerticalAnchor: ((Double) -> Void)?
    var onSetHorizontalOffset: ((Double) -> Void)?
    var onScaleFont: ((Double) -> Void)?
    var onSetNextGap: ((Double) -> Void)?
    var onSelectOverlay: ((UUID?) -> Void)?
    var onEditTextOverlay: ((UUID) -> Void)?
    var onOverlayTransform: ((UUID, Double, Double, Double, Double) -> Void)?

    private enum DragTarget { case main, next }
    private var dragTarget: DragTarget?
    private var dragStartFrac: CGFloat = 0
    private var anchorAtStart: CGFloat = 0
    private var gapAtStart: CGFloat = 0

    // ----- Gizmo lớp đè -----
    private enum GizmoMode { case move, scale(corner: Int), rotate }
    private struct GDrag {
        let id: UUID
        let mode: GizmoMode
        let startMouse: CGPoint
        let startOffX: Double
        let startOffY: Double
        let startScale: Double
        let startRot: Double
        let center: CGPoint
        let cornerDist: CGFloat
        let startAngle: CGFloat        // góc tâm→chuột lúc bắt đầu xoay (radian)
    }
    private var gDrag: GDrag?
    private var gizmoPreview: (id: UUID, offX: Double, offY: Double, scale: Double, rot: Double)?
    /// Kéo NHÓM trên preview: id → (offX, offY) gốc; + bản xem trước khi đang kéo.
    private var groupDragBase: [UUID: (offX: Double, offY: Double)] = [:]
    private var groupGizmoPreview: [UUID: (offX: Double, offY: Double)]?

    // ----- Kéo "sóng nhạc" -----
    var onVisualizerTransform: ((MusicVisualizer) -> Void)?
    private enum VizDragMode: Equatable { case move, resize }
    private struct VizDrag { let mode: VizDragMode; let startMouse: CGPoint; let spec: MusicVisualizer }
    private var vizDrag: VizDrag?
    private var vizPreview: MusicVisualizer?
    /// Sóng nhạc hiện hành: đang kéo → bản kéo; nếu không → bản đã NỘI SUY keyframe theo giờ bài.
    private func currentViz() -> MusicVisualizer? {
        if let vp = vizPreview { return vp }
        return project?.visualizer.map { $0.resolved(atSong: karTime) }
    }

    /// Chữ nhật vùng sóng nhạc trong toạ độ VIEW (y-DOWN, gốc trên-trái).
    private func vizViewRect(_ s: MusicVisualizer) -> CGRect {
        let H = bounds.height, W = bounds.width
        let regionW = W * CGFloat(s.widthFrac)
        let x0 = (W - regionW) / 2 + CGFloat(s.offsetX) * W
        let maxH = CGFloat(s.heightFrac) * H
        let baseYUp = CGFloat(s.baselineY) * H
        let hiUp = baseYUp + maxH
        let loUp = baseYUp - maxH * 0.5
        return CGRect(x: x0, y: H - hiUp, width: regionW, height: hiUp - loUp)
    }

    private let handleSize: CGFloat = 9
    private let rotateHandleGap: CGFloat = 26      // tay xoay cách mép trên

    private func rotatePoint(_ p: CGPoint, around c: CGPoint, by rad: CGFloat) -> CGPoint {
        let s = sin(rad), co = cos(rad)
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }
    /// Neo tay xoay (giữa mép trên, đã xoay theo góc hiện tại) trong toạ độ view.
    private func rotateHandlePoint(_ r: CGRect, rotDeg: Double) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let raw = CGPoint(x: r.midX, y: r.minY - rotateHandleGap)
        return rotatePoint(raw, around: c, by: CGFloat(rotDeg) * .pi / 180)
    }

    /// Kế hoạch vẽ preview — cache theo dòng, canvas giữ suốt đời.
    private let previewPlan = KaraokeRenderer.PreviewPlan()

    // ----- Rà chuột lên khối chữ → làm sáng để biết kéo được -----
    private var hoverTextZone: DragTarget?
    private var hoverTrack: NSTrackingArea?
    // Xem trước lúc KÉO chữ dọc — chỉ cập nhật cục bộ + vẽ lại canvas, KHÔNG đụng
    // `store` mỗi lần chuột nhích (round-trip SwiftUI = giật). Chốt vào store ở mouseUp.
    private var dragPreviewAnchor: CGFloat?
    private var dragPreviewOffsetX: CGFloat?
    private var dragPreviewGap: CGFloat?
    private var dragPreviewFontScale: CGFloat?     // .main kéo GÓC = phóng chữ
    private var dragDownPoint: NSPoint = .zero
    private var offsetXAtStart: CGFloat = 0
    private enum TextDrag { case move, scale }
    private var textDrag: TextDrag = .move
    private var textCenterAtDown: CGPoint = .zero
    private var textCornerDistAtDown: CGFloat = 1

    /// Khung bao (đã nới) của khối chữ chính / câu nhắc trong toạ độ view.
    private func textZoneRect(_ zone: DragTarget) -> CGRect? {
        let raw = zone == .main ? previewPlan.mainBlockRect : previewPlan.nextBlockRect
        return raw?.insetBy(dx: -10, dy: -8)
    }
    /// Chọn khối chữ dưới con trỏ. ("Nhắc câu tiếp theo" đã gỡ — chỉ còn câu chính.)
    private func pickTextZone(at p: NSPoint) -> DragTarget? {
        if textZoneRect(.main)?.contains(p) ?? false { return .main }
        return nil
    }
    private func setHoverTextZone(_ z: DragTarget?) {
        guard hoverTextZone != z else { return }
        hoverTextZone = z
        (z == nil ? NSCursor.arrow : NSCursor.openHand).set()
        needsDisplay = true
    }

    /// Đồng hồ riêng (CVDisplayLink) để vẽ mượt khi phát, KHÔNG qua SwiftUI.
    var timeProvider: (() -> TimeInterval)?
    private var displayLink: DisplayLink?
    private var linkRunning = false
    /// (2026-09-14) Hạ nhịp vẽ thật xuống ~30Hz — vsync máy 60Hz đo bằng `sample` lúc user báo
    /// "lag toàn bộ app" cho thấy CỨ MỖI LẦN cửa sổ commit theo vsync (không riêng gì có
    /// `CAAnimation` hay không — tự set `needsDisplay`/`position` mỗi khung CŨNG tính), AppKit
    /// chạy lại Auto Layout của CẢ CỬA SỔ — nặng trên máy Intel cũ. Giảm còn 1 nửa tần suất
    /// (~30Hz, mắt người vẫn thấy mượt với chữ karaoke) để giảm ~1 nửa chi phí đó. 60Hz gốc vẫn
    /// còn quá đủ mượt ở 30Hz cho nội dung CHỮ (không phải video action nhanh).
    private var lastRealDraw: CFTimeInterval = 0

    private var spectrumObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        // Phân tích "sóng nhạc" xong (chạy nền) → vẽ lại preview.
        spectrumObserver = NotificationCenter.default.addObserver(
            forName: SpectrumStore.readyNote, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        displayLink?.stop()
        if let o = spectrumObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func displayTick() {
        let nowClock = CACurrentMediaTime()
        guard nowClock - lastRealDraw >= 1.0 / 30.0 else { return }
        guard let tp = timeProvider else { return }
        let now = tp()
        if abs(now - time) > 0.0001 {
            lastRealDraw = nowClock
            time = now
            needsDisplay = true
            displayIfNeeded()
        }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != linkRunning else { return }
        linkRunning = playing
        if playing {
            if displayLink == nil {
                displayLink = DisplayLink { [weak self] in self?.displayTick() }
            }
            displayLink?.start()
        } else {
            displayLink?.stop()
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !suppressMediaFill }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hình học lớp đè

    private var selectedClip: OverlayClip? {
        guard let id = selectedOverlayID else { return nil }
        return project?.overlays.first { $0.id == id }
    }

    /// Rect của một lớp đè trong toạ độ VIEW (y-down), có thể ghi đè scale/offset.
    private func clipViewRect(_ clip: OverlayClip, scale: Double? = nil,
                             offX: Double? = nil, offY: Double? = nil) -> CGRect {
        let img = clip.kind == .text ? OverlayTextStore.image(for: clip)
                                     : OverlayImageStore.image(for: clip)
        let kf = clip.transform(atLocal: time - clip.start)   // chuyển động: pose tại thời điểm này
        return Compositor.overlayViewRect(
            image: img,
            canvasSize: bounds.size,
            scale: CGFloat(scale ?? kf.scale),
            offsetX: CGFloat(offX ?? kf.offX),
            offsetY: CGFloat(offY ?? kf.offY),
            fit: clip.kind == .text ? .native : .fit)
    }

    /// Pose (biến hình) hiện tại của clip — dùng khi bắt đầu kéo gizmo.
    private func clipPose(_ clip: OverlayClip) -> (offX: Double, offY: Double, scale: Double, rot: Double) {
        let k = clip.transform(atLocal: time - clip.start)
        return (k.offX, k.offY, k.scale, k.rot)
    }

    private func cornerPoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    private func handleRect(_ c: CGPoint) -> CGRect {
        CGRect(x: c.x - handleSize, y: c.y - handleSize, width: handleSize * 2, height: handleSize * 2)
    }

    // MARK: Chuột

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTrack { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); hoverTrack = t
    }

    private var hoverViz = false

    override func mouseMoved(with event: NSEvent) {
        guard gDrag == nil, dragTarget == nil, vizDrag == nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Rê lên vùng sóng nhạc (khi không trỏ vào chữ) → hiện khung kéo.
        let onViz: Bool = {
            guard selectedOverlayID == nil, let s = currentViz(), s.enabled, pickTextZone(at: p) == nil
            else { return false }
            return vizViewRect(s).insetBy(dx: -12, dy: -12).contains(p)
        }()
        if onViz != hoverViz { hoverViz = onViz; needsDisplay = true }
        if onViz { setHoverTextZone(nil); return }
        // Đang trỏ vào gizmo lớp đè đang chọn → không gợi ý kéo chữ.
        if let clip = selectedClip, clipViewRect(clip).insetBy(dx: -14, dy: -14).contains(p) {
            setHoverTextZone(nil); return
        }
        setHoverTextZone(pickTextZone(at: p))
    }

    override func mouseExited(with event: NSEvent) {
        setHoverTextZone(nil)
        if hoverViz { hoverViz = false; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 1, bounds.height > 1 else { return }

        // 0) Bấm ĐÚP trúng 1 lớp CHỮ → chọn + mở sửa nội dung ngay.
        if event.clickCount == 2, let project {
            for clip in project.overlays.reversed()
            where clip.kind == .text && !clip.isHidden && time >= clip.start && time < clip.end {
                if clipViewRect(clip).insetBy(dx: -6, dy: -6).contains(p) {
                    onSelectOverlay?(clip.id)
                    onEditTextOverlay?(clip.id)
                    return
                }
            }
        }

        // 1) Tay cầm / thân của lớp đè ĐANG chọn (bỏ qua nếu đã KHOÁ — (U4) không cho kéo nhầm).
        if let clip = selectedClip, !clip.isLocked {
            let r = clipViewRect(clip)
            let center = CGPoint(x: r.midX, y: r.midY)
            let rot = CGFloat(clip.rotation) * .pi / 180
            // Chuột đưa về hệ CHƯA xoay của khung (xoay ngược quanh tâm).
            let pl = rotatePoint(p, around: center, by: -rot)

            // Tay XOAY (điểm tròn phía trên mép, đã xoay theo góc hiện tại).
            let rh = rotateHandlePoint(r, rotDeg: clip.rotation)
            if handleRect(rh).contains(p) {
                gDrag = GDrag(id: clip.id, mode: .rotate, startMouse: p,
                              startOffX: clipPose(clip).offX, startOffY: clipPose(clip).offY,
                              startScale: clipPose(clip).scale, startRot: clipPose(clip).rot, center: center,
                              cornerDist: 1,
                              startAngle: atan2(p.y - center.y, p.x - center.x))
                NSCursor.crosshair.set(); return
            }
            for (i, cp) in cornerPoints(r).enumerated() where handleRect(cp).contains(pl) {
                gDrag = GDrag(id: clip.id, mode: .scale(corner: i), startMouse: p,
                              startOffX: clipPose(clip).offX, startOffY: clipPose(clip).offY,
                              startScale: clipPose(clip).scale, startRot: clipPose(clip).rot, center: center,
                              cornerDist: max(1, hypot(cp.x - center.x, cp.y - center.y)),
                              startAngle: 0)
                NSCursor.crosshair.set(); return
            }
            if r.insetBy(dx: -6, dy: -6).contains(pl) {
                gDrag = GDrag(id: clip.id, mode: .move, startMouse: p,
                              startOffX: clipPose(clip).offX, startOffY: clipPose(clip).offY,
                              startScale: clipPose(clip).scale, startRot: clipPose(clip).rot, center: center,
                              cornerDist: 1, startAngle: 0)
                // Kéo NHÓM: chốt offset gốc mọi lớp trong nhóm (kể cả lớp đang kéo).
                groupDragBase = [:]
                if selectedOverlayIDs.count > 1, selectedOverlayIDs.contains(clip.id), let project {
                    for cc in project.overlays where selectedOverlayIDs.contains(cc.id) && !cc.isLocked {
                        let pose = clipPose(cc)
                        groupDragBase[cc.id] = (pose.offX, pose.offY)
                    }
                }
                NSCursor.closedHand.set(); return
            }
        }

        // 2) Bấm trúng lớp đè khác (đang hiện tại thời điểm này) → chọn + kéo luôn.
        if let project {
            for clip in project.overlays.reversed()
            where !clip.isHidden && time >= clip.start && time < clip.end {
                let r = clipViewRect(clip)
                if r.contains(p) {
                    onSelectOverlay?(clip.id)
                    if !clip.isLocked {
                        gDrag = GDrag(id: clip.id, mode: .move, startMouse: p,
                                      startOffX: clipPose(clip).offX, startOffY: clipPose(clip).offY,
                                      startScale: clipPose(clip).scale, startRot: clipPose(clip).rot,
                                      center: CGPoint(x: r.midX, y: r.midY), cornerDist: 1,
                                      startAngle: 0)
                        NSCursor.closedHand.set()
                    }
                    return
                }
            }
        }

        // 2.6) Sóng nhạc — kéo để DỜI, kéo góc để PHÓNG (khi không bấm trúng chữ/lớp đè).
        if selectedOverlayID == nil, let spec = currentViz(), spec.enabled, pickTextZone(at: p) == nil {
            let r = vizViewRect(spec)
            for cp in cornerPoints(r) where handleRect(cp).contains(p) {
                vizDrag = VizDrag(mode: .resize, startMouse: p, spec: spec)
                NSCursor.crosshair.set(); return
            }
            if r.insetBy(dx: -12, dy: -12).contains(p) {
                vizDrag = VizDrag(mode: .move, startMouse: p, spec: spec)
                NSCursor.closedHand.set(); return
            }
        }

        // 3) Kéo chữ chính / câu nhắc lên–xuống (chỉ khi không có lớp đè nào được chọn).
        if selectedOverlayID == nil, let style = project?.style {
            let frac = p.y / bounds.height
            var target = pickTextZone(at: p)
            if target == nil {                       // dự phòng: theo khoảng cách tới vạch neo
                let dMain = abs(frac - CGFloat(style.verticalAnchor))
                if dMain < 0.22 { target = .main }
            }
            if let target {
                dragStartFrac = frac
                dragDownPoint = p
                // Có keyframe chữ → bắt đầu kéo từ vị trí ĐÃ NỘI SUY tại vạch đỏ.
                let baseTB = project?.textBlockTransform(atSong: karTime,
                    baseAnchor: style.verticalAnchor, baseHOffset: style.horizontalOffset)
                    ?? (anchor: style.verticalAnchor, hOffset: style.horizontalOffset, fontScale: 1)
                anchorAtStart = CGFloat(baseTB.anchor)
                gapAtStart = CGFloat(style.nextLineGap)
                offsetXAtStart = CGFloat(baseTB.hOffset)
                dragTarget = target
                hoverTextZone = nil
                // Bấm sát GÓC khung chữ chính → kéo phóng to/nhỏ; ngược lại = dời.
                textDrag = .move
                if target == .main, let mb = textZoneRect(.main) {
                    let c = CGPoint(x: mb.midX, y: mb.midY)
                    for cp in cornerPoints(mb) where handleRect(cp).contains(p) {
                        textDrag = .scale
                        textCenterAtDown = c
                        textCornerDistAtDown = max(1, hypot(cp.x - c.x, cp.y - c.y))
                        NSCursor.crosshair.set()
                        return
                    }
                }
                NSCursor.closedHand.set()
                return
            }
        }

        // 4) Vùng trống → bỏ chọn lớp đè.
        if selectedOverlayID != nil { onSelectOverlay?(nil) }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 1, bounds.height > 1 else { return }

        if let d = vizDrag {
            var s = d.spec
            let dx = Double((p.x - d.startMouse.x) / bounds.width)
            let dy = Double((p.y - d.startMouse.y) / bounds.height)   // view y-DOWN: xuống = +
            switch d.mode {
            case .move:
                var ox = d.spec.offsetX + dx
                if abs(ox) < 0.01 { ox = 0 }
                s.offsetX = min(0.5, max(-0.5, ox))
                s.baselineY = min(0.9, max(0, d.spec.baselineY - dy))   // kéo LÊN → baselineY tăng
            case .resize:
                s.widthFrac  = min(1.0, max(0.15, d.spec.widthFrac + dx * 2))
                s.heightFrac = min(0.7, max(0.04, d.spec.heightFrac - dy * 1.4))
            }
            vizPreview = s
            needsDisplay = true
            return
        }

        if let d = gDrag {
            switch d.mode {
            case .move:
                let dOffX = Double((p.x - d.startMouse.x) / bounds.width)
                let dOffY = Double((p.y - d.startMouse.y) / bounds.height)
                if !groupDragBase.isEmpty {
                    // Kéo CẢ NHÓM: dời mọi lớp theo cùng delta.
                    var mp: [UUID: (offX: Double, offY: Double)] = [:]
                    for (id, base) in groupDragBase {
                        mp[id] = (min(0.5, max(-0.5, base.offX + dOffX)),
                                  min(0.5, max(-0.5, base.offY + dOffY)))
                    }
                    groupGizmoPreview = mp
                    if let me = mp[d.id] { gizmoPreview = (d.id, me.offX, me.offY, d.startScale, d.startRot) }
                    needsDisplay = true
                    return
                }
                var offX = d.startOffX + dOffX
                var offY = d.startOffY + dOffY
                if abs(offX) < 0.012 { offX = 0 }
                if abs(offY) < 0.012 { offY = 0 }
                gizmoPreview = (d.id, offX, offY, d.startScale, d.startRot)
            case .scale:
                let dist = hypot(p.x - d.center.x, p.y - d.center.y)
                var scale = min(4, max(0.03, d.startScale * Double(dist / d.cornerDist)))
                // Hít về "vừa khung" khi kéo gần đầy màn hình xem trước.
                if let clip = project?.overlays.first(where: { $0.id == d.id }) {
                    let r1 = clipViewRect(clip, scale: 1, offX: d.startOffX, offY: d.startOffY)
                    if r1.width > 1, r1.height > 1 {
                        let fit = Double(min(bounds.width / r1.width, bounds.height / r1.height))
                        if fit > 0.05, abs(scale - fit) / fit < 0.06 { scale = fit }
                    }
                }
                gizmoPreview = (d.id, d.startOffX, d.startOffY, scale, d.startRot)
            case .rotate:
                let ang = atan2(p.y - d.center.y, p.x - d.center.x)
                var deg = d.startRot + Double((ang - d.startAngle) * 180 / .pi)
                deg = (deg.truncatingRemainder(dividingBy: 360) + 540)
                    .truncatingRemainder(dividingBy: 360) - 180        // về [-180,180)
                for snap in [-180.0, -90, 0, 90, 180] where abs(deg - snap) < 4 { deg = snap }
                gizmoPreview = (d.id, d.startOffX, d.startOffY, d.startScale, deg)
            }
            needsDisplay = true
            return
        }

        guard let target = dragTarget else { return }
        let frac = p.y / bounds.height
        let delta = frac - dragStartFrac
        switch target {
        case .main where textDrag == .scale:
            let dist = hypot(p.x - textCenterAtDown.x, p.y - textCenterAtDown.y)
            dragPreviewFontScale = min(4, max(0.25, dist / textCornerDistAtDown))
        case .main:
            dragPreviewAnchor = min(0.95, max(0.05, anchorAtStart + delta))
            var x = offsetXAtStart + (p.x - dragDownPoint.x) / bounds.width
            x = min(0.45, max(-0.45, x))
            if abs(x) < 0.008 { x = 0 }
            dragPreviewOffsetX = x
        case .next:
            var g = min(0.42, max(-0.42, gapAtStart + delta))
            if abs(g) < 0.035 { g = g < 0 ? -0.035 : 0.035 }
            dragPreviewGap = g
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if vizDrag != nil {
            if let s = vizPreview { onVisualizerTransform?(s) }   // GIỮ vizPreview tới syncAfterCommit
            vizDrag = nil
            NSCursor.arrow.set()
            needsDisplay = true
            return
        }
        if let d = gDrag {
            if let mp = groupGizmoPreview {
                // Kéo NHÓM: chốt offset mọi lớp (giữ scale/rot của từng lớp).
                for (id, v) in mp {
                    let cl = project?.overlays.first { $0.id == id }
                    onOverlayTransform?(id, v.offX, v.offY, cl?.scale ?? d.startScale, cl?.rotation ?? d.startRot)
                }
            } else {
                let gp = gizmoPreview
                onOverlayTransform?(d.id, gp?.offX ?? d.startOffX, gp?.offY ?? d.startOffY,
                                    gp?.scale ?? d.startScale, gp?.rot ?? d.startRot)
            }
            gDrag = nil
            groupDragBase = [:]
            // GIỮ preview tới khi `updateNSView` nhận model mới → không giật 1 nhịp.
            needsDisplay = true
        }
        if let target = dragTarget {                 // chốt kéo chữ: 1 lần ghi store
            switch target {
            case .main where textDrag == .scale:
                if let f = dragPreviewFontScale, abs(f - 1) > 0.001 { onScaleFont?(Double(f)) }
            case .main:
                if let a = dragPreviewAnchor { onSetVerticalAnchor?(Double(a)) }
                if let x = dragPreviewOffsetX { onSetHorizontalOffset?(Double(x)) }
            case .next:
                if let g = dragPreviewGap { onSetNextGap?(Double(g)) }
            }
            needsDisplay = true
        }
        dragTarget = nil
        textDrag = .move
        NSCursor.arrow.set()
    }

    /// Gọi từ `updateNSView`: model đã phản ánh giá trị vừa commit → bỏ preview.
    func syncAfterCommit() {
        if gizmoPreview != nil, gDrag == nil { gizmoPreview = nil }
        if groupGizmoPreview != nil, gDrag == nil { groupGizmoPreview = nil }
        if vizPreview != nil, vizDrag == nil { vizPreview = nil }
        if dragTarget == nil, dragPreviewAnchor != nil || dragPreviewGap != nil
            || dragPreviewOffsetX != nil || dragPreviewFontScale != nil {
            dragPreviewAnchor = nil; dragPreviewGap = nil
            dragPreviewOffsetX = nil; dragPreviewFontScale = nil
        }
    }

    // MARK: Vẽ

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let viewSize = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())

        Compositor.draw(
            Compositor.previewBackgroundLayers(
                project: project, background: background,
                backgroundImage: backgroundImage, suppressMediaFill: suppressMediaFill,
                time: karTime, duration: project?.audio?.duration ?? 0,
                beatEnergy: currentBeatEnergy()),
            in: ctx, canvasSize: bounds.size, flipped: true)

        guard let project, viewSize.width > 1, viewSize.height > 1 else { return }

        // Lớp đè đang được KÉO (1 lớp hoặc cả nhóm) — vẽ riêng bằng giá trị preview.
        let dragExcl: Set<UUID> = groupGizmoPreview.map { Set($0.keys) }
            ?? (gizmoPreview.map { [$0.id] } ?? [])

        // Lớp đè NẰM DƯỚI chữ (ảnh graded tô màu…).
        Compositor.draw(Compositor.overlayLayers(project: project, time: time,
                                                 zone: .belowText, excluding: dragExcl),
                        in: ctx, canvasSize: viewSize, flipped: true)

        drawVisualizer(ctx, size: viewSize, above: false)

        // Kéo chữ: offset đọc từ `dragPreview*` (KHÔNG gắn với `dragTarget`) → lúc thả chuột,
        // model đã đổi nhưng `updateNSView` chưa chạy: preview vẫn giữ đúng vị trí, KHÔNG nhảy
        // lui-tới. `syncAfterCommit` xoá preview ĐÚNG lúc model đã cập nhật → khớp liền.
        var textDX: CGFloat = 0
        var textDY: CGFloat = 0        // dời CẢ khối chữ (chính + nhắc)
        var nextDY: CGFloat = 0        // chỉ dời câu nhắc
        // Vị trí GỐC hiện hành = tĩnh, hoặc đã nội suy keyframe tại vạch đỏ.
        let tb0 = project.textBlockTransform(atSong: karTime,
            baseAnchor: project.style.verticalAnchor, baseHOffset: project.style.horizontalOffset)
        if let a = dragPreviewAnchor { textDY = (a - CGFloat(tb0.anchor)) * viewSize.height }
        if let x = dragPreviewOffsetX { textDX = (x - CGFloat(tb0.hOffset)) * viewSize.width }
        if let g = dragPreviewGap { nextDY = (g - CGFloat(project.style.nextLineGap)) * viewSize.height }

        ctx.saveGState()
        if let f = dragPreviewFontScale, let mb = previewPlan.mainBlockRect {
            let c = CGPoint(x: mb.midX, y: mb.midY)      // phóng quanh tâm khối chữ
            ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: f, y: f); ctx.translateBy(x: -c.x, y: -c.y)
        } else if textDX != 0 || textDY != 0 {
            ctx.translateBy(x: textDX, y: textDY)
        }
        if karStarted {
            KaraokeRenderer.drawPreview(in: ctx, canvasSize: viewSize, project: project,
                                        time: karTime, plan: previewPlan, nextLineDY: nextDY)
        }
        ctx.restoreGState()

        // Vạch canh giữa khi kéo ngang đã hít về tâm.
        if dragTarget == .main, textDrag == .move, dragPreviewOffsetX == 0 {
            NSColor.systemYellow.withAlphaComponent(0.75).setStroke()
            let l = NSBezierPath()
            l.move(to: NSPoint(x: viewSize.width / 2, y: 0))
            l.line(to: NSPoint(x: viewSize.width / 2, y: viewSize.height))
            l.lineWidth = 1; l.setLineDash([3, 3], count: 2, phase: 0); l.stroke()
        }

        // Gợi ý: làm sáng khối chữ đang rà chuột / đang kéo (vẽ SAU chữ).
        if let zone = dragTarget ?? hoverTextZone, let base = textZoneRect(zone) {
            var box = base
            if dragTarget == .main {
                if let f = dragPreviewFontScale {           // phóng quanh tâm
                    let c = CGPoint(x: box.midX, y: box.midY)
                    box = CGRect(x: c.x - box.width * f / 2, y: c.y - box.height * f / 2,
                                 width: box.width * f, height: box.height * f)
                } else {
                    box.origin.x += textDX; box.origin.y += textDY
                }
            } else if dragTarget == .next {
                box.origin.y += nextDY
            }
            box = box.intersection(CGRect(origin: .zero, size: viewSize).insetBy(dx: 1, dy: 1))
            let dragging = dragTarget != nil
            let path = NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7)
            Theme.accentNS.withAlphaComponent(dragging ? 0.16 : 0.10).setFill(); path.fill()
            Theme.accentNS.withAlphaComponent(dragging ? 0.95 : 0.65).setStroke()
            path.lineWidth = 1.5
            if !dragging { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
            // Khối CHÍNH: 4 tay cầm góc để phóng to/nhỏ.
            if zone == .main {
                for cp in cornerPoints(box) {
                    let hr = CGRect(x: cp.x - 4, y: cp.y - 4, width: 8, height: 8)
                    NSColor.white.setFill(); NSBezierPath(rect: hr).fill()
                    Theme.accentNS.setStroke(); let hp = NSBezierPath(rect: hr); hp.lineWidth = 1; hp.stroke()
                }
            }
            var hx = box.maxX + 9
            if hx > viewSize.width - 6 { hx = box.minX - 9 }
            drawUpDownHint(CGPoint(x: hx, y: box.midY))
        }

        drawVisualizer(ctx, size: viewSize, above: true)

        // Lớp đè ĐÈ LÊN chữ (logo…). Clip đang kéo thì vẽ riêng bằng giá trị preview.
        Compositor.draw(Compositor.overlayLayers(project: project, time: time,
                                                 zone: .aboveText, excluding: dragExcl),
                        in: ctx, canvasSize: viewSize, flipped: true)
        func drawDragClip(_ clip: OverlayClip, offX: Double, offY: Double, scale: Double, rot: Double) {
            guard let img = clip.kind == .text ? OverlayTextStore.image(for: clip)
                                               : OverlayImageStore.image(for: clip) else { return }
            Compositor.draw([Compositor.Layer(content: .image(img), opacity: CGFloat(clip.opacity),
                                              blend: clip.blend,
                                              fit: clip.kind == .text ? .native : .fit, scale: CGFloat(scale),
                                              offsetX: CGFloat(offX), offsetY: CGFloat(offY),
                                              rotationDeg: CGFloat(rot))],
                            in: ctx, canvasSize: viewSize, flipped: true)
        }
        if let mp = groupGizmoPreview {
            for (id, v) in mp {
                guard let clip = project.overlays.first(where: { $0.id == id }),
                      time >= clip.start, time < clip.end else { continue }
                drawDragClip(clip, offX: v.offX, offY: v.offY, scale: clip.scale, rot: clip.rotation)
            }
        } else if let gp = gizmoPreview, let clip = project.overlays.first(where: { $0.id == gp.id }) {
            drawDragClip(clip, offX: gp.offX, offY: gp.offY, scale: gp.scale, rot: gp.rot)
        }

        // Gizmo cho lớp đè đang chọn (+ khung mờ cho các lớp khác trong nhóm).
        if selectedOverlayIDs.count > 1 {
            for id in selectedOverlayIDs where id != selectedOverlayID {
                guard let clip = project.overlays.first(where: { $0.id == id }),
                      time >= clip.start, time < clip.end else { continue }
                let mp = groupGizmoPreview?[id]
                let r = clipViewRect(clip, offX: mp?.offX, offY: mp?.offY)
                NSColor.white.withAlphaComponent(0.5).setStroke()
                let bp = NSBezierPath(rect: r); bp.lineWidth = 1
                bp.setLineDash([4, 3], count: 2, phase: 0); bp.stroke()
            }
        }
        if let clip = selectedClip {
            let gp = gizmoPreview
            let r = clipViewRect(clip, scale: gp?.scale, offX: gp?.offX, offY: gp?.offY)
            drawGizmo(ctx, rect: r, rotDeg: gp?.rot ?? clip.rotation)
        }

        // Vạch an toàn (title-safe 90% / action-safe 93%) — chỉ để canh, không xuất ra video.
        if showSafeArea {
            NSColor.systemGreen.withAlphaComponent(0.55).setStroke()
            for inset in [CGFloat(0.035), CGFloat(0.05)] {
                let r = CGRect(x: viewSize.width * inset, y: viewSize.height * inset,
                               width: viewSize.width * (1 - inset * 2),
                               height: viewSize.height * (1 - inset * 2))
                let p = NSBezierPath(rect: r)
                p.lineWidth = 1; p.setLineDash([5, 4], count: 2, phase: 0); p.stroke()
            }
        }
    }

    /// Năng lượng nhạc hiện tại (0…1, mượt) — cho "Hiệu ứng Bass nền". ĐỘC LẬP với sóng nhạc
    /// (bars) có bật hay không — chỉ cần bật riêng `beatZoomEnabled`.
    private func currentBeatEnergy() -> Float {
        guard project?.backgroundMedia?.beatZoomEnabled == true,
              let ref = project?.audio, let url = AudioLoader.resolveURL(from: ref) else { return 0 }
        return SpectrumStore.energy(for: url, at: karTime)
    }

    /// Vẽ "sóng nhạc" theo audio gốc (lớp dưới hoặc trên chữ tuỳ `spec.aboveText`).
    private func drawVisualizer(_ ctx: CGContext, size: CGSize, above: Bool) {
        guard let spec = currentViz(), spec.enabled, spec.aboveText == above else { return }
        var url: URL?
        if let ref = project?.audio { url = AudioLoader.resolveURL(from: ref) }
        let bands = SpectrumStore.bands(for: url, at: karTime, count: spec.bandCount)
                    ?? [Float](repeating: 0, count: max(4, spec.bandCount))
        VisualizerRenderer.draw(in: ctx, canvasSize: size, spec: spec, bands: bands, flipped: true)

        // Khung kéo (chỉ khi đang kéo hoặc rê chuột lên vùng sóng).
        let showBox = vizDrag != nil || (hoverViz && !above)
        if showBox {
            let r = vizViewRect(spec)
            let path = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            Theme.accentNS.withAlphaComponent(vizDrag != nil ? 0.16 : 0.09).setFill(); path.fill()
            Theme.accentNS.withAlphaComponent(vizDrag != nil ? 0.95 : 0.6).setStroke()
            path.lineWidth = 1.5
            if vizDrag == nil { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
            for cp in cornerPoints(r) {
                let hr = CGRect(x: cp.x - 4, y: cp.y - 4, width: 8, height: 8)
                NSColor.white.setFill(); NSBezierPath(rect: hr).fill()
                Theme.accentNS.setStroke(); let hp = NSBezierPath(rect: hr); hp.lineWidth = 1; hp.stroke()
            }
        }
    }

    /// Cặp mũi nhỏ ↕ cạnh khối chữ — báo "kéo lên/xuống được".
    private func drawUpDownHint(_ c: CGPoint) {
        Theme.accentNS.withAlphaComponent(0.9).setFill()
        let up = NSBezierPath()
        up.move(to: NSPoint(x: c.x, y: c.y - 9))
        up.line(to: NSPoint(x: c.x - 5, y: c.y - 3))
        up.line(to: NSPoint(x: c.x + 5, y: c.y - 3))
        up.close(); up.fill()
        let dn = NSBezierPath()
        dn.move(to: NSPoint(x: c.x, y: c.y + 9))
        dn.line(to: NSPoint(x: c.x - 5, y: c.y + 3))
        dn.line(to: NSPoint(x: c.x + 5, y: c.y + 3))
        dn.close(); dn.fill()
    }

    private func drawGizmo(_ ctx: CGContext, rect r: CGRect, rotDeg: Double) {
        let accent = Theme.accentNS

        // Vạch canh tâm khi đã hít về 0 (vẽ ở hệ view, KHÔNG xoay).
        if let gp = gizmoPreview {
            if gp.offX == 0 {
                NSColor.systemYellow.withAlphaComponent(0.8).setStroke()
                let l = NSBezierPath()
                l.move(to: NSPoint(x: bounds.midX, y: 0)); l.line(to: NSPoint(x: bounds.midX, y: bounds.height))
                l.lineWidth = 1; l.setLineDash([3, 3], count: 2, phase: 0); l.stroke()
            }
            if gp.offY == 0 {
                NSColor.systemYellow.withAlphaComponent(0.8).setStroke()
                let l = NSBezierPath()
                l.move(to: NSPoint(x: 0, y: bounds.midY)); l.line(to: NSPoint(x: bounds.width, y: bounds.midY))
                l.lineWidth = 1; l.setLineDash([3, 3], count: 2, phase: 0); l.stroke()
            }
        }

        let c = CGPoint(x: r.midX, y: r.midY)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: CGFloat(rotDeg) * .pi / 180)
        ctx.translateBy(x: -c.x, y: -c.y)

        // Khung.
        let box = NSBezierPath(rect: r)
        accent.setStroke(); box.lineWidth = 1.5; box.stroke()

        // Cần + tay XOAY (giữa mép trên).
        let stemTop = CGPoint(x: r.midX, y: r.minY - rotateHandleGap)
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: r.midX, y: r.minY)); stem.line(to: NSPoint(x: stemTop.x, y: stemTop.y))
        accent.setStroke(); stem.lineWidth = 1.5; stem.stroke()
        let rr = CGRect(x: stemTop.x - 5, y: stemTop.y - 5, width: 10, height: 10)
        NSColor.white.setFill(); NSBezierPath(ovalIn: rr).fill()
        accent.setStroke(); let rp = NSBezierPath(ovalIn: rr); rp.lineWidth = 1.5; rp.stroke()

        // 4 tay cầm góc.
        for cp in cornerPoints(r) {
            let hr = CGRect(x: cp.x - 4, y: cp.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); NSBezierPath(rect: hr).fill()
            accent.setStroke(); let hp = NSBezierPath(rect: hr); hp.lineWidth = 1; hp.stroke()
        }
        ctx.restoreGState()
    }
}
