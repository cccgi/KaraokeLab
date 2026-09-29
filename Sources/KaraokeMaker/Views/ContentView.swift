import SwiftUI
import AppKit
import AVFoundation
import ImageIO
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
    private var bag = Set<AnyCancellable>()

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
    private var bag = Set<AnyCancellable>()

    init() {
        source.$phase.receive(on: DispatchQueue.main).sink { [weak self] in self?.phase = $0 }.store(in: &bag)
        source.$resultNote.receive(on: DispatchQueue.main).sink { [weak self] in self?.resultNote = $0 }.store(in: &bag)
        source.$listenProgress
            .throttle(for: .seconds(0.3), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.throttledListenProgress = $0 }
            .store(in: &bag)
    }
}

/// Cửa sổ chính — tông tối kiểu phần mềm dựng nhạc.
/// Trên: [panel trái tab] | [preview + thanh phát]
/// Giữa: thanh ĐÁNH DẤU (T) luôn hiện
/// Dưới: timeline chạy hết bề ngang.
struct ContentView: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var colorPresets: ColorPresetStore

    /// Nút "← Thư viện" trên thanh trên (do RootView cấp — 1 thanh duy nhất kiểu CapCut).
    var onExitToLibrary: (() -> Void)? = nil
    var onOpenNewTab: (() -> Void)? = nil
    var trialDays: Int? = nil

    @FocusState private var isNameFieldFocused: Bool
    @FocusState private var textOverlayEditing: Bool

    @State private var showReplaceLinesAlert = false
    @State private var pendingReplace: PendingLineReplace?
    @State private var clearedLyricsBackup: String?
    @State private var lyricsImportNote: String?

    @State private var currentLineIndex = 0
    /// M-C — zoom timeline (points/sec) đưa lên đây để lệnh / menu điều khiển được.
    @State private var timelineZoom: Double = 60
    @State private var timelineViewportW: Double = 800
    @State private var timelineFitTick: Int = 0
    /// Mở project (hay đổi tab) → "Vừa khung" đúng 1 lần khi biết được bề rộng khung nhìn THẬT
    /// (trước đó `timelineViewportW` chỉ là giá trị mặc định 800, chưa phản ánh kích thước panel
    /// thật của user) — khỏi phải tự bấm "Vừa khung" mỗi lần mở lại project.
    @State private var didInitialTimelineFit = false
    /// (2026-09-24) SỬA "Vừa khung" RA SÓNG VUÔNG + THỪA KHOẢNG XÁM: `timelineViewportW` đổi
    /// NHIỀU LẦN liên tiếp lúc mới mở (panel 3 cột còn đang dàn xong) — nếu "Vừa khung" tự động
    /// chốt luôn ở LẦN ĐỔI ĐẦU TIÊN, có thể đang dùng bề rộng TẠM (nhỏ hơn thật), ra zoom quá
    /// thấp (khớp sóng bị vuông/thô) và khung nhìn thật (rộng hơn) thừa mảng xám. Chờ bề rộng
    /// ĐỨNG YÊN (không đổi thêm) một chút rồi mới "Vừa khung" bằng con số CUỐI CÙNG.
    @State private var pendingInitialFitGen = 0
    /// (2026-09-24) SỬA "Import nhạc lần đầu vào project TRỐNG không tự Vừa khung": trước chỉ
    /// tự "Vừa khung" theo `timelineViewportW` đổi — với project MỚI/TRỐNG, bề rộng khung đã
    /// biết (và "chốt" luôn) ngay từ lúc mở, TRƯỚC KHI user import nhạc, nên lúc nhạc thật vào
    /// (đổi `playback.duration` từ 0 → có giá trị) không còn ai gọi lại "Vừa khung" nữa. Theo
    /// dõi THÊM mốc "nhạc vừa có" (độc lập với mốc bề rộng ở trên) — cái nào tới sau thì tự sửa
    /// lại đúng (`timelineFitToWindow()` luôn tính lại từ số MỚI NHẤT, không cộng dồn).
    @State private var didAutoFitForDuration = false
    @State private var pendingDurationFitGen = 0
    /// Clip lớp đè đã chép (⌘C) — để dán (⌘V) tại vạch đỏ.
    @State private var copiedOverlay: OverlayClip?
    @State private var clearedTimingBackup: [LyricLine]?
    @State private var timelineClipboard: [LyricLine] = []
    @State private var timelineSnapBusy = false
    @State private var selectedOverlayID: UUID?
    @State private var selectedOverlayIDs: Set<UUID> = []
    /// Tab đang mở trong bảng sửa lớp chữ.
    @State private var textInspTab: TextInspTab = .content
    /// (U6) Kho media kéo-thả.
    @State private var mediaPoolDropTargeted = false

    /// Dòng vừa bấm T (đã có điểm bắt đầu, chưa có kết thúc) và mốc phải reset nếu quá lâu.
    @State private var pendingTapLine: Int?
    @State private var pendingTapDeadline: TimeInterval?
    private let tapTimeoutSeconds: TimeInterval = 20

    /// Pop-up "Xuất" (kiểu CapCut) — mở từ nút Xuất trên thanh trên, không còn tab Xuất trong inspector.
    @State private var showExportSheet = false
    @State private var previewBackground: PreviewBackground = .dark
    /// Ảnh nền hiện tại (Mode C, kind == .image) — dùng chung Preview + xuất video.
    @State private var backgroundImage: CGImage?
    @State private var bgImageLoadToken: URL?   // ảnh nền đang chờ nạp (chống đua)
    /// URL video nền đã giải được (kind == .video).
    @State private var bgVideoURL: URL?
    /// Chất lượng khung video nền khi xem thử.
    @State private var previewQuality: PreviewQuality = .medium

    /// K1 — canh lời chính xác (forced alignment).
    @ObservedObject private var textPresets = TextLayerPresetStore.shared
    @ObservedObject private var kfClip = KeyframeClipboard.shared
    @StateObject private var aligner = ForcedAligner()
    @State private var alignLyricsInput = ""
    // "Tự động tạo Karaoke — Không cần lời" (Auto Karaoke): đường THỨ HAI sau khi nhập nhạc. Chạy nền; bước cuối gọi CHÍNH hàm canh giờ
    // (`runKaraokeTiming`) mà đường "Có lời" gọi — không có bộ canh giờ mới.
    @StateObject private var autoKaraoke = AutoKaraokeFlow()
    private enum CreateMode { case hasLyrics, noLyrics }
    /// Cách tạo Karaoke đã chọn sau khi nhập nhạc (nil = chưa chọn).
    @State private var createMode: CreateMode?
    /// Từ máy chưa chắc của karaoke tự động, gắn theo dòng đã canh giờ (trong bộ nhớ; hiện ở tab "Sửa lời").
    @State private var autoUncertain: [AutoUncertainWord] = []
    @State private var showSrtPreview = false
    @State private var exportNote: String?
    /// Ảnh chụp project khi bắt đầu kéo slider, để "chốt" một bước undo lúc thả.
    @State private var settingSnapshot: KaraokeProject?

    @StateObject private var videoExporter = TransparentVideoExporter()

    // (2026-09-17) Xem `BeatSepProxy`/`AdvancedKaraokeProxy` ở đầu file — KHÔNG giữ
    // `BeatSeparation`/`AdvancedKaraoke` bằng `@StateObject` trực tiếp nữa (publish tiến độ
    // nhiều lần/giây từng kéo CẢ `ContentView` dựng lại). `beatSep`/`advanced` bên dưới là lối
    // tắt gọi HÀM (KHÔNG đọc thuộc tính đổi liên tục qua đây — đọc qua `beatSepProxy`/`advancedProxy`).
    @StateObject private var beatSepProxy = BeatSepProxy()
    @StateObject private var advancedProxy = AdvancedKaraokeProxy()
    private var beatSep: BeatSeparation { beatSepProxy.source }
    /// Phần "Tạo Karaoke cao cấp" (nghe‑chép giọng hát) — độc lập với các bước cũ.
    private var advanced: AdvancedKaraoke { advancedProxy.source }
    @State private var exportAudioChoice: ExportAudioChoice = .original
    @State private var exportProRes = false
    @AppStorage("kmShowSafeArea") private var showSafeArea = false

    // Song ca / đánh dấu người hát
    @State private var duetMode = false


    /// Âm thanh gắn vào video khi xuất.
    enum ExportAudioChoice: String, CaseIterable, Identifiable {
        case original = "Nhạc gốc (có lời)"
        case beat     = "Chỉ beat (không lời)"
        case none     = "Không tiếng"
        var id: String { rawValue }
    }

    private enum PendingLineReplace {
        case splitFromText
        case srt(lines: [LyricLine], joined: String)
    }

    /// Giây TRONG BÀI tại vạch đỏ = giờ-timeline − mốc clip ★ KARAOKE. Dùng cho MỌI
    /// thao tác gán/đọc timing LỜI (lời lưu theo giây trong bài, không theo timeline).
    private var playheadSongTime: TimeInterval {
        max(0, playback.currentTime - store.project.karaokeClipStart)
    }

    private var activeLineIndex: Int? {
        TimingEditor.activeIndex(store.project.lines, at: playheadSongTime)
    }

    /// Có dòng nào đang ghi dở (bắt đầu rồi, chưa có kết thúc) không.
    private var hasRecordingLine: Bool {
        store.project.lines.contains { $0.start != nil && $0.end == nil }
    }

    // MARK: - Bố cục

    var body: some View {
        mainLayout
        .frame(minWidth: 1380, minHeight: 780)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onWindowKeyDown(handleKeyDown)
        .dismissesTextEditingOnOutsideClick()
        .focusedSceneValue(\.editorCommands, EditorCommandSink(
            run: { runCommand($0) },
            canRun: { canRun($0) },
            selection: editorSelection,
            linesEmpty: store.project.lines.isEmpty,
            hasCopiedOverlay: copiedOverlay != nil))
        .onAppear {
            DispatchQueue.main.async { endNameEditing() }
            reloadBackgroundImage()
            // Karaoke đã có timing → mở thẳng tab "Chỉnh sửa" (project làm xong rồi thì
            // không lý gì mặc định vào bước "Tạo Karaoke" nữa).
            if store.project.hasAnyTiming { leftPanelTab = .background }
            // (U1/U7) Lần đầu vào màn làm việc (từ Home, hay đổi tab dự án) — nạp lại audio
            // ĐÚNG project đang mở, dù `playback` là 1 instance DÙNG CHUNG cho mọi tab
            // (so trực tiếp với audio CỦA PROJECT NÀY, không qua `resolvedAudioURL` vì nó
            // ưu tiên trả `playback.loadedURL` cũ — sẽ luôn "khớp" nhầm lúc vừa đổi tab).
            let wantURL = store.project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
            if playback.loadedURL != wantURL {
                syncPlaybackWithProject()
            } else {
                // Audio đã đúng nhưng vào lại editor → vẫn quét cache beat/vocal của bài này
                // (nếu không nút "Karaoke BẬT/TẮT" hiện disable dù đã tách trước đó).
                adoptOrRefreshBeatSep(for: wantURL)
            }
            syncAudioSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: ColorPipeline.hdrNote)) { _ in
            store.lastError = L("Ảnh/Video HDR — đã hạ về SDR để hiển thị & xuất.")
        }
        .onChange(of: store.project.audioTrimStart) { _ in syncAudioSettings() }
        .onChange(of: store.project.audioTrimEnd) { _ in syncAudioSettings() }
        .onChange(of: store.project.audioGain) { _ in syncAudioSettings() }
        .onChange(of: store.project.audioMuted) { _ in syncAudioSettings() }
        .onChange(of: store.project.karaokeClipStart) { _ in syncAudioSettings() }
        .onChange(of: store.project.backgroundMedia?.lastKnownPath) { _ in
            reloadBackgroundImage()
        }
        .onChange(of: store.project.lines.count) { _ in
            currentLineIndex = min(currentLineIndex, max(store.project.lines.count - 1, 0))
        }
        .onChange(of: timelineViewportW) { _ in
            // Lần đầu biết bề rộng khung nhìn THẬT (không còn là giá trị mặc định 800) sau khi mở
            // project/đổi tab → tự "Vừa khung" luôn, khỏi phải tự bấm nút. Debounce: chờ bề rộng
            // hết đổi (panel dàn xong) rồi mới chốt, tránh dùng số TẠM lúc layout chưa ổn định.
            guard !didInitialTimelineFit else { return }
            pendingInitialFitGen &+= 1
            let gen = pendingInitialFitGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard gen == pendingInitialFitGen, !didInitialTimelineFit else { return }
                didInitialTimelineFit = true
                timelineFitToWindow()
            }
        }
        .onChange(of: playback.duration) { newDur in
            // Import nhạc lần đầu vào project TRỐNG (bề rộng khung đã "chốt" từ trước lúc chưa
            // có nhạc) → mốc RIÊNG cho lúc nhạc thật vào, debounce y hệt bên trên.
            guard !didAutoFitForDuration, newDur > 0.1 else { return }
            pendingDurationFitGen &+= 1
            let gen = pendingDurationFitGen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard gen == pendingDurationFitGen, !didAutoFitForDuration else { return }
                didAutoFitForDuration = true
                timelineFitToWindow()
            }
        }
        .onChange(of: playback.isPlaying) { playing in
            if !playing { clearPendingTap() }
            PerfMonitor.shared.note = playing ? "phát" : "rảnh"
        }
        .onChange(of: beatSepProxy.beatURL) { url in
            // Beat vừa có (tạo karaoke xong / up stems) & đang BẬT → chuyển sang phát beat.
            if let url, karaokeOn, playback.isLoaded {
                playback.swapSource(to: url)
            }
            // Beat biến mất (đổi bài, bỏ stems…) → về bài gốc (giữ nút BẬT cho lần sau).
            if url == nil, let orig = projectAudioURL, playback.loadedURL != orig {
                playback.swapSource(to: orig)
            }
            syncStemRefsIntoProject()
        }
        .onChange(of: beatSepProxy.vocalURL) { _ in syncStemRefsIntoProject() }
    }

    /// Vocal/beat vừa tách xong (hoặc lấy từ cache máy này) → LƯU LUÔN vào project — để
    /// `store.save()` gói cả 2 file này vào project (`materializeMedia`), mở ở máy khác khỏi
    /// phải tách lại từ đầu. Không qua `store.perform/edit` (không cần undo cho việc này),
    /// chỉ đánh dấu `markDirty()` để không quên lưu.
    private func syncStemRefsIntoProject() {
        var changed = false
        if let v = beatSepProxy.vocalURL {
            let ref = AudioLoader.makeReference(for: v)
            if store.project.vocalStem?.lastKnownPath != ref.lastKnownPath { store.project.vocalStem = ref; changed = true }
        }
        if let b = beatSepProxy.beatURL {
            let ref = AudioLoader.makeReference(for: b)
            if store.project.beatStem?.lastKnownPath != ref.lastKnownPath { store.project.beatStem = ref; changed = true }
        }
        if changed { store.markDirty() }
    }

    // MARK: - Bố cục chính

    private var mainLayout: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            VSplitView {
                HSplitView {
                    leftPanel
                        .frame(minWidth: 430, idealWidth: 720, maxWidth: 900)
                        .clipped()
                    centerColumn
                        .frame(minWidth: 460, maxWidth: .infinity)
                        .layoutPriority(1)
                        .clipped()
                    inspectorColumn
                        .frame(minWidth: 360, idealWidth: 450, maxWidth: 560)
                        .clipped()
                }
                .frame(minHeight: 280, maxHeight: .infinity)

                VStack(spacing: 0) {
                    syncBar
                    Divider()
                    timelineArea
                }
                .frame(minHeight: 300, idealHeight: 520, maxHeight: 820, alignment: .top)
                .clipped()
            }

            errorBar
        }
        .background(
            PlaybackTicks(
                isPlaying: playback.isPlaying,
                canFollow: pendingTapLine == nil,
                lines: store.project.lines,
                currentLineIndex: Binding(get: { currentLineIndex }, set: { currentLineIndex = $0 }),
                onSecond: { t in
                    store.lastPreviewTime = max(0, t - store.project.karaokeClipStart)   // t = giờ-timeline
                    checkPendingTapTimeout()
                }
            )
        )
        .sheet(isPresented: $showExportSheet) { exportSheet }
    }

    /// Pop-up "Xuất" (kiểu CapCut) — SRT / ASS / nền / video, mở từ nút Xuất trên thanh trên.
    private var exportSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent)
                Text(L("Xuất")).font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Button(L("Đóng")) { showExportSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Metric.pad)
            Divider().overlay(Theme.stroke)
            ScrollView { exportTabContent.padding(Theme.Metric.pad + 2) }
        }
        .frame(width: 580, height: 660)
        .background(Theme.panel)
    }

    /// Dòng gần nhất với mốc thời gian `t` (để tua wave thì danh sách cuộn theo).
    private func lineIndexNearestTime(_ t: TimeInterval) -> Int {
        let lines = store.project.lines
        guard !lines.isEmpty else { return 0 }

        if let inside = lines.firstIndex(where: { l in
            guard let s = l.start, let e = l.end else { return false }
            return t >= s && t < e
        }) { return inside }

        let before = lines.indices
            .filter { lines[$0].isTimed && (lines[$0].start ?? 0) <= t }
            .max(by: { (lines[$0].start ?? 0) < (lines[$1].start ?? 0) })
        if let last = before {
            let next = last + 1
            if lines.indices.contains(next), !lines[next].isTimed { return next }
            return last
        }
        return TimingEditor.firstUntimedIndex(lines) ?? 0
    }

    /// Tua tới `t`: đưa con trỏ dòng theo, huỷ đồng hồ tự-reset.
    private func seekTo(_ t: TimeInterval) {
        playback.seek(to: t)
        let songT = max(0, t - store.project.karaokeClipStart)   // t = giờ-timeline
        store.lastPreviewTime = songT
        currentLineIndex = clampedIndex(lineIndexNearestTime(songT))
        clearPendingTap()
    }

    // MARK: - Tự reset câu bấm T dở dang

    private func checkPendingTapTimeout() {
        guard playback.isPlaying,
              let line = pendingTapLine,
              let deadline = pendingTapDeadline,
              playback.currentTime >= deadline,
              store.project.lines.indices.contains(line),
              store.project.lines[line].start != nil,
              store.project.lines[line].end == nil else { return }

        store.perform(L("Tự reset câu bấm T dở dang")) {
            TimingEditor.clear(lines: &store.project.lines, at: line)
        }
        currentLineIndex = line
        clearPendingTap()
    }

    private func clearPendingTap() {
        pendingTapLine = nil
        pendingTapDeadline = nil
    }

    @ViewBuilder
    private var errorBar: some View {
        if let error = store.lastError ?? playback.lastError ?? videoExporter.lastError {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).font(.callout).foregroundStyle(.red)
                Spacer()
                Button(L("Ẩn")) { store.lastError = nil; playback.clearError() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.panelAlt)
        }
    }

    // MARK: - Thanh công cụ trên

    private var toolbar: some View {
        HStack(spacing: Theme.Metric.gap) {
            // ← về Thư viện (do RootView cấp)
            if let back = onExitToLibrary {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkDim)
                .help(L("Về Thư viện"))
                Divider().frame(height: 16).overlay(Theme.stroke)
            }

            // (Thao tác Tệp: Dự án mới / Mở / Lưu / Lưu thành → nằm ở menu bar "File".)

            Button { store.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).foregroundStyle(store.undoManager.canUndo ? Theme.inkDim : Theme.inkDim.opacity(0.35))
                .disabled(!store.undoManager.canUndo).help(L("Hoàn tác (⌘Z)"))
            Button { store.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).foregroundStyle(store.undoManager.canRedo ? Theme.inkDim : Theme.inkDim.opacity(0.35))
                .disabled(!store.undoManager.canRedo).help(L("Làm lại (⇧⌘Z)"))

            Divider().frame(height: 16).overlay(Theme.stroke)

            TextField(L("Tên dự án"), text: Binding(
                get: { store.project.name },
                set: { store.project.name = $0; store.markDirty() }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: 240)
            .focused($isNameFieldFocused)
            .onSubmit { endNameEditing() }
            .onChange(of: isNameFieldFocused) { focused in
                if focused { settingSnapshot = store.project }
                else if let snapshot = settingSnapshot {
                    store.commit(from: snapshot, name: L("Đổi tên dự án")); settingSnapshot = nil
                }
            }

            if store.hasUnsavedChanges {
                Circle().fill(.orange).frame(width: 5, height: 5)
            }

            Spacer()

            if let days = trialDays { TrialBanner(daysRemaining: days) }

            // Cụm nút phải — cùng kiểu XANH nổi bật như "Xuất".
            Group {
                if let newTab = onOpenNewTab {
                    Button(action: newTab) {
                        Label(L("Dự án mới"), systemImage: "plus").font(.system(size: 13, weight: .semibold))
                    }
                    .help(L("Mở project mới trong tab khác"))
                }
                Button { openProjectFromPanel() } label: {
                    Label(L("Mở"), systemImage: "folder").font(.system(size: 13, weight: .semibold))
                }
                .help(L("Mở project…"))
                Button { saveProject() } label: {
                    Label(L("Lưu"), systemImage: "square.and.arrow.down.on.square").font(.system(size: 13, weight: .semibold))
                }
                .help(L("Lưu (⌘S)"))
                Button { saveProjectAs() } label: {
                    Label(L("Lưu thành"), systemImage: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                }
                .help(L("Lưu thành…"))
                Button { showExportSheet = true } label: {
                    HStack(spacing: 6) {
                        if videoExporter.isExporting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(videoExporter.isExporting ? L("Đang xuất…") : L("Xuất"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .help(L("Xuất video / SRT / ASS"))
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.regular)
        }
        .padding(.horizontal, Theme.Metric.pad)
        .frame(height: Theme.Metric.topbarH)
        .background(Theme.panelAlt)
        // Đổi project TRONG CÙNG tab (Mở / Dự án mới) hoặc rời tab → huỷ luồng tự động, bỏ lời/mốc giờ đang dở:
        // kết quả của project A không bao giờ lọt vào project B.
        .onChange(of: store.projectSessionID) { _ in
            autoKaraoke.cancel(); createMode = nil; autoUncertain = []
        }
        .onDisappear { autoKaraoke.cancel() }
        #if KM_GUITEST
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("KMGUITest.toggleKaraoke"))) { _ in toggleKaraoke() }
        #endif
    }

    // MARK: - Tự động tạo Karaoke (Không cần lời)

    /// Bản tách giọng hát của project: ưu tiên tham chiếu LƯU TRONG project, rồi tới bản vừa tách (proxy). Chỉ dùng để dò chỗ có giọng hát.
    private var autoLyricsVocalURL: URL? {
        let fm = FileManager.default
        if let v = store.project.vocalStem.flatMap(AudioLoader.resolveURL(from:)), fm.fileExists(atPath: v.path) { return v }
        guard projectAudioURL != nil, let v = beatSepProxy.vocalURL, fm.fileExists(atPath: v.path) else { return nil }
        return v
    }

    /// FULL MIX của CHÍNH project này (file gốc). KHÔNG dùng `playback.loadedURL`/`resolvedAudioURL`: nó có thể đang là bản BEAT
    /// (khi bật Karaoke) hoặc còn sót nhạc của project trước → sẽ nhận dạng nhầm bản nhạc không lời/bài khác.
    private var autoLyricsAudioURL: URL? {
        guard let u = projectAudioURL, FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// Nối luồng tự động với project + các bước SẴN CÓ của app (tách giọng, canh giờ).
    private func configureAutoKaraoke() {
        autoKaraoke.hooks = AutoKaraokeHooks(
            projectSession: { store.projectSessionID },
            sourceAudio: { autoLyricsAudioURL },
            vocalStem: { autoLyricsVocalURL },
            analyzeMusic: { await analyzeMusicForAutoKaraoke() },
            createKaraoke: { lyrics, shouldApply in
                guard let audio = autoLyricsAudioURL else { return .failure(L("Chưa có file nhạc.")) }
                // Cùng hàm, cùng tham số như đường "Có lời" (chất lượng nhanh mặc định của nút "Tạo nhanh Karaoke").
                return await runKaraokeTiming(audio: audio, lyrics: lyrics, quality: .fast, origin: .auto, shouldApply: shouldApply)
            },
            currentLines: { store.project.lines },
            karaokeCreated: { unc in autoUncertain = unc })
    }

    /// "Phân tích nhạc" = bước tách giọng SẴN CÓ (không thêm bộ tách mới). Chờ nếu đang có 1 lượt tách khác.
    private func analyzeMusicForAutoKaraoke() async -> URL? {
        guard let src = autoLyricsAudioURL else { return nil }
        while beatSep.isRunning { try? await Task.sleep(nanoseconds: 300_000_000) }
        return await beatSep.separateLocal(source: src)?.vocal
    }

    private func startAutoKaraoke() {
        configureAutoKaraoke()
        autoKaraoke.start()
    }

    /// Chuyển sang đường "Có lời" KHÔNG cần nhập lại nhạc; lời máy đã nhận dạng (nếu có) được điền sẵn vào ô lời khi ô đang trống.
    private func switchToManualLyrics(prefill: String?) {
        autoKaraoke.cancel()
        if let p = prefill, alignLyricsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { alignLyricsInput = p }
        createMode = .hasLyrics
    }

    /// Từ chưa chắc còn hiệu lực: dòng còn tồn tại và từ ở vị trí đó vẫn là từ máy đã ghi (user chưa sửa).
    private var validAutoUncertain: [AutoUncertainWord] {
        autoUncertain.filter { u in
            guard let line = store.project.lines.first(where: { $0.id == u.lineID }) else { return false }
            let t = UncertaintyMapper.tokens(line.text)
            return t.indices.contains(u.wordIndex) && UncertaintyMapper.norm(t[u.wordIndex]) == UncertaintyMapper.norm(u.original)
        }
    }

    /// Chọn phương án cho 1 từ chưa chắc: thay đúng từ đó (GIỮ mốc giờ của từ bị thay, 1 bước hoàn tác) rồi bỏ khỏi danh sách.
    private func applyUncertainAlternative(_ u: AutoUncertainWord, _ alt: String) {
        guard let i = store.project.lines.firstIndex(where: { $0.id == u.lineID }),
              let newText = UncertaintyMapper.replacingWord(in: store.project.lines[i].text, at: u.wordIndex, with: alt) else { return }
        commitLyricEdit(u.lineID, newText)
        autoUncertain.removeAll { $0.id == u.id }
    }

    /// "Vừa khung" — đặt zoom sao cho TOÀN BỘ timeline lọt viewport (khớp ĐÚNG công thức
    /// `TimelineEditor.duration` để không thừa/thiếu) rồi kéo về đầu.
    private func timelineFitToWindow() {
        let k = max(0, store.project.karaokeClipStart)
        let overlayEnd = (store.project.overlays.map(\.end).max() ?? 0) + 10
        let lineEnd = (store.project.lines.compactMap(\.end).max() ?? 0) + k + 10
        let dur = max(playback.duration + k, overlayEnd, lineEnd, 60)
        let vw = max(timelineViewportW, 200)
        // CHO PHÉP zoom xuống rất thấp — bài dài 4' vẫn phải LỌT TRỌN khung (min 8 cũ = luôn thiếu ~20s).
        timelineZoom = min(400, max(1.5, (vw - 6) / dur))
        timelineFitTick &+= 1          // canh cho canvas kéo scroll về x=0
    }

    private func openProjectFromPanel() {
        if let url = FilePanels.chooseProjectToOpen() {
            store.open(from: url); syncPlaybackWithProject()
        }
    }
    private func saveProject() {
        if store.save() == false,
           let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
            store.save(to: url)
        }
    }
    private func saveProjectAs() {
        if let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
            store.save(to: url)
        }
    }

    // MARK: - Panel trái: Lời

    private enum LeftPanelTab: Hashable { case steps, background, lyrics, text, visualizer, files }
    @State private var leftPanelTab: LeftPanelTab = .steps

    /// Nút tab cột trái — kiểu "rail" CapCut: icon trên, nhãn dưới, ô chọn có nền + gạch nhấn.
    /// `done` (chỉ "Tạo Karaoke") → chấm xanh lá báo bước đã xong.
    @ViewBuilder
    private func leftTabButton(_ title: String, icon: String, tab: LeftPanelTab, done: Bool) -> some View {
        let selected = leftPanelTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { leftPanelTab = tab }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 17, weight: .regular))
                    if done {
                        Circle().fill(Color.green).frame(width: 6, height: 6).offset(x: 5, y: -3)
                    }
                }
                Text(L(title)).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Theme.accent : Theme.inkDim)
            .background(RoundedRectangle(cornerRadius: Theme.Metric.radiusSm)
                .fill(selected ? Theme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leftPanel: some View {
        VStack(spacing: 0) {
            // (U6) Kho media giờ là 1 KHU RIÊNG, chiếm hết chiều cao khi mở — không còn
            // nhét vừa trong 1 thẻ nhỏ của bước 3 (đúng góp ý: cần giống hẳn 1 "kho" thật,
            // không phải 1 mục cài đặt).
            HStack(spacing: 4) {
                // "Tạo Karaoke" chỉ còn khi CHƯA có dòng canh xong (hoặc đang đứng ở đó lúc vừa xong, tới
                // khi tự chuyển sang "Nền video") — xong bước này là hết quay lại; mở lại project cũng vậy.
                if showStepsTab {
                    leftTabButton("Tạo Karaoke", icon: "sparkles", tab: .steps, done: aiLinesTimed)
                }
                leftTabButton("Nền video", icon: "photo", tab: .background, done: false)
                if aiLinesTimed {
                    leftTabButton("Sửa lời", icon: "text.alignleft", tab: .lyrics, done: false)
                }
                leftTabButton("Thêm text", icon: "textformat", tab: .text, done: false)
                leftTabButton("Sóng nhạc", icon: "waveform", tab: .visualizer, done: false)
                leftTabButton("Media", icon: "folder", tab: .files, done: false)
            }
            .padding(Theme.Metric.gap)

            Divider().overlay(Theme.stroke)

            switch leftPanelTab {
            case .files:
                filesPanel
            case .steps:
                ScrollViewReader { proxy in
                    ScrollView {
                        aiStepsPanel
                            .padding(Theme.Metric.pad)
                    }
                    .onChange(of: aiAudioOK) { ok in
                        // Nhập audio xong → tự cuộn lên phần dán lời (thấy nút Tạo Karaoke).
                        guard ok else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("lyricsStep", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: alignPhase) { phase in
                        switch phase {
                        case .separating, .aligning:
                            // Vừa bấm tạo karaoke → cuộn xuống cho thấy tiến trình đang chạy.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo("aiProgress", anchor: .center)
                                }
                            }
                        case .done:
                            // Xong → tự nhảy sang tab "Chỉnh sửa" + "Vừa khung" cho thấy trọn bài.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                // Karaoke tự động có từ máy chưa chắc → mở thẳng "Sửa lời" để xem/sửa; ngược lại như cũ.
                                withAnimation { leftPanelTab = validAutoUncertain.isEmpty ? .background : .lyrics }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                timelineFitToWindow()
                            }
                        case .idle:
                            break
                        }
                    }
                }
            case .lyrics:
                LyricEditPanel(currentLineIndex: currentLineIndex,
                               onFocusLine: focusLyricLine,
                               onCommit: commitLyricEdit,
                               uncertain: validAutoUncertain,
                               onApplyAlternative: applyUncertainAlternative,
                               onDismissUncertain: { u in autoUncertain.removeAll { $0.id == u.id } })
            case .background:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                        subCard("Nền video") { backgroundSourceContent }
                    }
                    .padding(Theme.Metric.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.02))
            case .text:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                        subCard("Thêm text") { textLayerPanel }
                    }
                    .padding(Theme.Metric.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.02))
            case .visualizer:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                        subCard("Sóng nhạc") { visualizerPanel }
                    }
                    .padding(Theme.Metric.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.02))
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .onChange(of: aiLinesTimed) { timed in
            if timed {
                // Có dòng canh xong mà đang đứng ở "Tạo Karaoke" NGOÀI luồng tạo karaoke (luồng đó tự
                // chuyển sau 0.3s để kịp thấy dấu "xong"): nhập SRT/ASS, làm lại ⇧⌘Z… → rời sang "Nền video".
                if leftPanelTab == .steps, alignPhase == .idle { leftPanelTab = .background }
            } else if leftPanelTab == .lyrics {
                leftPanelTab = .steps                       // ⌘Z lùi về trước lúc tạo → tab "Sửa lời" biến mất
            }
        }
        .onChange(of: store.fileURL) { _ in
            if leftPanelTab == .steps, aiLinesTimed { leftPanelTab = .background }   // mở project khác ngay trong editor
        }
        .alert(L("Thay toàn bộ dòng lời?"), isPresented: $showReplaceLinesAlert) {
            Button(L("Huỷ"), role: .cancel) { pendingReplace = nil }
            Button(L("Thay & xoá timing"), role: .destructive) { performPendingReplace() }
        } message: {
            Text(L("Một số dòng đã có timing. Thao tác này tạo danh sách dòng mới và xoá timing hiện có."))
        }
    }

    /// Tab "Chỉnh sửa" — nền video + sóng nhạc. (Kho file tách sang tab "File của bạn".)
    @ViewBuilder
    private var mediaLibraryPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                subCard("Nền video") { backgroundSourceContent }
                subCard("Chữ / Text") { textLayerPanel }
                subCard("Sóng nhạc") { visualizerPanel }
            }
            .padding(Theme.Metric.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
    }

    /// Ô "Chữ / Text" ở panel trái — thêm lớp chữ (như lớp ảnh).
    private var textLayerPanel: some View {
        let textClips = store.project.overlays.filter { $0.kind == .text }
        return VStack(alignment: .leading, spacing: 7) {
            Button { addTextOverlay() } label: {
                Label(L("Thêm 1 lớp chữ"), systemImage: "textformat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.regular)
            .onDrag { NSItemProvider(object: Self.newTextDragToken as NSString) }

            Text(L("Bấm để thêm ở vạch đỏ, hoặc KÉO nút này thả xuống làn lớp đè trên timeline. Lớp chữ hoạt động như lớp ảnh: kéo–giãn–xoay trên màn hình xem trước, chỉnh bên phải."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !textClips.isEmpty {
                Divider()
                ForEach(textClips) { clip in
                    Button { selectedOverlayID = clip.id } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "textformat").font(.caption2).foregroundStyle(Theme.accent)
                            Text(clip.text.isEmpty ? L("(trống)") : clip.text)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if selectedOverlayID == clip.id {
                                Image(systemName: "checkmark").font(.caption2).foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Tab "Media" — kho ảnh / video / nhạc, kéo xuống timeline. Chỉ 1 ô "+ Nhập file" —
    /// bấm hay thả file vào bất kỳ đâu trong ô đều nhập được (đúng kiểu user tham khảo).
    @ViewBuilder
    private var filesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.gap) {
                mediaImportBox
                if !store.project.mediaPool.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 12)], spacing: 14) {
                        ForEach(store.project.mediaPool) { item in
                            mediaPoolThumb(item, size: 96)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(Theme.Metric.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
    }

    /// Ô "+ Nhập file" — khi kho TRỐNG thì chiếm cả khu (giống ảnh tham khảo), khi đã có
    /// file thì co lại thành 1 thanh gọn phía trên lưới. Bấm HOẶC thả file (ảnh/video/nhạc)
    /// vào bất kỳ đâu trong ô đều nhập được.
    private var mediaImportBox: some View {
        let empty = store.project.mediaPool.isEmpty
        return Button { importMediaPoolImages() } label: {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                    Text(L("Nhập file")).font(.system(size: 15, weight: .bold))
                }
                Text(L("Kéo và thả video, ảnh, nhạc vào đây"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, empty ? 90 : 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Theme.Metric.radius)
            .fill(mediaPoolDropTargeted ? Theme.accent.opacity(0.10) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius)
            .strokeBorder(mediaPoolDropTargeted ? Theme.accent : Theme.stroke,
                          style: StrokeStyle(lineWidth: 1.5, dash: mediaPoolDropTargeted ? [] : [5, 4])))
        .onDrop(of: ["public.file-url"], isTargeted: $mediaPoolDropTargeted) { handleMediaPoolFileDrop($0) }
    }

    private var linesList: some View {
        LyricLinesList(
            currentLineIndex: currentLineIndex,
            onSelect: { currentLineIndex = $0 },
            onSeekToLineStart: seekToLineStart,
            onClearLine: clearLine,
            onClearAll: clearAllTiming,
            canUndoClearAll: clearedTimingBackup != nil,
            onUndoClearAll: restoreClearedTiming,
            onSetText: setLineText,
            onSetStart: { setLineStartTime($0, $1) },
            onSetEnd: { setLineEndTime($0, $1) },
            onNudgeStart: { nudgeStart($0, $1) },
            onNudgeEnd: { nudgeEnd($0, $1) },
            onStartToPlayhead: { setStartToPlayhead($0) },
            onEndToPlayhead: { setEndToPlayhead($0) }
        )
    }

    // MARK: - Cột trái: các bước

    private var aiAudioOK: Bool { playback.isLoaded }
    private var aiLyricsOK: Bool { !store.project.rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var aiLinesOK: Bool { !store.project.lines.isEmpty }
    private var aiLinesTimed: Bool { store.project.lines.contains { $0.isTimed } }
    /// Chỉ cần bước "Tách dòng" khi gõ lời tay (chưa có dòng có sẵn mốc từ SRT).
    private var aiNeedsSplit: Bool { !aiLinesTimed }

    @State private var audioDropTargeted = false
    @State private var userBeatURL: URL?
    @State private var userVocalURL: URL?
    @State private var beatDropTargeted = false
    @State private var vocalDropTargeted = false
    private enum StemSlot { case beat, vocal }
    private enum AudioInputMode: String, CaseIterable, Identifiable {
        case whole = "Cả bài nhạc", stems = "Beat + Vocal riêng"
        var id: String { rawValue }
    }
    @State private var audioInputMode: AudioInputMode = .whole

    @ViewBuilder
    private var stepAudioContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if aiAudioOK {
                HStack(spacing: 8) {
                    Image(systemName: beatSepProxy.usingUserStems ? "waveform.path.badge.plus" : "music.note")
                        .foregroundStyle(.secondary)
                    Text(beatSepProxy.usingUserStems
                         ? L("Beat + Vocal của bạn")
                         : (playback.loadedURL?.lastPathComponent ?? store.project.audio?.fileName ?? "—"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Đổi")) { resetAudioInput() }.controlSize(.small)
                }
            } else if store.project.audio != nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(L("Không tìm thấy file nhạc")).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(L("Chọn lại…")) { importAudio() }.controlSize(.small)
                }
            } else {
                Text(L("Bạn có bài nhạc, hay có sẵn Beat + Vocal riêng?"))
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $audioInputMode) {
                    ForEach(AudioInputMode.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch audioInputMode {
                case .whole: wholeAudioInput
                case .stems: stemsInput
                }
            }
        }
    }

    @ViewBuilder
    private var wholeAudioInput: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.secondary)
            Button(L("Chọn file nhạc (MP3 / WAV)…")) { importAudio() }
                .buttonStyle(.borderedProminent)
            Text(L("…hoặc kéo file nhạc từ Finder thả vào đây."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(audioDropTargeted ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(audioDropTargeted ? Theme.accent : Theme.strokeStrong))
        .onDrop(of: ["public.file-url"], isTargeted: $audioDropTargeted) { handleAudioDrop($0) }
    }

    @ViewBuilder
    private var stemsInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            stemDropRow("🥁  Beat (không lời)", url: $userBeatURL,
                        targeted: $beatDropTargeted, slot: .beat)
            stemDropRow("🎤  Vocal (chỉ giọng)", url: $userVocalURL,
                        targeted: $vocalDropTargeted, slot: .vocal)
            if userBeatURL != nil, userVocalURL != nil {
                Button(beatSepProxy.isRunning ? L("Đang xử lý…") : L("Dùng 2 file này")) { adoptStems() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(beatSepProxy.isRunning)
            }
        }
    }

    /// Xoá nguồn nhạc hiện tại → quay lại màn hình chọn "Cả bài / Beat + Vocal".
    private func resetAudioInput() {
        audioInputMode = beatSepProxy.usingUserStems ? .stems : .whole
        beatSep.clearUserStems()
        userBeatURL = nil; userVocalURL = nil
        playback.unload()
        if store.project.audio != nil {
            store.perform(L("Bỏ nhạc")) { store.project.audio = nil }
        }
        karaokeOn = false
    }

    @ViewBuilder
    private func stemDropRow(_ title: String, url: Binding<URL?>,
                             targeted: Binding<Bool>, slot: StemSlot) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.caption.weight(.medium))
                Text(url.wrappedValue?.lastPathComponent ?? L("kéo file vào, hoặc bấm Chọn"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if url.wrappedValue != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Button(L("Chọn…")) {
                if let u = FilePanels.chooseAudioToImport() { url.wrappedValue = u }
            }.controlSize(.small).disabled(beatSepProxy.usingUserStems)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(targeted.wrappedValue ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(targeted.wrappedValue ? Theme.accent : Theme.stroke))
        .onDrop(of: ["public.file-url"], isTargeted: targeted) { handleStemDrop($0, into: slot) }
    }

    private func handleStemDrop(_ providers: [NSItemProvider], into slot: StemSlot) -> Bool {
        guard !beatSepProxy.usingUserStems,
              let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") })
        else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                switch slot {
                case .beat:  userBeatURL = url
                case .vocal: userVocalURL = url
                }
            }
        }
        return true
    }

    private func adoptStems() {
        guard let b = userBeatURL, let v = userVocalURL else { return }
        Task {
            guard let mix = await beatSep.adoptUserStems(beat: b, vocal: v) else { return }
            let ref = AudioLoader.makeReference(for: mix)
            store.perform(L("Dùng beat + vocal")) {
                store.project.audio = ref
                if store.project.name == "Untitled" {
                    store.project.name = v.deletingPathExtension().lastPathComponent
                }
            }
            playback.load(url: mix)
        }
    }

    // MARK: Cột trái — các bước tạo karaoke

    private var aiStepsPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Tạo Karaoke bằng AI")).font(.title3.bold())

            stepBlock(1, "Nhập file audio", done: aiAudioOK) { stepAudioContent }

            // ② Dán lời → tách nhạc + canh giờ → timeline.
            // ② Chọn cách tạo Karaoke: CÓ LỜI (dán/nhập lời → canh giờ) hoặc KHÔNG CẦN LỜI (máy tự nhận dạng + tự canh giờ).
            if aiAudioOK {
                stepBlock(2, createMode == nil ? "Chọn cách tạo Karaoke" : (createMode == .hasLyrics ? "Dán lời & tạo karaoke" : "Tự động tạo Karaoke"),
                          done: aiLinesOK) {
                    createModeContent
                }
                .id("lyricsStep")
            }
            // Bước 3 "chọn nền" đã bỏ — nền / sóng nhạc / ảnh đè giờ ở tab "Kho media".
        }
    }

    @State private var aiLinesListExpanded = false

    /// Tiến trình 2 chặng của bước "Dán lời & tạo karaoke".
    enum AlignPhase { case idle, separating, aligning, done }
    @State private var alignPhase: AlignPhase = .idle

    /// Mục sổ xuống theo đúng kiểu các nhóm trong panel "Kiểu chữ"
    /// (bấm vào cả hàng tiêu đề để mở/đóng, không chỉ mũi tên).
    @ViewBuilder
    private func collapsibleSection<C: View>(
        _ title: String, expanded: Binding<Bool>, @ViewBuilder _ content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(title).font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue { content() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
    }

    /// Nội dung bước ②: 2 lựa chọn RÕ RÀNG rồi mới tới đường đã chọn (không gộp chung 1 trang nhập lời).
    @ViewBuilder
    private var createModeContent: some View {
        if createMode == nil {
            createModeChooser
        } else {
            Button { createMode = nil; autoKaraoke.reset() } label: { Label(L("Đổi cách tạo"), systemImage: "chevron.left") }
                .controlSize(.small).disabled(autoKaraoke.isRunning)
            if createMode == .hasLyrics {
                forcedAlignStep
            } else {
                AutoKaraokePanel(flow: autoKaraoke,
                                 analysisProgress: beatSepProxy.throttledProgress,
                                 timingProgress: advancedProxy.throttledListenProgress,
                                 onStart: { startAutoKaraoke() },
                                 onRetryTiming: { autoKaraoke.retryTiming() },
                                 onCancel: { autoKaraoke.cancel() },
                                 onManual: { switchToManualLyrics(prefill: $0) })
            }
        }
    }

    private var createModeChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Bạn muốn tạo Karaoke theo cách nào?")).font(.caption2).foregroundStyle(.secondary)
            // Nút 1 dòng (nút hệ thống) + mô tả ngay dưới — không nhồi 2 dòng vào nút (bị cắt chữ).
            Button { createMode = .hasLyrics } label: { choiceTitle(icon: "text.alignleft", L("Tôi có lời bài hát")) }
                .buttonStyle(.bordered).controlSize(.large)
            Text(L("Dán hoặc nhập lời — máy tự canh giờ.")).font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Button { createMode = .noLyrics; startAutoKaraoke() } label: { choiceTitle(icon: "wand.and.stars", L("Không cần lời — Tự động tạo Karaoke")) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            Text(L("Máy tự nghe, viết lời rồi canh giờ.")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func choiceTitle(icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var forcedAlignStep: some View {
        Text(L("Dán lời theo thứ tự hát, mỗi câu 1 dòng. Cách các đoạn (phiên khúc, điệp khúc, đoạn cầu…) bằng MỘT dòng trống. Đoạn nào hát lại chỉ cần viết MỘT lần — máy tự tìm và nhân bản cho đủ."))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextEditor(text: $alignLyricsInput)
            .font(.body).frame(minHeight: 190, maxHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.strokeStrong))

        HStack(spacing: 8) {
            Button(L("Dán")) {
                if let s = NSPasteboard.general.string(forType: .string) { alignLyricsInput = s }
            }.controlSize(.small)
            if !alignLyricsInput.isEmpty {
                Button(L("Xoá")) { alignLyricsInput = "" }.controlSize(.small).buttonStyle(.link)
            }
            Spacer()
        }

        let noLyrics = alignLyricsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            Button {
                runForcedAlign(quality: .fast)
            } label: {
                Label(advancedProxy.isBusy ? L("Đang xử lý…") : L("Tạo nhanh Karaoke"), systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(advancedProxy.isBusy || noLyrics)

            Button {
                runForcedAlign(quality: .hq)
            } label: {
                Label(L("Tạo Karaoke Chất Lượng"), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(advancedProxy.isBusy || noLyrics)
        }
        Text(L("“Chất lượng” tách nhạc sạch hơn nhưng lâu hơn nhiều."))
            .font(.caption2).foregroundStyle(.secondary)

        if advancedProxy.phase != .idle {
            VStack(alignment: .leading, spacing: 10) {
                // Chặng 1 — PHÂN TÍCH NHẠC (tách beat/vocal). Xong → tick xanh, rồi mới sang chặng 2.
                phaseRow("phân tích nhạc",
                         running: advancedProxy.phase == .separating,
                         progress: beatSepProxy.throttledProgress)

                // Chặng 2 — TẠO KARAOKE (canh giờ). Chỉ hiện khi đã qua chặng 1.
                if advancedProxy.phase.rank >= 2 || advancedProxy.phase == .done {
                    phaseRow("tạo karaoke",
                             running: advancedProxy.phase.rank >= 2 && advancedProxy.phase.rank < 6,
                             progress: advancedProxy.throttledListenProgress)
                }

                if advancedProxy.phase == .done {
                    if !advancedProxy.resultNote.isEmpty {
                        Text(advancedProxy.resultNote).font(.caption).foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("Đang mở phần “Chỉnh sửa”…"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if case .failed(let m) = advancedProxy.phase {
                    Text(m).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id("aiProgress")
        }

        HStack(spacing: 6) {
            Text(L("Hoặc")).font(.caption).foregroundStyle(.secondary)
            Button(L("Nhập SRT / ASS…")) { importLyrics() }.controlSize(.small)
        }
    }

    /// Đường "CÓ LỜI": lời người dùng dán → `runKaraokeTiming` (hàm CHUNG với đường "Không cần lời").
    private func runForcedAlign(quality: BeatSeparation.Quality) {
        guard let audio = resolvedAudioURL else { store.lastError = L("Chưa có file nhạc."); return }
        let lyrics = alignLyricsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyrics.isEmpty else { return }
        let session = store.projectSessionID
        Task {
            _ = await runKaraokeTiming(audio: audio, lyrics: lyrics, quality: quality, origin: .manual,
                                       shouldApply: { session == store.projectSessionID })
        }
    }

    private enum KaraokeOrigin { case manual, auto }

    /// ĐIỂM CHUNG của HAI ĐƯỜNG tạo Karaoke. Đường "Có lời" gọi với lời dán tay; đường "Không cần lời" gọi với lời máy nhận dạng.
    /// Từ đây trở xuống là MỘT bộ canh giờ duy nhất: `AdvancedKaraoke.run` (tách giọng → đi tìm từng đoạn lời → dựng dòng → làm sạch).
    /// `shouldApply` = false (huỷ / đã đổi project) → KHÔNG áp kết quả vào project.
    @MainActor
    private func runKaraokeTiming(audio: URL, lyrics rawLyrics: String, quality: BeatSeparation.Quality, origin: KaraokeOrigin,
                                  shouldApply: @escaping @MainActor () -> Bool) async -> KaraokeTimingOutcome {
        let lyrics = rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyrics.isEmpty else { return .failure(L("Chưa có lời.")) }
        AutoLyricsDebug.recordTiming(origin: origin == .manual ? "manual" : "auto", lyrics: lyrics)
        #if KM_GUITEST
        if origin == .auto, AutoLyricsDebug.failNextTiming {                    // chỉ bản dựng kiểm thử: giả lập lỗi canh giờ
            AutoLyricsDebug.failNextTiming = false
            return .failure("Canh giờ không ra kết quả (giả lập để kiểm thử)")
        }
        #endif
        alignPhase = .separating   // kích hoạt cuộn xuống bước ③ khi xong
        let outcome = await advanced.run(
            audio: audio, pastedLyrics: lyrics, lang: .vi, quality: quality,
            beatSep: beatSep, aligner: aligner
        )
        guard let outcome, !outcome.lines.isEmpty else {
            alignPhase = .idle
            var msg = L("Canh xong nhưng không ra dòng nào — kiểm tra lại lời / nhạc.")
            if case .failed(let m) = advancedProxy.phase { msg = m }
            if origin == .manual { store.lastError = msg }
            return .failure(msg)
        }
        guard shouldApply() else { alignPhase = .idle; return .discarded }
        store.perform(L("Tạo Karaoke")) {
            var ls = outcome.lines
            for i in ls.indices { applyLeadWait(&ls, i, 0.3) }
            store.project.lines = ls
            store.project.rawLyrics = outcome.fullLyrics ?? lyrics
        }
        currentLineIndex = 0
        alignPhase = .done
        aiLinesListExpanded = true
        return .success(lines: outcome.lines.count)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 1 chặng trong bước tạo karaoke: đang chạy = spinner + thanh %, xong = tick xanh.
    @ViewBuilder
    private func phaseRow(_ title: String, running: Bool, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small)
                    Text(String(format: L("Đang %@…"), L(title).lowercased())).font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(String(format: L("Đã %@ xong"), L(title).lowercased())).font(.caption).foregroundStyle(.green)
                }
            }
            if running {
                ProgressView(value: max(0, min(1, progress)))
            }
        }
    }

    @ViewBuilder
    private func stepBlock<C: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder _ content: () -> C) -> some View {
        // Mỗi bước 1 THẺ riêng — tách bạch, đỡ cảm giác "1 khối chữ dài" (giống CapCut chia panel rõ ràng).
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(done ? Color.green : Theme.accent).frame(width: 22, height: 22)
                    if done {
                        Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                    } else {
                        Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                    }
                }
                Text(L(title)).font(.headline)
                Spacer()
            }
            content().padding(.leading, 30)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panelAlt))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }

    /// "Nhập lại" ở bước ② (thủ công) — xoá lời + dòng.
    private func resetLyricsEntry() {
        store.perform(L("Nhập lại lời")) {
            store.project.rawLyrics = ""
            store.project.lines = []
        }
        aiLinesListExpanded = false
        currentLineIndex = 0
        clearedLyricsBackup = nil
        lyricsImportNote = nil
    }

    // MARK: - Inspector (phải)

    @ViewBuilder
    private var inspectorColumn: some View {
        VStack(spacing: 0) {
            if case .overlay(let id) = editorSelection {
                overlayInspectorColumn(id)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "textformat").font(.system(size: 11)).foregroundStyle(Theme.inkDim)
                    Text(L("Kiểu chữ karaoke")).sectionHeaderStyle()
                    Spacer()
                }
                .padding(.horizontal, Theme.Metric.pad).padding(.vertical, Theme.Metric.gap)
                Divider().overlay(Theme.stroke)

                StylePanel(currentLineIndex: currentLineIndex, onCommitLineText: commitLyricEdit) {
                    EmptyView()
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    @ViewBuilder
    private func overlayInspectorColumn(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.2.layers.3d.top.filled").font(.system(size: 11)).foregroundStyle(Theme.accent)
                Text(store.project.overlays.first(where: { $0.id == id })?.name ?? L("Lớp đè"))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    let cur = store.project.overlays.first(where: { $0.id == id })?.name ?? ""
                    if let new = TextPrompt.run(title: L("Đổi tên clip"), defaultValue: cur, okTitle: L("Đổi")) {
                        timelineOverlayRename(id, new)
                    }
                } label: { Image(systemName: "pencil").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help(L("Đổi tên clip"))
                Spacer()
                Button(L("Xong")) { selectedOverlayID = nil }.controlSize(.small)
            }
            .padding(.horizontal, Theme.Metric.pad).padding(.vertical, Theme.Metric.gap)
            Divider().overlay(Theme.stroke)
            if selectedOverlayIDs.count > 1 {
                let asGroup = store.project.overlayGroups.first { Set($0.memberIDs) == selectedOverlayIDs }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L("%d lớp đang chọn"), selectedOverlayIDs.count))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(L("Kéo bất kỳ clip nào để dời cả nhóm · ⌫ để xoá cả nhóm · ⌘/Shift+bấm để thêm/bớt."))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let g = asGroup {
                            Text(String(format: L("Nhóm: %@"), g.name)).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            Button(L("Đổi tên")) { renameGroup(g.id) }.controlSize(.small)
                            Button(L("Bỏ nhóm")) { ungroup(g.id) }.controlSize(.small)
                        } else {
                            Button { makeGroupFromSelection() } label: { Label(L("Gom thành nhóm"), systemImage: "square.stack.3d.up") }
                                .controlSize(.small).buttonStyle(.borderedProminent).tint(Theme.accent)
                        }
                    }
                    Button(role: .destructive) {
                        let ids = selectedOverlayIDs
                        store.perform(L("Xoá lớp đè")) { store.project.overlays.removeAll { ids.contains($0.id) }; pruneOverlayGroups() }
                        selectedOverlayIDs = []; selectedOverlayID = nil
                    } label: { Label(String(format: L("Xoá %d lớp"), selectedOverlayIDs.count), systemImage: "trash") }
                    .controlSize(.small)
                }
                .padding(Theme.Metric.pad)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let g = overlayGroup(forClip: id) {
                        let hiddenAll = g.memberIDs.allSatisfy { gid in
                            store.project.overlays.first { $0.id == gid }?.isHidden ?? false }
                        let lockedAll = g.memberIDs.allSatisfy { gid in
                            store.project.overlays.first { $0.id == gid }?.isLocked ?? false }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.stack.3d.up.fill").font(.caption2).foregroundStyle(Theme.accent)
                                Text(g.name).font(.caption.weight(.semibold))
                                Text(String(format: L("(%d lớp)"), g.memberIDs.count)).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                            }
                            HStack(spacing: 6) {
                                Button { selectGroup(g.id) } label: { Label(L("Chọn cả nhóm"), systemImage: "checkmark.circle") }
                                    .controlSize(.small)
                                Button { setGroupFlag(g.id, hidden: !hiddenAll) } label: {
                                    Image(systemName: hiddenAll ? "eye.slash" : "eye")
                                }.controlSize(.small).help(hiddenAll ? L("Hiện cả nhóm") : L("Ẩn cả nhóm"))
                                Button { setGroupFlag(g.id, locked: !lockedAll) } label: {
                                    Image(systemName: lockedAll ? "lock.fill" : "lock.open")
                                }.controlSize(.small).help(lockedAll ? L("Mở khoá nhóm") : L("Khoá cả nhóm"))
                                Button { renameGroup(g.id) } label: { Image(systemName: "pencil") }.controlSize(.small)
                                Button { ungroup(g.id) } label: { Image(systemName: "square.stack.3d.up.slash") }
                                    .controlSize(.small).help(L("Bỏ nhóm"))
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
                        Divider()
                    }
                    overlayInspectorInline(id)

                    Divider()
                    Button(role: .destructive) { removeOverlay(id) } label: {
                        Label(L("Xoá lớp này"), systemImage: "trash")
                    }
                }
                .padding(14)
            }
            }
        }
    }


    private var resolvedAudioURL: URL? {
        playback.loadedURL ?? store.project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
    }


    private func timeFieldRow(_ title: String, value: TimeInterval?, isStart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                TimeField(seconds: value) { t in
                    isStart ? setLineStartTime(currentLineIndex, t) : setLineEndTime(currentLineIndex, t)
                }
            }
            HStack(spacing: 4) {
                Button("−0.5") { isStart ? nudgeStart(currentLineIndex, -0.5) : nudgeEnd(currentLineIndex, -0.5) }
                Button("−0.05") { isStart ? nudgeStart(currentLineIndex, -0.05) : nudgeEnd(currentLineIndex, -0.05) }
                Button("+0.05") { isStart ? nudgeStart(currentLineIndex, 0.05) : nudgeEnd(currentLineIndex, 0.05) }
                Button("+0.5") { isStart ? nudgeStart(currentLineIndex, 0.5) : nudgeEnd(currentLineIndex, 0.5) }
                Spacer()
                Button(L("= đang phát")) { isStart ? setStartToPlayhead(currentLineIndex) : setEndToPlayhead(currentLineIndex) }
                    .disabled(!playback.isLoaded)
            }
            .controlSize(.small).font(.caption)
        }
    }

    // MARK: - Cột giữa: preview + thanh phát

    private var centerColumn: some View {
        VStack(spacing: Theme.Metric.gap) {
            KaraokePreview(background: previewBackground, backgroundImage: backgroundImage,
                           videoURL: bgVideoURL, previewQuality: previewQuality,
                           selectedOverlayID: selectedOverlayID,
                           selectedOverlayIDs: selectedOverlayIDs,
                           showSafeArea: showSafeArea,
                           onSelectOverlay: { selectedOverlayID = $0 },
                           onEditTextOverlay: { id in
                               selectedOverlayID = id
                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textOverlayEditing = true }
                           })
                .frame(maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.radius))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                .overlay(alignment: .topTrailing) {
                    Toggle(L("Vạch an toàn"), isOn: $showSafeArea)
                        .toggleStyle(.button).controlSize(.small)
                        .padding(Theme.Metric.gap)
                }
                .overlay { if isFreshProject { onboardingCard } }
            transportBar
        }
        .padding(Theme.Metric.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// Project vừa tạo, chưa có gì → hiện hướng dẫn 3 bước.
    private var isFreshProject: Bool {
        store.project.audio == nil
            && store.project.lines.isEmpty
            && store.project.overlays.isEmpty
            && store.project.backgroundMedia == nil
    }

    private var onboardingCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.mic").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text(L("Bắt đầu làm karaoke")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                onboardStep("1", "Kéo file nhạc vào ô 'File của bạn' (cột trái) hoặc thả xuống timeline.")
                onboardStep("2", "Sang tab 'Tạo Karaoke' → dán lời bài hát.")
                onboardStep("3", "Bấm tạo karaoke, rồi tinh chỉnh trên timeline.")
            }
            .font(.callout)
            Text(L("Ảnh / video / logo: kéo xuống timeline để đè lên video."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    private func onboardStep(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(n)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent.opacity(0.25)))
                .overlay(Circle().stroke(Theme.accent.opacity(0.6)))
            Text(L(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bọc 1 nhóm chức năng thành THẺ RIÊNG (nền mờ + viền mỏng) — cùng ngôn ngữ hình ảnh với
    /// `stepBlock` bên ngoài, tách bạch từng khối thay vì 1 cột chữ liền mạch.
    private func subCard<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.gap) {
            Text(L(title)).sectionHeaderStyle()
            content()
        }
        .padding(Theme.Metric.gap + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.radiusSm).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radiusSm).stroke(Theme.stroke))
    }

    /// Bước 3 trong quy trình giờ chỉ CHỈ ĐƯỜNG — điều khiển thật đã dời sang tab
    /// "Kho media" riêng (đầy chiều cao) ở trên cùng panel trái, đỡ nhồi nhét 1 chỗ.
    @ViewBuilder
    private var backgroundPanelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Chọn nền ở tab **Nền video**, thêm chữ ở tab **Thêm text**, bật sóng nhạc ở tab **Sóng nhạc**. Thêm ảnh / video / nhạc đè ở tab **Media**."))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { withAnimation { leftPanelTab = .background } } label: {
                    Label(L("Nền video"), systemImage: "photo")
                }
                Button { withAnimation { leftPanelTab = .files } } label: {
                    Label(L("Media"), systemImage: "folder")
                }
            }
            .controlSize(.small)
        }
    }

    /// (U6) Nội dung chọn nền — dùng chung giữa tab "Kho media" (chính) và bước 3 cũ (nếu cần).
    /// Gồm LUÔN bảng phóng/lệch/mờ + Ken Burns + chỉnh màu (`backgroundMediaBlock`) — không
    /// còn tách sang tab Xuất nữa.
    @ViewBuilder
    private var backgroundSourceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Kiểu nền"), selection: $previewBackground) {
                ForEach(PreviewBackground.allCases) { Text(L($0.rawValue)).tag($0) }
            }

            // Hiệu ứng Bass nền — CHỈ hiện khi đã có nền (ảnh/video), đặt ngay dưới kiểu nền cho dễ thấy.
            if store.project.backgroundMedia != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("Hiệu ứng Bass nền"), isOn: beatZoomEnabledBinding)
                        .toggleStyle(.checkbox).font(.caption.weight(.semibold))
                    if beatZoomEnabledBinding.wrappedValue {
                        bgSlider("Mức bass", beatZoomAmountBinding.wrappedValue, 1.0...1.3) { v in
                            beatZoomAmountBinding.wrappedValue = v
                        }
                        Text(L("Nền phóng to nhẹ theo tiếng bass, tự mượt lại — không giật."))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }

            if let media = store.project.backgroundMedia, media.kind == .video {
                Picker(L("Chất lượng xem"), selection: $previewQuality) {
                    ForEach(PreviewQuality.allCases) { Text(L($0.rawValue)).tag($0) }
                }
            }
            Divider().padding(.vertical, 2)
            backgroundMediaBlock
        }
    }

    /// (U6) Danh sách lớp đè — dùng chung giữa tab "Kho media" (chính) và bước 3 cũ.
    @ViewBuilder
    private var overlayListContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(L("＋ Ảnh / logo…")) { addOverlay() }.controlSize(.small)
            }
            if store.project.overlays.isEmpty {
                Text(L("Chưa có. Thêm logo hoặc ảnh graded để đè lên video."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(store.project.overlays) { clip in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Button { toggleOverlayLocked(clip.id) } label: {
                                Image(systemName: clip.isLocked ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(.borderless)
                            .help(clip.isLocked ? L("Đang khoá — bấm để mở, kéo/sửa được lại") : L("Khoá lại để không kéo/sửa nhầm"))
                            Button { toggleOverlayHidden(clip.id) } label: {
                                Image(systemName: clip.isHidden ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(clip.isHidden ? L("Đang ẩn") : L("Đang hiện"))
                            Text(clip.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(selectedOverlayID == clip.id ? L("Đóng") : L("Sửa")) {
                                selectedOverlayID = (selectedOverlayID == clip.id) ? nil : clip.id
                            }
                            .controlSize(.small)
                            .help(L("Mở bảng chỉnh ở cột bên phải"))
                            Button(role: .destructive) { removeOverlay(clip.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    /// (U5) Chia gọn theo tab thay vì cuộn dài 1 lượt — Biến hình / Màu sắc.
    @ViewBuilder
    private func overlayInspectorInline(_ id: UUID) -> some View {
        if let b = overlayBinding(id) {
            let locked = store.project.overlays.first(where: { $0.id == id })?.isLocked ?? false
            switch b.wrappedValue.kind {
            case .audio: audioOverlayInspector(b, locked: locked)
            case .text:  textOverlayInspector(b, locked: locked)
            default:     overlayVisualInspector(id, b, locked: locked)
            }
        }
    }

    /// Danh sách font gợi ý cho lớp chữ (không quét toàn hệ thống cho nhẹ).
    private static let textLayerFonts: [String] = {
        let want = ["Helvetica Neue", "Arial", "Avenir Next", "Futura", "Georgia",
                    "Times New Roman", "SF Pro", "SF Pro Display", "Be Vietnam Pro",
                    "Montserrat", "Roboto", "Noto Sans", "UTM Avo", "iCiel Cadena",
                    "Pattaya", "Lobster", "Bebas Neue", "Anton", "Oswald"]
        let all = Set(NSFontManager.shared.availableFontFamilies)
        return want.filter { all.contains($0) }
    }()

    /// Tab của bảng sửa LỚP CHỮ — chia nhỏ thay vì 1 cột dài kéo.
    private enum TextInspTab: String, CaseIterable {
        case content, color, effect, transform
        var label: String {
            switch self {
            case .content: return "Nội dung"
            case .color: return "Màu"
            case .effect: return "Hiệu ứng"
            case .transform: return "Biến hình"
            }
        }
        var icon: String {
            switch self {
            case .content: return "textformat"
            case .color: return "paintpalette"
            case .effect: return "sparkles"
            case .transform: return "move.3d"
            }
        }
    }

    @ViewBuilder
    private func textOverlayInspector(_ b: Binding<OverlayClip>, locked: Bool) -> some View {
        let halfDur = max(0.1, b.wrappedValue.duration / 2)
        var seen = Set<String>()
        let fonts = ([b.wrappedValue.textFontName] + Self.textLayerFonts).filter { seen.insert($0).inserted }
        VStack(alignment: .leading, spacing: 9) {
            if locked {
                Label(L("Đã khoá — mở khoá ở danh sách bên trái để sửa"), systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(L("Kéo–giãn–xoay trên màn hình xem trước · bấm đúp chữ để sửa nhanh."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu {
                    Button(L("Lưu kiểu hiện tại…")) {
                        if let name = TextPrompt.run(title: L("Lưu kiểu lớp chữ"),
                                                     defaultValue: "\(L("Kiểu")) \(textPresets.presets.count + 1)") {
                            textPresets.add(name: name, style: TextLayerStyle(b.wrappedValue))
                        }
                    }
                    if !textPresets.presets.isEmpty {
                        Divider()
                        ForEach(textPresets.presets) { pr in
                            Button(pr.name) {
                                store.perform(L("Kiểu lớp chữ: \(pr.name)")) {
                                    if let i = store.project.overlays.firstIndex(where: { $0.id == b.wrappedValue.id }) {
                                        pr.style.apply(to: &store.project.overlays[i])
                                    }
                                }
                            }
                        }
                        Divider()
                        Menu(L("Xoá kiểu")) {
                            ForEach(textPresets.presets) { pr in
                                Button(pr.name, role: .destructive) { textPresets.delete(pr.id) }
                            }
                        }
                    }
                } label: { Label(L("Kiểu"), systemImage: "textformat.alt") }
                    .menuStyle(.borderlessButton).fixedSize()
            }

            Picker("", selection: $textInspTab) {
                ForEach(TextInspTab.allCases, id: \.self) { t in
                    Label(L(t.label), systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.vertical, 2)

            switch textInspTab {
            case .content:
                TextEditor(text: b.text)
                    .font(.body).frame(minHeight: 52, maxHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(textOverlayEditing ? Theme.accent : Theme.strokeStrong))
                    .focused($textOverlayEditing)
                HStack(spacing: 8) {
                    Menu {
                        ForEach(fonts, id: \.self) { f in
                            Button(f) { b.wrappedValue.textFontName = f }
                        }
                    } label: {
                        Text(b.wrappedValue.textFontName).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    Toggle("B", isOn: b.textBold).toggleStyle(.button).font(.system(size: 12, weight: .bold))
                    Toggle("I", isOn: b.textItalic).toggleStyle(.button).font(.system(size: 12).italic())
                }
                overlaySlider("Cỡ chữ", b.textFontSize, 12...320, "%.0f")
                overlaySlider("Giãn chữ", b.textCharSpacing, -10...40, "%.1f")
                overlaySlider("Cách dòng", b.textLineSpacing, 0...80, "%.0f")
                overlaySlider("Bề rộng ngắt dòng", b.textWrapFrac, 0.2...1.0, "%.2f")
                Picker(L("Căn lề"), selection: b.textAlign) {
                    Text(L("Trái")).tag(KaraokeTextAlignment.leading)
                    Text(L("Giữa")).tag(KaraokeTextAlignment.center)
                    Text(L("Phải")).tag(KaraokeTextAlignment.trailing)
                }
                .pickerStyle(.segmented).labelsHidden().tint(Theme.accent)

            case .color:
                AppFillField(fill: b.wrappedValue.textFill, label: "Màu chữ",
                             defaultValue: OverlayClip().textFill) {
                    b.wrappedValue.textFill = $0
                    b.wrappedValue.textColor = $0.color
                }
                AppFillField(fill: b.wrappedValue.textOutlineFill, label: "Màu viền",
                             defaultValue: OverlayClip().textOutlineFill) {
                    b.wrappedValue.textOutlineFill = $0
                    b.wrappedValue.textOutlineColor = $0.color
                }
                overlaySlider("Độ dày viền", b.textOutlineWidth, 0...30, "%.0f")
                AppFillField(fill: b.wrappedValue.textBackgroundFill, label: "Nền sau chữ (alpha 0 = tắt)",
                             defaultValue: OverlayClip().textBackgroundFill) {
                    b.wrappedValue.textBackgroundFill = $0
                    b.wrappedValue.textBackgroundColor = $0.color
                }
                Divider()
                AppFillField(fill: b.wrappedValue.textShadowFill, label: "Bóng đổ (alpha 0 = tắt)",
                             defaultValue: OverlayClip().textShadowFill) {
                    b.wrappedValue.textShadowFill = $0
                    b.wrappedValue.textShadowColor = $0.color
                }
                if b.wrappedValue.textShadowFill.maxAlpha > 0.001 {
                    overlaySlider("Nhoè bóng", b.textShadowRadius, 0...40, "%.0f")
                    overlaySlider("Bóng ngang", b.textShadowDX, -30...30, "%.0f")
                    overlaySlider("Bóng dọc", b.textShadowDY, -30...30, "%.0f")
                }
                AppFillField(fill: b.wrappedValue.textGlowFill, label: "Phát sáng / glow (alpha 0 = tắt)",
                             defaultValue: OverlayClip().textGlowFill) {
                    b.wrappedValue.textGlowFill = $0
                    b.wrappedValue.textGlowColor = $0.color
                }
                if b.wrappedValue.textGlowFill.maxAlpha > 0.001 {
                    overlaySlider("Độ toả glow", b.textGlowRadius, 0...50, "%.0f")
                }

            case .effect:
                HStack(spacing: 8) {
                    Picker(L("Chữ vào"), selection: b.textEntrance) {
                        ForEach(TextEffect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker(L("Chữ ra"), selection: b.textExit) {
                        ForEach(TextEffect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .controlSize(.small)
                if b.wrappedValue.textEntrance != .none || b.wrappedValue.textExit != .none {
                    overlaySlider("Thời lượng hiệu ứng", b.textEffectDur, 0.1...1.5, "%.2f")
                }
                Divider()
                overlaySlider("Độ mờ", opacityKFBinding(b), 0...1, "%.2f")
                fadeRow("Hiện dần", b.fadeIn, max: halfDur)
                fadeRow("Mờ dần", b.fadeOut, max: halfDur)

            case .transform:
                Toggle(L("Đè lên trên chữ karaoke"), isOn: b.aboveText).toggleStyle(.checkbox).font(.caption)
                HStack(spacing: 6) {
                    Button(L("Giữa khung")) {
                        b.wrappedValue.offsetX = 0; b.wrappedValue.offsetY = 0; b.wrappedValue.rotation = 0
                    }
                    Button(L("Cỡ gốc")) { b.wrappedValue.scale = 1 }
                }
                .controlSize(.small)
                Divider()
                keyframeControls(b)
            }
        }
        .disabled(locked)
    }

    /// Tua vạch đỏ tới mốc keyframe trước / sau vị trí hiện tại.
    private func seekToKeyframe(_ clip: OverlayClip, dir: Int) {
        let lt = max(0, playback.currentTime - clip.start)
        let t: Double? = dir < 0
            ? clip.keyframes.map(\.t).filter { $0 < lt - 0.02 }.max()
            : clip.keyframes.map(\.t).filter { $0 > lt + 0.02 }.min()
        if let t { seekTo(clip.start + t) }
    }

    /// Binding "Độ mờ" nhận biết keyframe: có chuyển động → đọc/ghi mốc tại vạch đỏ; không → tĩnh.
    private func opacityKFBinding(_ b: Binding<OverlayClip>) -> Binding<Double> {
        let clip = b.wrappedValue
        guard !clip.keyframes.isEmpty else { return b.opacity }
        let lt = max(0, playback.currentTime - clip.start)
        return Binding(
            get: { b.wrappedValue.transform(atLocal: lt).opacity },
            set: { v in
                store.edit(L("Độ mờ keyframe")) {
                    guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) else { return }
                    let p = store.project.overlays[i].transform(atLocal: lt)
                    store.project.overlays[i].upsertKeyframe(atLocal: lt, offX: p.offX, offY: p.offY,
                                                            scale: p.scale, rotation: p.rot, opacity: v)
                }
            })
    }

    /// Chuyển động (keyframe) cho lớp đè — cụm ◇ kiểu CapCut.
    @ViewBuilder
    private func keyframeControls(_ b: Binding<OverlayClip>) -> some View {
        let clip = b.wrappedValue
        let localT = max(0, playback.currentTime - clip.start)
        let hasAny = !clip.keyframes.isEmpty
        let nearIdx = clip.keyframes.firstIndex { abs($0.t - localT) < 0.15 }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Chuyển động")).font(.caption.bold())
                if hasAny { Text(String(format: L("%d mốc"), clip.keyframes.count)).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if hasAny {
                    Button { store.perform(L("Xoá chuyển động")) {
                        if let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) {
                            store.project.overlays[i].keyframes = [] }
                    } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(L("Xoá hết chuyển động"))
                }
                KeyframeControl(
                    hasAny: hasAny, atKeyframe: nearIdx != nil,
                    canPrev: clip.keyframes.contains { $0.t < localT - 0.02 },
                    canNext: clip.keyframes.contains { $0.t > localT + 0.02 },
                    onPrev: { seekToKeyframe(clip, dir: -1) },
                    onToggle: {
                        store.perform("Keyframe") {
                            guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) else { return }
                            if let ni = nearIdx { store.project.overlays[i].keyframes.remove(at: ni) }
                            else {
                                let p = store.project.overlays[i].transform(atLocal: localT)
                                store.project.overlays[i].upsertKeyframe(atLocal: localT, offX: p.offX, offY: p.offY,
                                                                        scale: p.scale, rotation: p.rot, opacity: p.opacity)
                            }
                        }
                    },
                    onNext: { seekToKeyframe(clip, dir: 1) })
            }

            if let ki = nearIdx {
                HStack(spacing: 6) {
                    Text(L("Kiểu chạy")).font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { clip.keyframes[ki].ease },
                        set: { v in store.edit(L("Kiểu keyframe")) {
                            guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }),
                                  store.project.overlays[i].keyframes.indices.contains(ki) else { return }
                            store.project.overlays[i].keyframes[ki].ease = v
                        } })) {
                        ForEach(KFEase.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().controlSize(.mini)
                    Spacer()
                }
            }
            if hasAny || kfClip.frames != nil {
                HStack(spacing: 10) {
                    if hasAny {
                        Button { kfClip.frames = clip.keyframes } label: { Image(systemName: "doc.on.doc") }
                            .help(L("Sao chép chuyển động"))
                        Button {
                            store.perform(L("Đảo chuyển động")) {
                                guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }),
                                      let last = store.project.overlays[i].keyframes.last?.t else { return }
                                let first = store.project.overlays[i].keyframes.first?.t ?? 0
                                store.project.overlays[i].keyframes = store.project.overlays[i].keyframes
                                    .map { var k = $0; k.t = first + (last - $0.t); return k }.sorted { $0.t < $1.t }
                            }
                        } label: { Image(systemName: "arrow.left.arrow.right") }.help(L("Đảo chiều"))
                    }
                    if kfClip.frames != nil {
                        Button {
                            guard let src = kfClip.frames else { return }
                            store.perform(L("Dán chuyển động")) {
                                guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) else { return }
                                let dur = max(0.1, store.project.overlays[i].duration)
                                store.project.overlays[i].keyframes = src
                                    .map { var k = $0; k.t = max(0, min(dur, k.t)); return k }.sorted { $0.t < $1.t }
                            }
                        } label: { Image(systemName: "doc.on.clipboard") }.help(L("Dán chuyển động"))
                    }
                    Spacer()
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text(hasAny
                 ? L("Dời vạch đỏ tới chỗ khác, kéo–giãn–xoay lớp trên màn hình xem trước → tự ghi mốc.")
                 : L("Bấm ◇ để bắt đầu. Rồi dời vạch đỏ + chỉnh lớp → app tự tạo mốc."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Clip TIẾNG trên làn lớp đè — chỉ tiếng, không hình.
    private func audioOverlayInspector(_ b: Binding<OverlayClip>, locked: Bool) -> some View {
        let halfDur = max(0.1, b.wrappedValue.duration / 2)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Clip tiếng — trộn kèm bài hát chính khi phát thử và khi xuất video."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L("Tắt tiếng clip này"), isOn: b.audioMuted)
                .toggleStyle(.checkbox).font(.caption)
            HStack(spacing: 6) {
                Text(L("Nhạc vào từ")).font(.caption2).frame(width: 72, alignment: .leading)
                Stepper(value: b.trimStart,
                        in: 0...max(0, b.wrappedValue.sourceDuration - 0.2), step: 0.5) {
                    Text(String(format: "%.1fs", b.wrappedValue.trimStart)).font(.caption2.monospacedDigit())
                }
                Button(L("Về 0")) { b.wrappedValue.trimStart = 0 }.controlSize(.small)
            }
            fadeRow("To dần", b.fadeIn, max: halfDur)
            fadeRow("Nhỏ dần", b.fadeOut, max: halfDur)
            Text(L("Kéo trên timeline để dời / đổi làn · kéo mép để cắt độ dài."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .disabled(locked)
    }

    private func overlayVisualInspector(_ id: UUID, _ b: Binding<OverlayClip>, locked: Bool) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                if locked {
                    Label(L("Đã khoá — mở khoá ở danh sách bên trái để sửa"), systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Text(L("Kéo–giãn–xoay trực tiếp trên màn hình xem trước. Thời điểm hiện / mất chỉnh ở timeline."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    overlaySlider("Độ mờ", opacityKFBinding(b), 0...1, "%.2f")
                    Picker(L("Hoà trộn"), selection: b.blend) {
                        ForEach(Compositor.Blend.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .controlSize(.small)
                    Toggle(L("Đè lên trên chữ"), isOn: b.aboveText)
                        .toggleStyle(.checkbox).font(.caption)
                        .help(L("Tắt = ảnh nằm DƯỚI chữ (dùng để tô màu / graded video)"))
                    HStack(spacing: 6) {
                        Button(L("Vừa khung")) {
                            b.wrappedValue.scale = 1
                            b.wrappedValue.offsetX = 0; b.wrappedValue.offsetY = 0; b.wrappedValue.rotation = 0
                        }
                        Button(L("Phủ kín")) {
                            b.wrappedValue.scale = overlayCoverScale(b.wrappedValue)
                            b.wrappedValue.offsetX = 0; b.wrappedValue.offsetY = 0
                        }
                        Button(L("Đổi ảnh…")) { replaceOverlayImage(id) }
                    }
                    .controlSize(.small)

                    if b.wrappedValue.kind == .video {
                        HStack(spacing: 6) {
                            Text(L("Video vào từ")).font(.caption2).frame(width: 66, alignment: .leading)
                            Stepper(value: b.trimStart,
                                    in: 0...max(0, b.wrappedValue.sourceDuration - b.wrappedValue.duration),
                                    step: 0.5) {
                                Text(String(format: "%.1fs", b.wrappedValue.trimStart))
                                    .font(.caption2.monospacedDigit())
                            }
                            Button(L("Về 0")) { b.wrappedValue.trimStart = 0 }.controlSize(.small)
                        }
                        Toggle(L("Bật tiếng của clip video"), isOn: b.videoAudioOn)
                            .toggleStyle(.checkbox).font(.caption)
                    }

                    let halfDur = max(0.1, b.wrappedValue.duration / 2)
                    fadeRow("Hiện dần", b.fadeIn, max: halfDur)
                    fadeRow("Mờ dần", b.fadeOut, max: halfDur)
                }

                Divider()
                keyframeControls(b)

                Divider()
                colorBasicPanel(b.colorAdjust, sample: {
                    let clip = b.wrappedValue
                    if clip.kind == .image { return OverlayImageStore.image(for: clip) }
                    guard let url = clip.resolveURL() else { return nil }
                    let vt = max(0, clip.trimStart + (playback.currentTime - clip.start))
                    guard let raw = OverlayVideoFrameStore.frame(path: clip.lastKnownPath, url: url, t: vt)
                    else { return nil }
                    return clip.colorAdjust.isIdentity ? raw : ImageFX.apply(raw, clip.colorAdjust)
                }, sampleKeySuffix: b.wrappedValue.kind == .video ? "|t\(Int(playback.currentTime))" : "")
            }
            .disabled(locked)
    }

    // MARK: - C7 · Bảng màu Basic (dùng cho lớp đè + nền)

    @ViewBuilder
    private func colorBasicPanel(_ b: Binding<ColorAdjust>, sample: (() -> CGImage?)? = nil,
                                 sampleKeySuffix: String = "") -> some View {
        let dirty = !b.wrappedValue.isIdentity
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L("MÀU")).font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    bypassColor.toggle()
                    ColorPipeline.bypass = bypassColor
                    OverlayImageStore.flush(); BackgroundImageStore.flush()
                } label: { Image(systemName: bypassColor ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(L("Xem Trước / Sau (tạm tắt chỉnh màu)"))
                Button { copiedColor = b.wrappedValue } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help(L("Sao chép thông số màu"))
                Button { if let c = copiedColor { b.wrappedValue = c } }
                    label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless).disabled(copiedColor == nil).help(L("Dán thông số màu"))
                Menu {
                    Button(L("Lưu preset màu…")) {
                        if let name = TextPrompt.run(title: L("Lưu preset màu"),
                                                     defaultValue: "\(L("Màu")) \(colorPresets.presets.count + 1)") {
                            colorPresets.add(name: name, adjust: b.wrappedValue)
                        }
                    }
                    if !colorPresets.presets.isEmpty {
                        Divider()
                        ForEach(colorPresets.presets) { pr in
                            Button(pr.name) { b.wrappedValue = pr.adjust }
                        }
                        Divider()
                        Menu(L("Xoá preset")) {
                            ForEach(colorPresets.presets) { pr in
                                Button(pr.name, role: .destructive) { colorPresets.delete(pr.id) }
                            }
                        }
                    }
                } label: { Image(systemName: "paintpalette") }
                    .menuStyle(.borderlessButton).frame(width: 24).help(L("Preset màu"))
                Button(L("Về gốc")) { b.wrappedValue = ColorAdjust() }
                    .controlSize(.mini).disabled(!dirty)
            }
            if bypassColor {
                Text(L("Đang xem BẢN GỐC (chỉnh màu tạm tắt)."))
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let sample {
                ColorScopes(provider: sample, key: b.wrappedValue.key + sampleKeySuffix)
            }
            Text(L("ÁNH SÁNG")).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            colorSlider("Phơi sáng", b.exposure)
            colorSlider("Tương phản", b.contrast)
            colorSlider("Sáng nổi", b.highlights)
            colorSlider("Vùng tối", b.shadows)
            colorSlider("Điểm trắng", b.whites)
            colorSlider("Điểm đen", b.blacks)

            Text(L("MÀU SẮC")).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.top, 2)
            colorSlider("Nhiệt độ", b.temperature, track: [
                Color(red: 0.20, green: 0.45, blue: 1.00), Color(red: 1.00, green: 0.82, blue: 0.20)])
            colorSlider("Sắc màu", b.tint, track: [
                Color(red: 0.20, green: 0.85, blue: 0.30), Color(red: 1.00, green: 0.20, blue: 0.85)])
            colorSlider("Độ rực", b.vibrance)
            colorSlider("Bão hoà", b.saturation, track: [
                Color(white: 0.55), Color(red: 0.95, green: 0.12, blue: 0.12)])

            Text(L("HIỆU ỨNG")).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.top, 2)
            colorSlider("Tối góc", b.vignette, bipolar: false)

            colorSection("ĐƯỜNG CONG", "curve", active: !b.wrappedValue.curves.isIdentity) {
                curvesEditor(b.curves)
            }
            colorSection("HSL / CHỌN MÀU", "hsl", active: !b.wrappedValue.hsl.isIdentity) {
                hslEditor(b.hsl)
            }
            colorSection("LUT", "lut", active: b.wrappedValue.lut?.isActive == true) {
                lutEditor(b)
            }
        }
        .onDisappear { clearColorBypass() }
    }

    private func clearColorBypass() {
        guard bypassColor || ColorPipeline.bypass else { return }
        bypassColor = false
        ColorPipeline.bypass = false
        OverlayImageStore.flush(); BackgroundImageStore.flush()
    }

    @State private var colorExpanded: Set<String> = []
    @State private var hslBand: Int = 0
    @State private var curveChan: Int = 0
    @State private var bypassColor = false
    @State private var copiedColor: ColorAdjust?

    @ViewBuilder
    private func colorSection<C: View>(_ title: String, _ id: String, active: Bool,
                                       @ViewBuilder _ content: () -> C) -> some View {
        let open = colorExpanded.contains(id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if open { colorExpanded.remove(id) } else { colorExpanded.insert(id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(L(title)).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(active ? Theme.accent : Color.secondary.opacity(0.7))
                    Spacer()
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
        .padding(.top, 3)
    }

    // MARK: C8 · Curve editor

    @ViewBuilder
    private func curvesEditor(_ b: Binding<ToneCurves>) -> some View {
        let chans = ["Chung", "Đỏ", "Lục", "Lam"]  // keys
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $curveChan) {
                ForEach(0..<4, id: \.self) { Text(L(chans[$0])).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini)
            ToneCurveGraph(curve: curveBinding(b, curveChan))
                .frame(height: 130)
            Button(L("Đường cong về thẳng")) {
                switch curveChan {
                case 1: b.wrappedValue.red = ToneCurve()
                case 2: b.wrappedValue.green = ToneCurve()
                case 3: b.wrappedValue.blue = ToneCurve()
                default: b.wrappedValue.master = ToneCurve()
                }
            }
            .controlSize(.mini)
        }
    }

    private func curveBinding(_ b: Binding<ToneCurves>, _ ch: Int) -> Binding<ToneCurve> {
        switch ch {
        case 1: return b.red
        case 2: return b.green
        case 3: return b.blue
        default: return b.master
        }
    }

    // MARK: C9 · HSL editor

    @ViewBuilder
    private func hslEditor(_ b: Binding<HSLAdjust>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $hslBand) {
                ForEach(0..<8, id: \.self) { Text(HSLAdjust.bandNames[$0]).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small)
            colorSlider("Tông màu", Binding(get: { b.wrappedValue.hue[hslBand] },
                                            set: { b.wrappedValue.hue[hslBand] = $0 }))
            colorSlider("Bão hoà", Binding(get: { b.wrappedValue.sat[hslBand] },
                                           set: { b.wrappedValue.sat[hslBand] = $0 }))
            colorSlider("Sáng", Binding(get: { b.wrappedValue.lum[hslBand] },
                                        set: { b.wrappedValue.lum[hslBand] = $0 }))
            Button(L("Dải này về 0")) {
                b.wrappedValue.hue[hslBand] = 0
                b.wrappedValue.sat[hslBand] = 0
                b.wrappedValue.lum[hslBand] = 0
            }
            .controlSize(.mini)
        }
    }

    // MARK: C10 · LUT

    @ViewBuilder
    private func lutEditor(_ b: Binding<ColorAdjust>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let ref = b.wrappedValue.lut, !ref.path.isEmpty {
                HStack {
                    Text(ref.name.isEmpty ? (ref.path as NSString).lastPathComponent : ref.name)
                        .font(.caption2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Bỏ")) { b.wrappedValue.lut = nil }.controlSize(.mini)
                }
                colorSlider("Độ mạnh", Binding(
                    get: { b.wrappedValue.lut?.intensity ?? 1 },
                    set: { b.wrappedValue.lut?.intensity = $0 }), bipolar: false)
            } else {
                Button(L("Chọn file .cube…")) {
                    if let url = FilePanels.chooseLUT() {
                        b.wrappedValue.lut = LUTRef(path: url.path,
                                                   name: url.deletingPathExtension().lastPathComponent,
                                                   intensity: 1)
                    }
                }
                .controlSize(.small)
                Text(L("LUT 3D .cube (áp trong sRGB).")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Slider màu: nội bộ −1…1 (hoặc 0…1), hiện −100…100. Double-click số = về 0.
    private func colorSlider(_ label: String, _ v: Binding<Double>, bipolar: Bool = true,
                             track: [Color]? = nil) -> some View {
        let lo: Double = bipolar ? -1 : 0
        return HStack(spacing: 6) {
            Text(L(label)).font(.caption2).frame(width: 78, alignment: .leading)
            if let track {
                GradientTrackSlider(value: v, range: lo...1, trackColors: track)
            } else {
                Slider(value: v, in: lo...1)
            }
            Text("\(Int((v.wrappedValue * 100).rounded()))")
                .font(.caption2.monospacedDigit())
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(v.wrappedValue == 0 ? .secondary : .primary)
                .onTapGesture(count: 2) { v.wrappedValue = 0 }
        }
    }

    /// Rãnh trượt tô sẵn gradient CỐ ĐỊNH (kiểu CapCut) — cho Nhiệt độ / Sắc / Bão hoà, để thấy
    /// ngay kéo bên nào ra tông gì. Bấm/kéo bất kỳ đâu trên rãnh (không cần trúng núm).
    private struct GradientTrackSlider: View {
        @Binding var value: Double
        var range: ClosedRange<Double> = -1...1
        var trackColors: [Color]

        var body: some View {
            GeometryReader { geo in
                let w = max(1, geo.size.width - 14)
                let span = range.upperBound - range.lowerBound
                let frac = span > 0 ? CGFloat((value - range.lowerBound) / span) : 0
                let x = 7 + max(0, min(1, frac)) * w
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: trackColors, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 3)
                        .padding(.horizontal, 7)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 13, height: 13)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                        .position(x: x, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = max(0, min(1, Double((g.location.x - 7) / w)))
                    value = range.lowerBound + f * span
                })
            }
            .frame(height: 16)
        }
    }

    private func overlaySlider(_ label: String, _ value: Binding<Double>,
                               _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        HStack(spacing: 6) {
            Text(L(label)).font(.caption2).frame(width: 42, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption2.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    /// Hàng "Hiện dần / Mờ dần" kiểu thanh trượt + số giây (thay `Stepper` cũ).
    private func fadeRow(_ label: String, _ value: Binding<Double>, max maxDur: Double) -> some View {
        HStack(spacing: 8) {
            Text(L(label)).font(.caption).frame(width: 66, alignment: .leading)
            Slider(value: value, in: 0...Swift.max(0.1, maxDur))
            Text(String(format: "%.1fs", value.wrappedValue))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func overlayBinding(_ id: UUID) -> Binding<OverlayClip>? {
        guard store.project.overlays.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.project.overlays.first(where: { $0.id == id }) ?? OverlayClip() },
            set: { newVal in
                store.edit(L("Sửa lớp đè")) {
                    if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                        store.project.overlays[i] = newVal
                    }
                }
            })
    }

    // MARK: - Sóng nhạc (music visualizer)

    private var visualizerBinding: Binding<MusicVisualizer> {
        Binding(
            get: { store.project.visualizer ?? .default },
            set: { newVal in
                store.edit(L("Chỉnh sóng nhạc")) { store.project.visualizer = newVal }
            })
    }

    private func setVisualizerEnabled(_ on: Bool) {
        store.perform(on ? L("Bật sóng nhạc") : L("Tắt sóng nhạc")) {
            if on {
                var v = store.project.visualizer ?? MusicVisualizer.freshDefault()
                v.enabled = true
                store.project.visualizer = v
            } else {
                store.project.visualizer?.enabled = false
            }
        }
        if on, let ref = store.project.audio, let url = AudioLoader.resolveURL(from: ref) {
            SpectrumStore.ensure(for: url)
        }
    }

    /// Preset nhanh: cột trắng mảnh, dày, gọn — kiểu spectrum cổ điển hay thấy trong video nhạc
    /// (khác hẳn kiểu gradient neon dày cộp mặc định). Giữ nguyên vị trí / kích thước đang đặt.
    private func applyClassicVisualizerPreset() {
        store.perform(L("Đổi kiểu sóng nhạc")) {
            guard var v = store.project.visualizer else { return }
            v.style = .barsUp
            v.bandCount = 140
            v.barGapFrac = 0.22
            v.cornerRadiusFrac = 0.1
            v.heightFrac = 0.14
            v.baselineY = 0.05
            v.mirror = false
            v.color1 = RGBAColor(r: 1, g: 1, b: 1, a: 1)
            v.color2 = RGBAColor(r: 1, g: 1, b: 1, a: 1)
            v.gradientDir = .up
            v.glowAuto = true
            v.glow = 0.08
            v.tipColor = RGBAColor(r: 1, g: 1, b: 1, a: 0)
            v.opacity = 0.9
            v.sensitivity = 1.2
            v.smoothing = 0.5
            store.project.visualizer = v
        }
    }

    /// M-D — cắt đầu / đuôi bài + âm lượng. KHÔNG dời timeline-time (lời giữ nguyên);
    /// chỉ giới hạn vùng PHÁT (và sau này vùng XUẤT).
    private func syncAudioSettings() {
        playback.applyAudioSettings(
            trimStart: store.project.audioTrimStart,
            trimEnd: store.project.audioTrimEnd,
            gain: store.project.audioGain,
            muted: store.project.audioMuted)
        // Bước 2c — clip ★ KARAOKE: cả bản karaoke phát trễ đúng mốc này trên timeline.
        playback.setLeadOffset(store.project.karaokeClipStart)
    }

    /// Slider vị trí sóng nhạc — nhận biết keyframe (có mốc → đọc/ghi mốc tại vạch đỏ).
    private func vizKFBinding(_ kp: WritableKeyPath<MusicVisualizer, Double>, base: Binding<Double>) -> Binding<Double> {
        guard store.project.visualizer?.keyframes.isEmpty == false else { return base }
        let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
        return Binding(
            get: { store.project.visualizer?.resolved(atSong: songT)[keyPath: kp] ?? base.wrappedValue },
            set: { newVal in
                store.edit(L("Sóng nhạc keyframe")) {
                    guard var v = store.project.visualizer else { return }
                    var res = v.resolved(atSong: songT)
                    res[keyPath: kp] = newVal
                    v.widthFrac = res.widthFrac; v.heightFrac = res.heightFrac
                    v.offsetX = res.offsetX; v.baselineY = res.baselineY
                    v.rotation = res.rotation; v.opacity = res.opacity
                    v.upsertKeyframe(atSong: songT)
                    store.project.visualizer = v
                }
            })
    }

    @ViewBuilder
    private var visualizerPanel: some View {
        let v = visualizerBinding
        let on = store.project.visualizer?.enabled ?? false
        let vizSongT = max(0, playback.currentTime - store.project.karaokeClipStart)
        let vizKF = store.project.visualizer?.keyframes ?? []
        let vizNearIdx = vizKF.firstIndex { abs($0.t - vizSongT) < 0.15 }
        HStack(spacing: 8) {
            Image(systemName: on ? "waveform" : "waveform.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.inkDim)
            Text(on ? L("Sóng nhạc: BẬT") : L("Sóng nhạc: TẮT"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? Theme.ink : Theme.inkDim)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { setVisualizerEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        // Sổ ra sẵn — các control luôn HIỆN, chỉ mờ + khoá khi chưa bật.
        Group {
            Text(L("Vẽ theo nhạc GỐC bạn bỏ vào. Mặc định full bề ngang — chỉnh cỡ / vị trí bên dưới."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(L("Kiểu"), selection: v.style) {
                ForEach(MusicVisualizer.Style.allCases) { Text($0.label).tag($0) }
            }.controlSize(.small)
            Button { applyClassicVisualizerPreset() } label: {
                Label(L("Cột mảnh cổ điển"), systemImage: "wand.and.stars")
            }
            .controlSize(.small)
            .help(L("Đổi sang kiểu cột trắng mảnh, dày, gọn gàng — kiểu spectrum cổ điển hay dùng trong video nhạc."))
            overlaySlider("Cỡ ngang", vizKFBinding(\.widthFrac, base: v.widthFrac), 0.2...1.0, "%.2f")
            overlaySlider("Cao", vizKFBinding(\.heightFrac, base: v.heightFrac), 0.04...0.6, "%.2f")
            overlaySlider("Dời ngang", vizKFBinding(\.offsetX, base: v.offsetX), -0.5...0.5, "%.2f")
            overlaySlider("Nâng lên", vizKFBinding(\.baselineY, base: v.baselineY), 0...0.9, "%.2f")
            overlaySlider("Độ mờ", vizKFBinding(\.opacity, base: v.opacity), 0...1, "%.2f")

            HStack(spacing: 8) {
                Text(L("Chuyển động")).font(.caption.bold())
                if !vizKF.isEmpty { Text(String(format: L("%d mốc"), vizKF.count)).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if !vizKF.isEmpty {
                    Button { store.perform(L("Xoá chuyển động sóng")) { store.project.visualizer?.keyframes = [] } }
                        label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Xoá hết"))
                    Button { kfClip.vizFrames = vizKF } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Sao chép"))
                }
                if kfClip.vizFrames != nil {
                    Button {
                        if let src = kfClip.vizFrames {
                            store.perform(L("Dán chuyển động sóng")) { store.project.visualizer?.keyframes = src }
                        }
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Dán"))
                }
                KeyframeControl(
                    hasAny: !vizKF.isEmpty, atKeyframe: vizNearIdx != nil,
                    canPrev: vizKF.contains { $0.t < vizSongT - 0.02 },
                    canNext: vizKF.contains { $0.t > vizSongT + 0.02 },
                    onPrev: { if let t = vizKF.map(\.t).filter({ $0 < vizSongT - 0.02 }).max() {
                        seekTo(t + store.project.karaokeClipStart) } },
                    onToggle: {
                        store.perform(L("Keyframe sóng")) {
                            if let ni = vizNearIdx { store.project.visualizer?.keyframes.remove(at: ni) }
                            else { store.project.visualizer?.upsertKeyframe(atSong: vizSongT) }
                        }
                    },
                    onNext: { if let t = vizKF.map(\.t).filter({ $0 > vizSongT + 0.02 }).min() {
                        seekTo(t + store.project.karaokeClipStart) } })
            }
            Text(vizKF.isEmpty
                 ? L("Bấm ◇ để bắt đầu. Rồi dời vạch đỏ + chỉnh cỡ/vị trí/độ mờ (hoặc kéo sóng trên màn hình xem trước) → tự tạo mốc.")
                 : L("Dời vạch đỏ tới lúc khác, chỉnh cỡ/vị trí/độ mờ → tự ghi mốc."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            overlaySlider("Sáng (glow)", v.glow, 0...1, "%.2f")
            overlaySlider("Độ nhạy", v.sensitivity, 0.3...3, "%.2f")
            overlaySlider("Độ mượt", v.smoothing, 0...1, "%.2f")
            DisclosureGroup(L("Màu sắc")) {
                VStack(alignment: .leading, spacing: 5) {
                    Picker(L("Kiểu màu"), selection: v.gradientDir) {
                        ForEach(MusicVisualizer.GradientDir.allCases) { Text($0.label).tag($0) }
                    }.controlSize(.small)
                    if v.wrappedValue.gradientDir == .rainbow {
                        overlaySlider("Dải màu", v.rainbowSpread, 0.2...3, "%.2f")
                        overlaySlider("Xoay màu", v.rainbowShift, 0...1, "%.2f")
                    } else {
                        HStack(spacing: 14) {
                            AppColorField(color: v.wrappedValue.color1, supportsOpacity: false, label: "Màu gốc") {
                                v.wrappedValue.color1 = $0
                            }
                            AppColorField(color: v.wrappedValue.color2, supportsOpacity: false, label: "Màu ngọn") {
                                v.wrappedValue.color2 = $0
                            }
                        }.font(.caption2)
                    }
                    HStack(spacing: 10) {
                        Toggle(L("Glow theo màu gốc"), isOn: v.glowAuto).toggleStyle(.checkbox).font(.caption2)
                        if !v.wrappedValue.glowAuto {
                            AppColorField(color: v.wrappedValue.glowColor, label: "Màu glow") {
                                v.wrappedValue.glowColor = $0
                            }.font(.caption2)
                        }
                    }
                    AppColorField(color: v.wrappedValue.tipColor, label: "Chấm sáng ở ngọn (alpha > 0 để bật)") {
                        v.wrappedValue.tipColor = $0
                    }.font(.caption2)
                }
            }.font(.caption)
            DisclosureGroup(L("Chi tiết")) {
                VStack(alignment: .leading, spacing: 5) {
                    overlaySlider("Số cột", Binding(get: { Double(v.wrappedValue.bandCount) },
                                                    set: { v.wrappedValue.bandCount = Int($0) }), 12...200, "%.0f")
                    overlaySlider("Khe cột", v.barGapFrac, 0...0.85, "%.2f")
                    overlaySlider("Bo góc", v.cornerRadiusFrac, 0...0.5, "%.2f")
                    if v.wrappedValue.style == .segments {
                        overlaySlider("Số đốt", Binding(get: { Double(v.wrappedValue.segCount) },
                                                        set: { v.wrappedValue.segCount = Int($0) }), 4...36, "%.0f")
                    }
                    if v.wrappedValue.style == .radial || v.wrappedValue.style == .radialBlob
                        || v.wrappedValue.style == .radialRing {
                        overlaySlider("Xoay", v.rotation, -180...180, "%.0f")
                    }
                    if v.wrappedValue.style == .waveLine || v.wrappedValue.style == .radialRing {
                        overlaySlider("Nét", v.lineWidthFrac, 0.002...0.03, "%.3f")
                    }
                    if v.wrappedValue.style == .barsMirror || v.wrappedValue.style == .areaGlow {
                        Toggle(L("Đối xứng 2 bên"), isOn: v.mirror).toggleStyle(.checkbox).font(.caption)
                    }
                    Toggle(L("Đè lên trên chữ"), isOn: v.aboveText).toggleStyle(.checkbox).font(.caption)
                }
            }.font(.caption)
        }
        .disabled(!on)
        .opacity(on ? 1 : 0.5)
    }

    private func addOverlay() {
        guard let url = FilePanels.chooseBackgroundImage() else { return }
        let dur = playback.duration > 0.5 ? playback.duration : 5
        var clip = OverlayClip(kind: .image, url: url, start: 0, duration: dur)
        clip.lane = freeOverlayLane(start: 0, end: clip.end)
        store.perform(L("Thêm lớp đè")) { store.project.overlays.append(clip) }
        selectedOverlayID = clip.id
    }

    /// Thêm 1 LỚP CHỮ (kind == .text) — hoạt động như lớp ảnh: có clip trên timeline,
    /// kéo–giãn–xoay trên preview, chỉnh nội dung/font/màu ở inspector bên phải.
    private func addTextOverlay(at time: TimeInterval? = nil, lane: Int? = nil) {
        let dur = min(playback.duration > 0.5 ? playback.duration : 6, 6)
        // Lớp đè sống theo GIỜ-TIMELINE (không trừ karaokeClipStart như timing lời).
        let ph = time ?? playback.currentTime
        let start = max(0, ph)
        var clip = OverlayClip()
        clip.kind = .text
        clip.name = L("Chữ")
        clip.text = L("Văn bản")
        clip.start = start
        clip.duration = dur
        clip.scale = 1
        clip.aboveText = true
        clip.textColor = store.project.style.textColor
        clip.textFill = .solid(store.project.style.textColor)
        clip.lane = lane ?? freeOverlayLane(start: start, end: start + dur)
        store.perform(L("Thêm lớp chữ")) { store.project.overlays.append(clip) }
        selectedOverlayID = clip.id
    }

    private func freeOverlayLane(start: TimeInterval, end: TimeInterval) -> Int {
        for lane in 0..<4 {
            let clash = store.project.overlays.contains {
                $0.lane == lane && $0.start < end && $0.end > start
            }
            if !clash { return lane }
        }
        return 0
    }

    private func removeOverlay(_ id: UUID) {
        store.perform(L("Xoá lớp đè")) {
            store.project.overlays.removeAll { $0.id == id }
            pruneOverlayGroups()
        }
        if selectedOverlayID == id { selectedOverlayID = nil }
        selectedOverlayIDs.remove(id)
    }

    // MARK: - Nhóm lớp đè

    private func pruneOverlayGroups() {
        let live = Set(store.project.overlays.map(\.id))
        for i in store.project.overlayGroups.indices {
            store.project.overlayGroups[i].memberIDs.removeAll { !live.contains($0) }
        }
        store.project.overlayGroups.removeAll { $0.memberIDs.count < 2 }
    }

    private func overlayGroup(forClip id: UUID) -> OverlayGroup? {
        store.project.overlayGroups.first { $0.memberIDs.contains(id) }
    }

    private func makeGroupFromSelection() {
        let ids = Array(selectedOverlayIDs)
        guard ids.count >= 2 else { return }
        store.perform(L("Gom nhóm lớp")) {
            // gỡ các id này khỏi nhóm cũ (nếu có) rồi tạo nhóm mới
            for i in store.project.overlayGroups.indices {
                store.project.overlayGroups[i].memberIDs.removeAll { ids.contains($0) }
            }
            store.project.overlayGroups.removeAll { $0.memberIDs.count < 2 }
            let n = store.project.overlayGroups.count + 1
            store.project.overlayGroups.append(OverlayGroup(name: "\(L("Nhóm")) \(n)", memberIDs: ids))
        }
    }

    private func ungroup(_ gid: UUID) {
        store.perform(L("Bỏ nhóm")) { store.project.overlayGroups.removeAll { $0.id == gid } }
    }

    private func renameGroup(_ gid: UUID) {
        guard let cur = store.project.overlayGroups.first(where: { $0.id == gid })?.name,
              let new = TextPrompt.run(title: L("Đổi tên nhóm"), defaultValue: cur, okTitle: L("Đổi")) else { return }
        store.perform(L("Đổi tên nhóm")) {
            if let i = store.project.overlayGroups.firstIndex(where: { $0.id == gid }) {
                store.project.overlayGroups[i].name = new
            }
        }
    }

    private func setGroupFlag(_ gid: UUID, hidden: Bool? = nil, locked: Bool? = nil) {
        guard let g = store.project.overlayGroups.first(where: { $0.id == gid }) else { return }
        store.perform(hidden != nil ? L("Ẩn/hiện nhóm") : L("Khoá/mở nhóm")) {
            for i in store.project.overlays.indices where g.memberIDs.contains(store.project.overlays[i].id) {
                if let h = hidden { store.project.overlays[i].isHidden = h }
                if let l = locked { store.project.overlays[i].isLocked = l }
            }
        }
    }

    private func selectGroup(_ gid: UUID) {
        guard let g = store.project.overlayGroups.first(where: { $0.id == gid }), !g.memberIDs.isEmpty else { return }
        selectedOverlayIDs = Set(g.memberIDs)
        selectedOverlayID = g.memberIDs.first
    }

    // MARK: - Lớp đè trên timeline: dời · cắt · tách · nhân đôi

    /// Bước 1 — kéo clip ★ KARAOKE: chốt mốc bắt đầu mới (1 undo / lần kéo).
    private func timelineKaraokeClipMove(_ newStart: Double) {
        let v = max(0, newStart)
        guard abs(v - store.project.karaokeClipStart) > 0.0005 else { return }
        store.perform(L("Dời clip Karaoke")) { store.project.karaokeClipStart = v }
    }

    private func timelineOverlayMove(_ id: UUID, _ newStart: Double, _ newLane: Int) {
        store.perform(L("Dời lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            store.project.overlays[i].start = max(0, newStart)
            store.project.overlays[i].lane = max(0, min(3, newLane))
        }
    }

    private func timelineOverlayTrim(_ id: UUID, _ newStart: Double, _ newDuration: Double) {
        store.perform(L("Cắt lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            var c = store.project.overlays[i]
            var s = max(0, newStart)
            var dur = max(0.1, newDuration)

            if c.kind == .video {
                let src = c.sourceDuration > 0.05 ? c.sourceDuration : .greatestFiniteMagnitude
                let deltaLeft = s - c.start            // >0 = cắt bớt đầu, <0 = kéo ngược ra
                if abs(deltaLeft) > 0.0005 {           // KÉO MÉP TRÁI → dời điểm vào nguồn
                    var newTrim = c.trimStart + deltaLeft
                    if newTrim < 0 { s -= newTrim; dur += newTrim; newTrim = 0 }   // hết đầu nguồn
                    c.trimStart = newTrim
                }
                // KÉO MÉP PHẢI (hoặc sau khi nắn trái) — không vượt quá phần còn lại của nguồn.
                dur = min(dur, max(0.1, src - c.trimStart))
            }
            c.start = max(0, s)
            c.duration = dur
            store.project.overlays[i] = c
        }
    }

    private func timelineOverlaySplit(_ id: UUID, _ atTime: Double) {
        store.perform(L("Tách lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            let c = store.project.overlays[i]
            guard atTime > c.start + 0.1, atTime < c.end - 0.1 else { return }
            var left = c
            left.duration = atTime - c.start
            var right = c
            right.id = UUID()
            right.start = atTime
            right.duration = c.end - atTime
            if c.kind == .video {
                right.trimStart = c.trimStart + (atTime - c.start)   // nửa phải vào nguồn muộn hơn
            }
            store.project.overlays[i] = left
            store.project.overlays.insert(right, at: i + 1)
        }
    }

    private func timelineToggleLaneHidden(_ lane: Int) {
        let clips = store.project.overlays.filter { $0.lane == lane }
        guard !clips.isEmpty else { return }
        let makeHidden = !clips.allSatisfy { $0.isHidden }   // còn 1 cái hiện → ẩn hết
        store.perform(makeHidden ? L("Ẩn cả làn") : L("Hiện cả làn")) {
            for i in store.project.overlays.indices where store.project.overlays[i].lane == lane {
                store.project.overlays[i].isHidden = makeHidden
            }
        }
    }

    private func timelineToggleLaneLocked(_ lane: Int) {
        let clips = store.project.overlays.filter { $0.lane == lane }
        guard !clips.isEmpty else { return }
        let makeLocked = !clips.contains { $0.isLocked }     // chưa cái nào khoá → khoá hết
        store.perform(makeLocked ? L("Khoá cả làn") : L("Mở khoá cả làn")) {
            for i in store.project.overlays.indices where store.project.overlays[i].lane == lane {
                store.project.overlays[i].isLocked = makeLocked
            }
        }
    }

    /// Nút loa đầu làn lớp đè: tắt / bật tiếng MỌI clip mang tiếng trong làn (audio + video).
    private func timelineToggleLaneAudioMuted(_ lane: Int) {
        let audible = store.project.overlays.filter {
            $0.lane == lane && ($0.kind == .audio || $0.kind == .video)
        }
        guard !audible.isEmpty else { return }
        let makeMuted = !audible.allSatisfy { $0.audioMuted }   // còn 1 cái mở tiếng → tắt hết
        store.perform(makeMuted ? L("Tắt tiếng cả làn") : L("Bật tiếng cả làn")) {
            for i in store.project.overlays.indices
            where store.project.overlays[i].lane == lane
                && (store.project.overlays[i].kind == .audio || store.project.overlays[i].kind == .video) {
                store.project.overlays[i].audioMuted = makeMuted
            }
        }
    }

    private func timelineOverlayFade(_ id: UUID, _ fin: Double, _ fout: Double) {
        store.perform(L("Chỉnh fade lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            let d = store.project.overlays[i].duration
            store.project.overlays[i].fadeIn = max(0, min(fin, d))
            store.project.overlays[i].fadeOut = max(0, min(fout, d))
        }
    }

    private func timelineOverlayRename(_ id: UUID, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        store.perform(L("Đổi tên clip")) {
            if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                store.project.overlays[i].name = clean
            }
        }
    }

    /// Chuyển cảnh mờ: kéo clip SAU (`bID`) chồng lên clip trước cùng làn `dur` giây + đặt fadeIn.
    private func timelineOverlayTransition(_ bID: UUID, _ dur: Double) {
        store.perform(L("Chuyển cảnh")) {
            guard let bi = store.project.overlays.firstIndex(where: { $0.id == bID }) else { return }
            var b = store.project.overlays[bi]
            guard let a = store.project.overlays
                .filter({ $0.lane == b.lane && $0.id != bID && $0.start < b.start })
                .max(by: { $0.start < $1.start }) else { return }
            let ov = max(0.1, min(dur, b.duration * 0.9, a.duration * 0.9, b.start - a.start))
            b.start = max(a.start, b.start - ov)
            b.fadeIn = ov
            store.project.overlays[bi] = b
        }
    }

    private func timelineOverlayDuplicate(_ id: UUID) {
        store.perform(L("Nhân đôi lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            var copy = store.project.overlays[i]
            copy.id = UUID()
            copy.start = store.project.overlays[i].end
            copy.lane = freeOverlayLane(start: copy.start, end: copy.start + copy.duration)
            store.project.overlays.insert(copy, at: i + 1)
            selectedOverlayID = copy.id
        }
    }

    private func toggleOverlayHidden(_ id: UUID) {
        store.perform(L("Ẩn / hiện lớp đè")) {
            if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                store.project.overlays[i].isHidden.toggle()
            }
        }
    }

    /// (U4) Khoá lớp đè — chặn kéo/xoay/phóng nhầm ở preview (KHÔNG chặn ẩn/hiện/xoá).
    private func toggleOverlayLocked(_ id: UUID) {
        store.perform(L("Khoá / mở khoá lớp đè")) {
            if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                store.project.overlays[i].isLocked.toggle()
            }
        }
    }

    // MARK: - (U6) Kho media — nhập ảnh, kéo xuống timeline để đặt lên video.

    private func mediaPoolThumb(_ item: MediaPoolItem, size: CGFloat = 60) -> some View {
        let h = size * 0.7
        let icon: String = {
            switch item.kind {
            case .audio: return "music.note"
            case .video: return "film"
            case .image: return "photo"
            }
        }()
        return VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.elevated)
                if item.kind == .image, let url = item.resolveURL(), let ns = NSImage(contentsOf: url) {
                    Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size, height: h).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(item.kind == .audio ? Theme.accent : .secondary)
                }
            }
            .frame(width: size, height: h)
            Text(item.name).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: size)
        }
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .contextMenu {
            Button(L("Đặt vào timeline (ở mốc đang phát)")) { placeMediaPoolItem(item) }
            Button(L("Xoá khỏi kho"), role: .destructive) { removeMediaPoolItem(item.id) }
        }
        .help(L("Kéo xuống timeline để đặt lên video, hoặc bấm chuột phải"))
    }

    private func importMediaPoolImages() {
        let urls = FilePanels.chooseImagesToImport()
        guard !urls.isEmpty else { return }
        store.perform(L("Nhập file vào kho")) {
            for url in urls { store.project.mediaPool.append(MediaPoolItem(url: url)) }
        }
    }

    private func removeMediaPoolItem(_ id: UUID) {
        store.perform(L("Xoá file khỏi kho")) { store.project.mediaPool.removeAll { $0.id == id } }
    }

    /// Kéo file TỪ FINDER thẳng vào ô kho (ảnh / nhạc / video).
    private func handleMediaPoolFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") })
        else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                store.perform(L("Nhập file vào kho")) { store.project.mediaPool.append(MediaPoolItem(url: url)) }
            }
        }
        return true
    }

    /// Đặt 1 ảnh trong kho lên timeline TẠI MỐC PHÁT HIỆN TẠI — tạo `OverlayClip` mới,
    /// dùng lại ĐÚNG cơ chế lớp đè đã có (không đổi cách vẽ/xuất video).
    private func placeMediaPoolItem(_ item: MediaPoolItem, at time: TimeInterval? = nil, lane: Int? = nil) {
        guard let url = item.resolveURL() else { return }
        // NHẠC từ kho: bấm ở lưới (lane == nil) → nạp làm bài chính; KÉO xuống 1 làn lớp đè
        // (lane != nil) → thành CLIP TIẾNG trên làn đó (trộn kèm khi phát + xuất).
        if item.kind == .audio, lane == nil {
            loadAudio(from: url)
            return
        }
        let start = max(0, time ?? playback.currentTime)
        let isVideo = item.kind == .video
        let isAudio = item.kind == .audio
        var dur: TimeInterval = 5
        var srcDur: TimeInterval = 0
        if isVideo || isAudio {
            let d = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            if d.isFinite, d > 0.2 { dur = d; srcDur = d }
        }
        let songDur = max(playback.duration, playback.virtualDuration)
        if songDur > 0.5 { dur = min(dur, max(0.5, songDur - start)) }
        let kind: BackgroundMedia.Kind = isVideo ? .video : (isAudio ? .audio : .image)
        var clip = OverlayClip(kind: kind, url: url, start: start, duration: dur)
        clip.sourceDuration = srcDur
        let targetLane = lane.map { max(0, min(3, $0)) }
        clip.lane = targetLane ?? freeOverlayLane(start: start, end: clip.end)
        store.perform(isVideo ? L("Đặt video lên timeline")
                      : isAudio ? L("Đặt tiếng lên timeline") : L("Đặt ảnh từ kho lên timeline")) {
            // Thả TRÚNG 1 làn → chèn kiểu ripple: clip nào ở làn đó mà chồng/đứng sau
            // điểm thả thì đẩy sang phải để chừa chỗ (như CapCut).
            if let tl = targetLane {
                for i in store.project.overlays.indices
                where store.project.overlays[i].lane == tl
                    && store.project.overlays[i].end > clip.start + 0.001 {
                    store.project.overlays[i].start += clip.duration
                }
            }
            store.project.overlays.append(clip)
        }
        selectedOverlayID = clip.id
    }

    /// Kéo–thả 1 item kho xuống ĐÚNG làn + mốc trên timeline (từ canvas AppKit).
    private func timelineMediaDropAt(_ idStr: String, _ time: Double, _ lane: Int) {
        if idStr == Self.newTextDragToken { addTextOverlay(at: max(0, time), lane: lane); return }
        guard let id = UUID(uuidString: idStr),
              let item = store.project.mediaPool.first(where: { $0.id == id }) else { return }
        placeMediaPoolItem(item, at: time, lane: lane)
    }

    /// Chuỗi đánh dấu khi KÉO nút "Thêm 1 lớp chữ" thả xuống timeline.
    static let newTextDragToken = "karaoke.newtext"


    private func replaceOverlayImage(_ id: UUID) {
        guard let url = FilePanels.chooseBackgroundImage(),
              let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
        var clip = store.project.overlays[i]
        clip.lastKnownPath = url.path
        clip.name = url.deletingPathExtension().lastPathComponent
        clip.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        store.perform(L("Đổi ảnh lớp đè")) { store.project.overlays[i] = clip }
        OverlayImageStore.flush()
    }

    private func overlayCoverScale(_ clip: OverlayClip) -> Double {
        guard let img = OverlayImageStore.image(for: clip) else { return 1.9 }
        let r = store.project.resolution
        let cw = CGFloat(r.width), ch = CGFloat(r.height)
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0, cw > 0, ch > 0 else { return 1.9 }
        let fitBase = min(cw / iw, ch / ih)
        let fillBase = max(cw / iw, ch / ih)
        return fitBase > 0 ? Double(fillBase / fitBase) : 1.9
    }

    /// Mặc định BẬT karaoke — hễ có beat là phát beat (nút xanh).
    @State private var karaokeOn = false
    /// Bấm ＋1 Chữ / ＋1 Dòng → tăng để timeline tạo item trên "track tạm".
    @State private var stageWordTick = 0
    @State private var stageLineTick = 0
    /// ⌘Z ngay sau khi thả item tạm → trả nó về làn cam thay vì mất.
    @State private var restageTick = 0
    @State private var restageItem: TimelineEditor.StageItem?
    @State private var lastStageDrop: TimelineEditor.StageItem?

    private var projectAudioURL: URL? {
        store.project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
    }

    private var transportBar: some View {
        TransportBar(
            onSeek: seekTo,
            karaokeOn: karaokeOn,
            karaokeAvailable: beatSepProxy.beatURL != nil && projectAudioURL != nil,
            onKaraoke: toggleKaraoke
        )
    }

    /// Bật/tắt karaoke: đổi nguồn phát giữa bài gốc và beat (giữ nguyên vị trí).
    private func toggleKaraoke() {
        let want = !karaokeOn
        guard let target = want ? beatSepProxy.beatURL : projectAudioURL else { return }
        karaokeOn = want
        playback.swapSource(to: target)
    }

    // MARK: - Thanh thao tác dòng / chữ (dưới preview)

    private var syncBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Spacer()
                Button { lastStageDrop = nil; stageWordTick += 1 } label: {
                    Label(L("Thêm chữ"), systemImage: "textformat.abc")
                }
                .disabled(store.project.lines.isEmpty)
                .help(L("Thêm 1 ô chữ vào dòng đang chọn"))

                Button { lastStageDrop = nil; stageLineTick += 1 } label: {
                    Label(L("Thêm dòng"), systemImage: "text.append")
                }
                .disabled(!playback.isLoaded)
                .help(L("Thêm 1 dòng lời mới"))

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { duetMode.toggle() }
                } label: {
                    Label(L("Song ca"), systemImage: "music.mic").padding(.horizontal, 4)
                }
                .disabled(store.project.lines.isEmpty)
                .overlay(alignment: .center) {
                    if duetMode {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(.white, lineWidth: 2)
                    }
                }

                Divider().frame(height: 22)

                Button { addLeadWait(toLine: currentLineIndex, by: 0.25) } label: {
                    Label(L("Chữ sớm +0.25 (dòng)"), systemImage: "arrow.left.to.line")
                }
                .disabled(!store.project.lines.indices.contains(currentLineIndex))
                .help(L("Cho DÒNG đang chọn hiện sớm hơn 0,25 giây"))

                Button { addLeadWaitAll(by: 0.25) } label: {
                    Label(L("Chữ sớm +0.25 (cả bài)"), systemImage: "arrow.left.to.line")
                }
                .disabled(store.project.lines.isEmpty)
                .help(L("Cho CẢ BÀI hiện sớm hơn 0,25 giây"))
                Spacer()
            }
            .buttonStyle(.borderedProminent)   // xanh = bấm được; xám (disabled) = chưa bấm được
            .tint(Theme.accent)
            .controlSize(.small)

            if duetMode { duetBar }
        }
        .padding(.horizontal, Theme.Metric.pad)
        .padding(.vertical, duetMode ? Theme.Metric.gap + 2 : Theme.Metric.gap - 2)
        .background(Theme.panel)
    }

    /// Sổ ra CHÍNH GIỮA dưới nút Song ca: 3 icon to + ô màu, 1 dòng hướng dẫn.
    private var duetBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 34) {
                ForEach(SingerRole.allCases) { role in
                    VStack(spacing: 4) {
                        Image(nsImage: SingerIcon.image(
                            role, height: 40,
                            color: (store.project.singerColors[role.rawValue] ?? SingerRole.defaultColor(role)).nsColor))
                            .resizable().scaledToFit().frame(height: 40)
                        Text(role.label).font(.caption).bold()
                        AppColorField(color: store.project.singerColors[role.rawValue] ?? SingerRole.defaultColor(role),
                                      supportsOpacity: false, swatchWidth: 40) { c in
                            store.edit(L("Màu \(role.label)")) { store.project.singerColors[role.rawValue] = c }
                        }
                        .help(L("Đổi màu vai \(role.label)"))
                    }
                }
            }
            HStack(spacing: 10) {
                Text(L("Bấm khối câu trên timeline rồi chọn icon · bấm “Song ca” lần nữa để thoát"))
                    .font(.caption2).foregroundStyle(.secondary)
                Button(L("Bỏ đánh dấu dòng này")) { assignSingerTimeline(currentLineIndex, nil) }
                    .controlSize(.small)
                    .disabled(!(store.project.lines.indices.contains(currentLineIndex)
                                && store.project.lines[currentLineIndex].singer != nil))
                Button(L("Bỏ đánh dấu cả bài"), role: .destructive) { clearAllSingers() }
                    .controlSize(.small)
                    .disabled(!store.project.lines.contains { $0.singer != nil })
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private func clearAllSingers() {
        store.perform(L("Bỏ đánh dấu người hát cả bài")) {
            for i in store.project.lines.indices { store.project.lines[i].singer = nil }
        }
    }

    private func roleColor(_ role: SingerRole) -> Color {
        (store.project.singerColors[role.rawValue] ?? SingerRole.defaultColor(role)).color
    }

    private func assignSingerTimeline(_ lineIndex: Int, _ role: SingerRole?) {
        guard store.project.lines.indices.contains(lineIndex) else { return }
        store.perform(role == nil ? L("Bỏ đánh dấu người hát") : L("Đánh dấu \(role!.label)")) {
            store.project.lines[lineIndex].singer = role
        }
    }

    /// Cho 1 dòng hiện sớm hơn `a` giây (tăng "giờ chờ"). KHÔNG đụng timing chữ của
    /// chính nó. Nếu đè vào câu trước thì THU câu trước lại (end + chữ cuối) chứ không chồng.
    private func applyLeadWait(_ lines: inout [LyricLine], _ i: Int, _ a: Double) {
        guard lines.indices.contains(i), let s = lines[i].start else { return }
        var newStart = max(0, s - a)
        if i > 0 {
            let pj = i - 1
            let prevEnd = lines[pj].words.last?.end ?? lines[pj].end ?? 0
            let prevLastStart = lines[pj].words.last?.start ?? lines[pj].start ?? prevEnd
            let minPrevEnd = prevLastStart + 0.10          // chừa chữ cuối câu trước ≥ 0.1s
            if newStart < prevEnd {
                let room = max(minPrevEnd, newStart)
                lines[pj].end = room
                if !lines[pj].words.isEmpty { lines[pj].words[lines[pj].words.count - 1].end = room }
                newStart = room
            }
        }
        let sing = lines[i].words.first?.start ?? s        // không vượt lúc bắt đầu hát
        lines[i].start = min(newStart, sing)
    }

    private func addLeadWait(toLine i: Int, by a: Double) {
        guard store.project.lines.indices.contains(i) else { return }
        store.perform(L("Thêm giờ chờ (dòng này)")) {
            applyLeadWait(&store.project.lines, i, a)
        }
    }

    private func addLeadWaitAll(by a: Double) {
        guard !store.project.lines.isEmpty else { return }
        store.perform(L("Thêm giờ chờ (cả bài)")) {
            for i in store.project.lines.indices { applyLeadWait(&store.project.lines, i, a) }
        }
    }

    private func lineHasWords(_ i: Int) -> Bool {
        store.project.lines.indices.contains(i) && !store.project.lines[i].words.isEmpty
    }

    // MARK: - Timeline (dưới)

    private var timelineArea: some View {
        TimelineEditor(
            currentLineIndex: currentLineIndex,
            onSelect: { currentLineIndex = $0; selectedOverlayID = nil },
            onSeek: { seekTo($0) },
            onCommit: timelineApplyChanges,
            onWordsCommit: timelineWordsCommit,
            onLineTextRemap: timelineLineTextRemap,
            onAddLine: timelineAddLine,
            onPasteLine: timelinePasteLine,
            onAddWordAtPlayhead: timelineAddWordAtPlayhead,
            stageWordTick: stageWordTick, stageLineTick: stageLineTick,
            restageTick: restageTick, restageItem: restageItem,
            onStageWordDrop: timelineStageWordDrop,
            onStageLineDrop: timelineStageLineDrop,
            onMoveLines: timelineMoveLines,
            onDeleteLines: timelineDeleteLines,
            onCopyLines: timelineCopyLines,
            onPasteAtPlayhead: timelinePasteAtPlayhead,
            onDuplicateLines: timelineDuplicateLines,
            onNudgeLines: timelineNudgeLines,
            overlays: store.project.overlays,
            overlayGroups: store.project.overlayGroups,
            vizKeyframeTimes: store.project.visualizer?.keyframes.map(\.t) ?? [],
            textKeyframeTimes: store.project.textKeyframes.map(\.t),
            selectedOverlayID: selectedOverlayID,
            selectedOverlayIDs: selectedOverlayIDs,
            onOverlaySelect: { selectedOverlayID = $0 },
            onOverlaySelectMulti: { selectedOverlayIDs = $0 },
            onSelectGroup: { selectGroup($0) },
            onEditTextOverlay: { id in
                selectedOverlayID = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textOverlayEditing = true }
            },
            onOverlayMove: timelineOverlayMove,
            onOverlayTrim: timelineOverlayTrim,
            onOverlayFade: timelineOverlayFade,
            onOverlayRename: timelineOverlayRename,
            onOverlayTransition: timelineOverlayTransition,
            onOverlayDelete: removeOverlay,
            onOverlaySplit: timelineOverlaySplit,
            onOverlayDuplicate: timelineOverlayDuplicate,
            onToggleLaneHidden: timelineToggleLaneHidden,
            onToggleLaneLocked: timelineToggleLaneLocked,
            onToggleLaneAudioMuted: timelineToggleLaneAudioMuted,
            onMediaDrop: timelineMediaDropAt,
            run: { runCommand($0) },
            canPasteClip: copiedOverlay != nil,
            duetMode: duetMode,
            singerColors: store.project.singerColors,
            onAssignSinger: assignSingerTimeline,
            onKaraokeClipMove: timelineKaraokeClipMove,
            fitTick: timelineFitTick,
            pointsPerSecond: $timelineZoom,
            viewportWidth: $timelineViewportW
        )
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        // Kéo ảnh/video/nhạc TỪ KHO ("File của bạn") thả thẳng xuống timeline — canvas AppKit
        // tự nhận, đặt đúng LÀN + MỐC chỗ thả (nhạc → nạp làm nhạc chính).
    }

    // MARK: - Tab Xuất

    private var exportTabContent: some View {
        let cueCount = SrtExporter.timedCues(from: store.project).count
        let timedCount = store.project.lines.filter { $0.isTimed }.count

        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Xuất SRT")).font(.headline)
            Text(String(format: L("%d dòng có timing sẽ được xuất. (%d/%d dòng đã gán)"), cueCount, timedCount, store.project.lines.count))
                .font(.callout).foregroundStyle(.secondary)

            Toggle(L("Thêm BOM UTF-8"), isOn: Binding(
                get: { store.project.exportSettings.srtIncludeBOM },
                set: { newValue in store.perform(L("Đổi BOM")) { store.project.exportSettings.srtIncludeBOM = newValue } }
            ))
            .toggleStyle(.checkbox)

            HStack(spacing: 10) {
                Button(L("Xuất SRT…")) { exportSRT() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cueCount == 0)
                Button(showSrtPreview ? L("Ẩn xem trước") : L("Xem trước")) { showSrtPreview.toggle() }
                    .disabled(cueCount == 0)
            }

            Divider().padding(.vertical, 2)
            Text(L("Xuất .ass (karaoke quét chữ)")).font(.headline)
            Text(L("Hiệu ứng \\kf quét sáng từng chữ. Dùng timing từng chữ nếu có, không thì chia đều. Mở bằng Aegisub / VLC."))
                .font(.caption2).foregroundStyle(.secondary)
            Button(L("Xuất .ass…")) { exportASS() }
                .buttonStyle(.borderedProminent)
                .disabled(!store.project.hasAnyTiming)

            if let note = exportNote {
                Text(note).font(.caption).foregroundStyle(.green)
            }

            if showSrtPreview {
                ScrollView {
                    Text(String(SrtExporter.makeSRT(from: store.project).prefix(1500)))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelAlt))
            }

            Divider().padding(.vertical, 4)
            transparentVideoBlock
        }
    }

    // MARK: - Nền hình (Mode C) — bảng đầy đủ (chọn file, phóng/lệch/mờ, Ken Burns, chỉnh màu).
    // Nằm ở tab "Nền video" (trái) — KHÔNG còn ở mục Xuất.

    private var backgroundMediaBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let media = store.project.backgroundMedia {
                HStack(spacing: 6) {
                    Image(systemName: media.kind == .image ? "photo" : "film").foregroundStyle(.secondary)
                    Text(media.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Đổi")) { pickBackground(media.kind) }.controlSize(.small)
                    Button(L("Bỏ"), role: .destructive) { removeBackgroundMedia() }.controlSize(.small)
                }
                if backgroundImage == nil {
                    Text(L("⚠︎ Không mở được file (đã di chuyển / đổi tên?)."))
                        .font(.caption).foregroundStyle(.orange)
                }
                bgSlider("Phóng to", media.scale, 0.2...4) { v in editBackgroundMedia("Phóng nền") { $0.scale = v } }
                bgSlider("Lệch ngang", media.offsetX, -0.5...0.5) { v in editBackgroundMedia("Lệch nền ngang") { $0.offsetX = v } }
                bgSlider("Lệch dọc", media.offsetY, -0.5...0.5) { v in editBackgroundMedia("Lệch nền dọc") { $0.offsetY = v } }
                bgSlider("Độ mờ", media.opacity, 0...1) { v in editBackgroundMedia("Độ mờ nền") { $0.opacity = v } }

                Divider().padding(.vertical, 2)
                Toggle(L("Tự chuyển động nhẹ (Ken Burns)"), isOn: Binding(
                    get: { media.kenBurns },
                    set: { on in editBackgroundMedia("Ken Burns nền") { $0.kenBurns = on } }))
                    .font(.caption).toggleStyle(.checkbox)
                if media.kind == .image {
                    Toggle(L("Lấp 2 bên bằng ảnh mờ (không cắt cúp)"), isOn: Binding(
                        get: { media.blurFill },
                        set: { on in editBackgroundMedia("Nền mờ lấp cạnh") { $0.blurFill = on } }))
                        .font(.caption).toggleStyle(.checkbox)
                }

                Divider().padding(.vertical, 2)
                if let cb = bgColorBinding {
                    colorBasicPanel(cb, sample: {
                        backgroundImage.map {
                            BackgroundImageStore.processed(
                                base: $0,
                                adjust: store.project.backgroundMedia?.colorAdjust ?? ColorAdjust(),
                                needBlur: false).main
                        }
                    })
                }
            } else {
                HStack(spacing: 6) {
                    Button(L("Ảnh nền…")) { pickBackground(.image) }.controlSize(.small)
                    Button(L("Video nền…")) { pickBackground(.video) }.controlSize(.small)
                }
            }
        }
    }

    private func bgSlider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(L(title)).font(.caption).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
            Text(String(format: "%.2f", value)).font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    private func pickBackground(_ kind: BackgroundMedia.Kind) {
        let url: URL?
        switch kind {
        case .image: url = FilePanels.chooseBackgroundImage()
        case .video: url = FilePanels.chooseBackgroundVideo()
        case .audio, .text: url = nil   // nền không dùng audio / text
        }
        guard let url else { return }
        store.perform(kind == .image ? L("Chọn ảnh nền") : L("Chọn video nền")) {
            store.project.backgroundMedia = BackgroundMedia(kind: kind, url: url)
        }
        reloadBackgroundImage()
        previewBackground = .media
    }

    private func removeBackgroundMedia() {
        store.perform(L("Bỏ nền hình")) { store.project.backgroundMedia = nil }
        backgroundImage = nil
        bgVideoURL = nil
        if previewBackground == .media { previewBackground = .dark }
    }

    private func editBackgroundMedia(_ name: String, _ mutate: @escaping (inout BackgroundMedia) -> Void) {
        guard store.project.backgroundMedia != nil else { return }
        store.edit(L(name)) {
            if var m = store.project.backgroundMedia {
                mutate(&m)
                store.project.backgroundMedia = m
            }
        }
    }

    /// Binding màu cho nền (ảnh hoặc video) — C7.
    private var bgColorBinding: Binding<ColorAdjust>? {
        guard store.project.backgroundMedia != nil else { return nil }
        return Binding(
            get: { store.project.backgroundMedia?.colorAdjust ?? ColorAdjust() },
            set: { v in store.edit(L("Chỉnh màu nền")) { store.project.backgroundMedia?.colorAdjust = v } })
    }

    /// Bật/tắt "Hiệu ứng Bass nền" — ĐỘC LẬP với sóng nhạc (bars) có bật hay không, dùng chung
    /// đường phân tích FFT nên phải tự `ensure` phổ khi bật (không còn ăn theo `setVisualizerEnabled`).
    private var beatZoomEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.project.backgroundMedia?.beatZoomEnabled ?? false },
            set: { on in
                store.perform(L("Nền zoom theo nhạc")) { store.project.backgroundMedia?.beatZoomEnabled = on }
                if on, let ref = store.project.audio, let url = AudioLoader.resolveURL(from: ref) {
                    SpectrumStore.ensure(for: url)
                }
            })
    }
    private var beatZoomAmountBinding: Binding<Double> {
        Binding(
            get: { store.project.backgroundMedia?.beatZoomAmount ?? 1.15 },
            set: { v in store.edit(L("Mức zoom theo nhạc")) { store.project.backgroundMedia?.beatZoomAmount = v } })
    }

    private func reloadBackgroundImage() {
        BackgroundImageStore.flush()   // ảnh đổi → bỏ bản đã chỉnh màu / làm mờ
        guard let media = store.project.backgroundMedia, let url = media.resolveURL() else {
            backgroundImage = nil
            bgVideoURL = nil
            return
        }
        switch media.kind {
        case .image:
            bgVideoURL = nil
            bgImageLoadToken = url                       // đánh dấu ảnh hiện hành
            DispatchQueue.global(qos: .userInitiated).async {
                let cg = Self.decodeImage(at: url)       // nạp + giải mã NGOÀI luồng chính
                DispatchQueue.main.async {
                    guard bgImageLoadToken == url else { return }   // ảnh đã đổi → bỏ kết quả cũ
                    backgroundImage = cg
                }
            }
        case .video:
            backgroundImage = nil
            bgVideoURL = url
        case .audio, .text:
            backgroundImage = nil
            bgVideoURL = nil
        }
    }

    /// Giải mã ảnh nền, chặn trên cạnh dài 3840px (đủ 4K, khỏi giữ ảnh 24MP trong RAM
    /// và khỏi vẽ lại ảnh khổng lồ mỗi khung preview).
    private static func decodeImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Xuất theo ô "Nền:" đang chọn:
    /// - Ô caro (trong suốt) → .mov ProRes 4444 (alpha, chỉ có chữ).
    /// - Đen / Xám → .mp4 H.264, nền màu đó.
    /// - Ảnh / Video nền → .mp4 H.264, ghép nền.
    private enum ExportOutput {
        case transparentMOV
        case solidMP4(CGColor)
        case imageMP4
        case videoMP4
        var isTransparent: Bool { if case .transparentMOV = self { return true }; return false }
    }

    private var exportOutput: ExportOutput {
        switch previewBackground {
        case .checker: return .transparentMOV
        case .dark:    return .solidMP4(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        case .gray:    return .solidMP4(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        case .media:
            if let media = store.project.backgroundMedia {
                if media.kind == .video, bgVideoURL != nil { return .videoMP4 }
                if media.kind == .image, backgroundImage != nil { return .imageMP4 }
            }
            return .transparentMOV
        }
    }

    private var transparentVideoBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Xuất video")).font(.headline)

            Picker(L("Khung hình"), selection: Binding<String>(
                get: {
                    let r = store.project.resolution
                    return VideoResolution.presets.first { $0.value.width == r.width && $0.value.height == r.height }?.name ?? "Tuỳ chỉnh"
                },
                set: { name in
                    if let preset = VideoResolution.presets.first(where: { $0.name == name }) {
                        store.perform(L("Đổi khung hình")) {
                            store.project.resolution.width = preset.value.width
                            store.project.resolution.height = preset.value.height
                        }
                    }
                }
            )) {
                ForEach(VideoResolution.presets, id: \.name) { Text($0.name).tag($0.name) }
                Text(L("Tuỳ chỉnh")).tag("Tuỳ chỉnh")
            }

            Picker("FPS", selection: Binding<Int>(
                get: { Int(store.project.resolution.fps.rounded()) },
                set: { newValue in store.perform(L("Đổi FPS")) { store.project.resolution.fps = Double(newValue) } }
            )) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0)").tag($0) }
            }

            if exportOutput.isTransparent {
                Text(L("Video trong suốt: .mov ProRes 4444 (chất lượng cao, xuất nhanh — file lớn)."))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Text(String(format: L("Dài ~%@"), TimeFormatting.clock(videoExportOutputDuration))
                 + (store.project.karaokeClipStart > 0.05
                    ? String(format: L(" · karaoke vào ở %@"), TimeFormatting.clock(store.project.karaokeClipStart)) : ""))
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)
            audioForVideoBlock

            if !exportOutput.isTransparent {
                Toggle(L("Xuất .mov ProRes (nền màu đục — cho dựng phim)"), isOn: $exportProRes)
                    .toggleStyle(.checkbox).font(.caption)
            }

            if videoExporter.isExporting {
                ProgressView(value: videoExporter.progress)
                HStack {
                    Text(videoExporter.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Huỷ")) { videoExporter.cancel() }
                }
            } else {
                Button(L("Xuất video…")) { exportTransparentVideo() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.project.hasAnyTiming)

                if store.project.visualizer?.enabled == true {
                    Button(L("Xuất riêng sóng nhạc (nền trong suốt)…")) { exportVisualizerOnly() }
                        .controlSize(.small)
                        .disabled(store.project.audio == nil)
                    Text(L("File .mov nền trong suốt, chỉ có sóng nhạc — chất lượng theo ô 'Chất lượng' ở trên. Ghép ở phần mềm khác."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let out = videoExporter.lastOutputURL, !videoExporter.isExporting, videoExporter.lastError == nil {
                HStack(spacing: 8) {
                    Text(String(format: L("Đã xuất: %@"), out.lastPathComponent)).font(.caption).foregroundStyle(.green)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Mở thư mục")) {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    }.controlSize(.small)
                }
            }
        }
    }

    /// Chọn âm thanh cho video xuất. Chọn "Chỉ beat" thì dùng bản beat đã tách trong máy.
    private var audioForVideoBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Âm thanh trong video")).font(.subheadline).bold()
                Spacer()
                Picker("", selection: $exportAudioChoice) {
                    ForEach(ExportAudioChoice.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            if exportAudioChoice == .original, resolvedAudioURL == nil {
                Text(L("⚠︎ Chưa nạp file nhạc."))
                    .font(.caption).foregroundStyle(.orange)
            }

            if exportAudioChoice == .beat { beatSeparationInline }
        }
    }

    /// Phần beat — chỉ hiện khi người dùng chọn "Chỉ beat (không lời)".
    /// Beat được tách ngay trong máy (MDX-Net), thường đã có sẵn từ bước tạo karaoke.
    @ViewBuilder
    private var beatSeparationInline: some View {
        VStack(alignment: .leading, spacing: 6) {
            if beatSepProxy.beatURL != nil, !beatSepProxy.isRunning {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("Đã có beat cho bài này.")).font(.caption)
                    Spacer()
                    Button(L("Tách lại")) { runBeatSeparation() }.controlSize(.small)
                }
            } else {
                Button {
                    runBeatSeparation()
                } label: {
                    if beatSepProxy.isRunning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Đang tách nhạc…")) }
                    } else {
                        Text(L("Tạo beat"))
                    }
                }
                .controlSize(.small)
                .disabled(beatSepProxy.isRunning || resolvedAudioURL == nil)

                Text(L("Khoảng 30–60 giây."))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if beatSepProxy.isRunning {
                ProgressView(value: beatSepProxy.throttledProgress)
            }
            if beatSepProxy.status.hasPrefix("❌") {
                Text(beatSepProxy.status).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelAlt))
    }

    private func runBeatSeparation() {
        guard let src = resolvedAudioURL else { return }
        Task { _ = await beatSep.separateLocal(source: src) }
    }

    /// Độ dài phần KARAOKE (fallback khi chưa có audio) — `TransparentVideoExporter` tự
    /// tính lại cắt + `karaokeClipStart` + lớp đè bên trong.
    private var videoExportDuration: TimeInterval {
        if playback.duration > 0 { return playback.duration }
        let lastEnd = store.project.lines.compactMap(\.end).max() ?? 0
        return lastEnd + 2
    }

    /// Độ dài FILE XUẤT thực tế — track kết thúc muộn nhất (clip ★ dời `karaokeClipStart`, lớp đè).
    private var videoExportOutputDuration: TimeInterval {
        let songLen = playback.duration > 0
            ? playback.duration
            : (store.project.lines.compactMap(\.end).max() ?? 0) + 2
        let tStart = max(0, store.project.audioTrimStart)
        let tEnd = store.project.audioTrimEnd > 0.05 ? min(store.project.audioTrimEnd, songLen) : songLen
        let effDur = max(0.1, tEnd - tStart)
        let K = max(0, store.project.karaokeClipStart)
        let overlayEnd = store.project.overlays.filter { !$0.isHidden }.map(\.end).max() ?? 0
        return max(K + effDur, overlayEnd, 0.1)
    }

    // MARK: - Nhập lời

    // MARK: - M-A · Selection + Command system

    /// Cái đang chọn — NGUỒN ĐỌC duy nhất (tính từ `selectedOverlayID` + `currentLineIndex`).
    var editorSelection: EditorSelection {
        if let id = selectedOverlayID, store.project.overlays.contains(where: { $0.id == id }) {
            return .overlay(id: id)
        }
        if store.project.lines.indices.contains(currentLineIndex) {
            return .lyricLine(index: currentLineIndex)
        }
        return .none
    }

    /// Đặt selection nhất quán qua 1 đường.
    func select(_ sel: EditorSelection) {
        switch sel {
        case .none:
            selectedOverlayID = nil
        case .overlay(let id):
            selectedOverlayID = id
        case .lyricLine(let i):
            selectedOverlayID = nil
            currentLineIndex = clampedIndex(i)
        }
    }

    func canRun(_ cmd: EditorCommand) -> Bool {
        switch cmd {
        case .playPause, .seekBy, .zoomIn, .zoomOut, .zoomToFit,
             .toggleLyricsHidden, .toggleMusicMuted,
             .newProject, .openProject, .saveProject, .saveProjectAs, .openNewTab:
            return true
        case .prevLine, .nextLine, .setLineStartAtPlayhead, .setLineEndAtPlayhead, .clearLineTiming:
            return !store.project.lines.isEmpty
        case .splitAtPlayhead, .copySelection:
            if case .overlay = editorSelection { return true }
            return false
        case .deleteSelection, .duplicateSelection, .nudgeSelection:
            return editorSelection != .none
        case .pasteClip:
            return copiedOverlay != nil
        case .pasteClipStyle:
            if copiedOverlay != nil, case .overlay = editorSelection { return true }
            return false
        }
    }

    /// Điểm vào DUY NHẤT cho lệnh editor. Trả `true` nếu đã xử lý.
    @discardableResult
    func runCommand(_ cmd: EditorCommand) -> Bool {
        guard canRun(cmd) else { return false }
        let idx = clampedIndex(currentLineIndex)
        switch cmd {
        case .playPause:
            playback.togglePlayPause()
        case .seekBy(let d):
            seekTo(max(0, playback.currentTime + d))
        case .prevLine:
            moveCurrentLine(-1)
        case .nextLine:
            moveCurrentLine(1)
        case .setLineStartAtPlayhead:
            setStartToPlayhead(idx)
        case .setLineEndAtPlayhead:
            setEndToPlayhead(idx)
        case .clearLineTiming:
            clearLine(idx)
        case .splitAtPlayhead:
            if case .overlay(let id) = editorSelection {
                timelineOverlaySplit(id, playback.currentTime)
            }
        case .deleteSelection:
            if selectedOverlayIDs.count > 1 {
                let ids = selectedOverlayIDs
                store.perform(L("Xoá lớp đè")) { store.project.overlays.removeAll { ids.contains($0.id) }; pruneOverlayGroups() }
                selectedOverlayIDs = []; selectedOverlayID = nil
            } else {
                switch editorSelection {
                case .overlay(let id): removeOverlay(id)
                case .lyricLine(let i): clearLine(clampedIndex(i))
                case .none: break
                }
            }
        case .duplicateSelection:
            switch editorSelection {
            case .overlay(let id):
                timelineOverlayDuplicate(id)
            case .lyricLine(let i):
                if store.project.lines.indices.contains(i) {
                    timelineDuplicateLines([store.project.lines[i].id])
                }
            case .none: break
            }
        case .nudgeSelection(let d):
            switch editorSelection {
            case .overlay(let id):
                if let c = store.project.overlays.first(where: { $0.id == id }) {
                    timelineOverlayMove(id, max(0, c.start + d), c.lane)
                }
            case .lyricLine(let i):
                if store.project.lines.indices.contains(i) {
                    timelineNudgeLines([store.project.lines[i].id], d)
                }
            case .none: break
            }
        case .zoomIn:
            timelineZoom = min(400, timelineZoom * 1.4)
        case .zoomOut:
            timelineZoom = max(2, timelineZoom / 1.4)
        case .zoomToFit:
            timelineFitToWindow()
        case .toggleLyricsHidden:
            let h = store.project.lyricsHidden
            store.perform(h ? L("Hiện lời") : L("Ẩn lời")) { store.project.lyricsHidden.toggle() }
        case .toggleMusicMuted:
            let m = store.project.audioMuted
            store.perform(m ? L("Bật tiếng nhạc") : L("Tắt tiếng nhạc")) { store.project.audioMuted.toggle() }
        case .newProject:
            store.newProject(); store.prepareNewInLibrary(); playback.unload()
        case .openProject:
            openProjectFromPanel()
        case .saveProject:
            saveProject()
        case .saveProjectAs:
            saveProjectAs()
        case .openNewTab:
            onOpenNewTab?()
        case .copySelection:
            if case .overlay(let id) = editorSelection {
                copiedOverlay = store.project.overlays.first { $0.id == id }
            }
        case .pasteClip:
            guard var c = copiedOverlay else { break }
            c.id = UUID()
            c.start = max(0, playback.currentTime)
            c.lane = freeOverlayLane(start: c.start, end: c.start + c.duration)
            store.perform(L("Dán clip")) { store.project.overlays.append(c) }
            selectedOverlayID = c.id
        case .pasteClipStyle:
            guard let src = copiedOverlay, case .overlay(let id) = editorSelection,
                  let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { break }
            store.perform(L("Dán thuộc tính clip")) {
                var c = store.project.overlays[i]
                c.opacity = src.opacity; c.blendRaw = src.blendRaw; c.aboveText = src.aboveText
                c.colorAdjust = src.colorAdjust
                c.scale = src.scale; c.rotation = src.rotation
                c.offsetX = src.offsetX; c.offsetY = src.offsetY
                c.fadeIn = min(src.fadeIn, c.duration); c.fadeOut = min(src.fadeOut, c.duration)
                store.project.overlays[i] = c
            }
        }
        return true
    }

    // MARK: - Phím tắt

    private func handleKeyDown(_ key: KeyDownMonitor.KeyPress) -> Bool {
        if key.hasCommand, key.character == "z" {
            if key.hasShift {
                store.undoManager.redo()
            } else {
                let name = store.undoManager.undoActionName
                let wasStageDrop = lastStageDrop != nil && (name == L("Thêm chữ") || name == L("Thêm dòng"))
                store.undoManager.undo()
                if wasStageDrop, let p = lastStageDrop {
                    restageItem = p; restageTick += 1; lastStageDrop = nil
                }
            }
            return true
        }

        let timelineFocused: Bool = {
            guard let v = NSApp.keyWindow?.firstResponder as? NSView else { return false }
            return v.identifier?.rawValue == "KMTimelineCanvas"
        }()

        // ⌘C / ⌘V cho CLIP lớp đè — chỉ khi KHÔNG ở trong timeline (timeline tự lo copy dòng lời).
        if key.hasCommand, !key.hasShift, !timelineFocused {
            if key.character == "c", case .overlay = editorSelection {
                return runCommand(.copySelection)
            }
            if key.character == "v", copiedOverlay != nil {
                return runCommand(.pasteClip)
            }
        }
        guard !key.hasCommandOptionControl else { return false }

        switch key.character {
        case " ": return runCommand(.playPause)
        // T / Y (canh giờ thủ công) đã bỏ — sẽ gán phím mới khi làm lại chế độ thủ công.
        case "[": return runCommand(.prevLine)
        case "]": return runCommand(.nextLine)
        case "\u{f702}":                             // ← : tua lùi
            if timelineFocused { return false }      // canvas tự lo nudge dòng lời khi focus
            return runCommand(.seekBy(key.hasShift ? -1.0 : -0.1))
        case "\u{f703}":                             // → : tua tới
            if timelineFocused { return false }
            return runCommand(.seekBy(key.hasShift ? 1.0 : 0.1))
        case ",", "<": return runCommand(.nudgeSelection(-0.1))   // dời mục đang chọn
        case ".", ">": return runCommand(.nudgeSelection(0.1))
        case "\u{7f}", "\u{8}", "\u{f728}":   // Delete / Backspace / Forward-delete
            if case .overlay = editorSelection {
                return runCommand(.deleteSelection)   // đang chọn ảnh/logo → xoá nó
            }
            if timelineFocused { return false }        // đang chọn 1 ô chữ → để timeline xoá chữ đó
            return runCommand(.deleteSelection)        // xoá timing dòng đang chọn
        case "r" where key.hasShift: clearAllTiming(); return true
        default: return false
        }
    }

    private func endNameEditing() {
        isNameFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func defocusTextEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Hành động timing

    private func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), max(store.project.lines.count - 1, 0))
    }

    /// Bấm T — vào câu, sang dòng kế.
    private func markTap() {
        guard !store.project.lines.isEmpty else { return }
        clearedTimingBackup = nil
        let tapped = clampedIndex(currentLineIndex)
        var newIndex = currentLineIndex
        store.perform(L("Vào câu")) {
            newIndex = TimingEditor.tap(
                lines: &store.project.lines,
                at: tapped,
                time: playheadSongTime,
                leadIn: store.project.tapLeadIn
            )
        }
        currentLineIndex = clampedIndex(newIndex)

        // Dòng vừa bấm T có bắt đầu nhưng chưa có kết thúc -> chờ T kế;
        // nếu quá lâu (tapTimeoutSeconds) mà không bấm T thì tự reset dòng đó.
        if store.project.lines.indices.contains(tapped),
           store.project.lines[tapped].start != nil,
           store.project.lines[tapped].end == nil {
            pendingTapLine = tapped
            pendingTapDeadline = playback.currentTime + tapTimeoutSeconds
        } else {
            clearPendingTap()
        }
    }

    /// Bấm Y — chốt (tạm) điểm kết thúc của câu đang ghi dở.
    private func markEndOfLine() {
        let target = pendingTapLine
            ?? store.project.lines.firstIndex { $0.start != nil && $0.end == nil }
        guard let index = target, store.project.lines.indices.contains(index) else { return }
        store.perform(L("Kết thúc câu")) {
            TimingEditor.setEnd(lines: &store.project.lines, at: index, time: playheadSongTime)
        }
        clearPendingTap()
    }

    private func moveCurrentLine(_ delta: Int) {
        currentLineIndex = clampedIndex(currentLineIndex + delta)
        clearPendingTap()
    }

    private func jumpToFirstUntimed() {
        if let index = TimingEditor.firstUntimedIndex(store.project.lines) {
            currentLineIndex = index
        }
    }

    private func listenFromCurrentLine() {
        let index = clampedIndex(currentLineIndex)
        guard store.project.lines.indices.contains(index) else { return }
        // `target` = giây TRONG BÀI; tua playback (giờ-timeline) = target + mốc clip ★.
        let target = store.project.lines[index].start ?? playheadSongTime
        playback.seek(to: max(0, target - 0.5) + store.project.karaokeClipStart)
        playback.play()
    }

    /// Tab "Sửa lời" — có dòng canh xong rồi thì KHÔNG quay lại "Tạo Karaoke" nữa
    /// (trừ lúc đang đứng ở đó: vừa tạo xong, chờ tự chuyển sang "Nền video").
    private var showStepsTab: Bool { !aiLinesTimed || leftPanelTab == .steps }

    /// Bấm vào 1 dòng ở tab "Sửa lời": chọn dòng + đưa vạch đỏ tới đầu dòng (KHÔNG tự phát nhạc).
    private func focusLyricLine(_ index: Int) {
        guard store.project.lines.indices.contains(index) else { return }
        currentLineIndex = index
        if let start = store.project.lines[index].start {
            playback.seek(to: start + store.project.karaokeClipStart)
        }
    }

    /// Chốt chữ mới của 1 dòng (tab "Sửa lời" + ô "Nội dung dòng"): dựng lại các ô chữ, GIỮ timing,
    /// 1 bước hoàn tác. Chữ rỗng / không đổi → bỏ qua (không bao giờ xoá dòng).
    private func commitLyricEdit(_ id: UUID, _ raw: String) {
        guard let i = store.project.lines.firstIndex(where: { $0.id == id }),
              let updated = LyricLineEditor.apply(raw, to: store.project.lines[i]) else { return }
        store.perform(L("Sửa lời dòng")) { store.project.lines[i] = updated }
    }

    private func seekToLineStart(_ index: Int) {
        guard store.project.lines.indices.contains(index),
              let start = store.project.lines[index].start else { return }
        playback.seek(to: start + store.project.karaokeClipStart)   // start = giây trong bài
        playback.play()
    }


    private func nudgeStart(_ index: Int, _ delta: Double) {
        store.perform(L("Chỉnh điểm bắt đầu")) {
            TimingEditor.nudgeStart(lines: &store.project.lines, at: index, by: delta)
        }
    }

    private func nudgeEnd(_ index: Int, _ delta: Double) {
        store.perform(L("Chỉnh điểm kết thúc")) {
            TimingEditor.nudgeEnd(lines: &store.project.lines, at: index, by: delta)
        }
    }

    private func setStartToPlayhead(_ index: Int) {
        store.perform(L("Đặt điểm bắt đầu")) {
            TimingEditor.setStart(lines: &store.project.lines, at: index, to: playheadSongTime)
        }
    }

    private func setEndToPlayhead(_ index: Int) {
        store.perform(L("Đặt điểm kết thúc")) {
            TimingEditor.setEndTo(lines: &store.project.lines, at: index, to: playheadSongTime)
        }
    }

    private func setLineStartTime(_ index: Int, _ time: TimeInterval) {
        store.perform(L("Sửa điểm bắt đầu")) {
            TimingEditor.setStart(lines: &store.project.lines, at: index, to: time)
        }
    }

    private func setLineEndTime(_ index: Int, _ time: TimeInterval) {
        store.perform(L("Sửa điểm kết thúc")) {
            TimingEditor.setEndTo(lines: &store.project.lines, at: index, to: time)
        }
    }

    private func clearLine(_ index: Int) {
        store.perform(L("Xoá timing dòng")) {
            TimingEditor.clear(lines: &store.project.lines, at: index)
        }
        clearPendingTap()
    }

    private func setLineText(_ index: Int, _ newText: String) {
        guard store.project.lines.indices.contains(index) else { return }
        store.edit(L("Sửa lời dòng")) { store.project.lines[index].text = newText }
    }

    private func timelineApplyChanges(_ changes: [(Int, Double, Double)]) {
        store.perform(L("Kéo dòng trên timeline")) {
            for (index, newStart, newEnd) in changes {
                guard store.project.lines.indices.contains(index) else { continue }
                let oldS = store.project.lines[index].start ?? newStart
                let oldE = store.project.lines[index].end ?? newEnd
                let start = max(0, newStart)
                let end = max(start + 0.05, newEnd)
                let dS = start - oldS, dE = end - oldE

                // DỜI cả câu (2 mép nhích cùng lượng) → chữ đi theo.
                // KÉO 1 MÉP (chỉ 1 đầu đổi) → chữ ĐỨNG YÊN, chỉ phần chờ đầu / đuôi dài ra.
                if abs(dS - dE) < 0.001 {
                    for j in store.project.lines[index].words.indices {
                        if let ws = store.project.lines[index].words[j].start {
                            store.project.lines[index].words[j].start = max(0, ws + dS)
                        }
                        if let we = store.project.lines[index].words[j].end {
                            store.project.lines[index].words[j].end = max(0, we + dS)
                        }
                    }
                    store.project.lines[index].start = start
                    store.project.lines[index].end = end
                } else {
                    // Kéo 1 mép: KHÔNG để mép cắt vào chữ (chữ luôn nằm trong khối).
                    let fw = store.project.lines[index].words.first?.start
                    let lw = store.project.lines[index].words.last?.end
                    store.project.lines[index].start = min(start, fw ?? start)
                    store.project.lines[index].end = max(end, lw ?? end)
                }
            }
        }
    }

    // MARK: - Sửa CHỮ trực quan trên timeline (chỉ đổi words + text)

    /// Double-click phần DÒNG → rải lời mới vào các ô chữ ĐANG CÓ, giữ nguyên mốc timing.
    /// Đúng số chữ → thay 1-1. Dư chữ → gộp phần dư vào ô CUỐI. Thiếu → ô cuối để trống.
    private func timelineLineTextRemap(_ i: Int, _ raw: String) {
        guard store.project.lines.indices.contains(i) else { return }
        let toks = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\u{a0}" })
            .map(String.init)
        store.perform(L("Sửa lời dòng")) {
            var l = store.project.lines[i]
            if l.words.isEmpty {
                l.text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let n = l.words.count
                for k in 0..<n {
                    if k < n - 1 {
                        l.words[k].text = k < toks.count ? toks[k] : ""
                    } else {                                   // ô CUỐI: nuốt hết phần dư
                        l.words[k].text = toks.count > k ? toks[k...].joined(separator: " ") : ""
                    }
                }
                l.text = l.words.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            }
            store.project.lines[i] = l
        }
    }

    private func timelineWordsCommit(_ i: Int, _ words: [LyricWord], _ text: String) {
        guard store.project.lines.indices.contains(i) else { return }
        store.perform(L("Sửa chữ trên timeline")) {
            store.project.lines[i].words = words
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                store.project.lines[i].text = text
            }
            if let ws = words.first?.start, ws < (store.project.lines[i].start ?? ws) {
                store.project.lines[i].start = max(0, ws)
            }
            if let we = words.last?.end, we > (store.project.lines[i].end ?? we) {
                store.project.lines[i].end = we
            }
        }
    }

    private func timelineRedistributeWords(_ i: Int) {
        guard store.project.lines.indices.contains(i), !store.project.lines[i].words.isEmpty else { return }
        store.perform(L("Chia đều chữ")) {
            var l = store.project.lines[i]
            var tmp = l
            tmp.start = l.words.first?.start ?? l.start
            tmp.end = l.words.last?.end ?? l.end
            l.words = WordTiming.distribute(tmp)
            store.project.lines[i] = l
        }
    }

    /// Thêm 1 chữ RỖNG ~1 giây tại vạch đỏ (playhead), CHÈN vào câu `i` (không tạo câu mới).
    /// Kéo ô chữ TẠM thả vào dòng `li` tại [s,e]. Chèn thành chữ mới, đẩy/thu hàng xóm.
    private func timelineStageWordDrop(_ li: Int, _ s: Double, _ e: Double, _ text: String) {
        guard store.project.lines.indices.contains(li) else { return }
        store.perform(L("Thêm chữ")) {
            var l = store.project.lines[li]
            var ws = l.words
            let at = ws.firstIndex { ($0.start ?? .greatestFiniteMagnitude) > s } ?? ws.count
            var ns = max(0, s), ne = max(ns + 0.08, e)
            let m = 0.08
            if at > 0, let pe = ws[at - 1].end, ns < pe {                 // đè chữ trước → thu nó
                let pmin = (ws[at - 1].start ?? 0) + m
                ws[at - 1].end = max(pmin, ns)
                if ns < pmin { ns = pmin; ne = max(ne, ns + 0.08) }
            }
            if at < ws.count, let nsx = ws[at].start, ne > nsx {          // đè chữ sau → thu nó
                let nmax = (ws[at].end ?? nsx) - m
                ws[at].start = min(nmax, ne)
                if ne > nmax { ne = nmax; ns = min(ns, ne - 0.08) }
            }
            ws.insert(LyricWord(text: text.isEmpty ? "…" : text, start: ns, end: ne), at: at)
            l.words = ws
            l.start = min(l.start ?? ns, ws.first?.start ?? ns)
            l.end = max(l.end ?? ne, ws.last?.end ?? ne)
            l.text = ws.map(\.text).joined(separator: " ")
            store.project.lines[li] = l
        }
        lastStageDrop = .init(isLine: false, start: s, end: e,
                              text: text.isEmpty ? "…" : text, words: [])
    }

    /// Kéo DÒNG TẠM thả xuống track chính tại [s,e] với các chữ đã chia đều.
    private func timelineStageLineDrop(_ s: Double, _ e: Double, _ words: [LyricWord], _ text: String) {
        store.perform(L("Thêm dòng")) {
            var line = LyricLine(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 start: max(0, s), end: max(s + 0.2, e), source: .auto)
            line.words = words
            store.project.lines.append(line)
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        currentLineIndex = store.project.lines.firstIndex { abs(($0.start ?? -1) - s) < 0.01 } ?? currentLineIndex
        lastStageDrop = .init(isLine: true, start: s, end: e, text: text, words: words)
    }

    /// Thêm 1 ô chữ "…" vào dòng `i` ĐÚNG chỗ playhead (vạch đỏ). Rộng ~0.4s.
    /// KHÔNG chồng chữ khác, KHÔNG tràn ra ngoài dòng — kẹt vào khe giữa 2 chữ hàng xóm.
    func timelineAddWordAtPlayhead(_ i: Int) {
        guard store.project.lines.indices.contains(i) else { return }
        let T = playheadSongTime
        store.perform(L("Thêm chữ")) {
            var l = store.project.lines[i]
            var ws = l.words

            // Chèn TRƯỚC chữ đầu tiên bắt đầu sau playhead.
            let at = ws.firstIndex { ($0.start ?? .greatestFiniteMagnitude) > T } ?? ws.count
            let leftBound = at > 0
                ? (ws[at - 1].end ?? ws[at - 1].start ?? 0)
                : max(0, l.start ?? T)
            let rightBound = at < ws.count
                ? (ws[at].start ?? .greatestFiniteMagnitude)
                : max((l.end ?? T + 0.5), leftBound + 0.5)

            var s = min(max(T, leftBound), rightBound)
            var e = min(s + 0.4, rightBound)
            if e - s < 0.08 {                       // khe hẹp → lùi start để đủ 0.15s tối thiểu
                s = max(leftBound, rightBound - 0.15)
                e = max(rightBound, s + 0.08)
            }
            ws.insert(LyricWord(text: "…", start: s, end: e), at: at)

            l.words = ws
            l.start = min(l.start ?? s, ws.first?.start ?? s)
            l.end = max(l.end ?? e, ws.last?.end ?? e)
            l.text = ws.map { $0.text }.joined(separator: " ")
            store.project.lines[i] = l
        }
    }

    /// Thêm 1 câu MỚI 5 giây tại `t`. Chỉ nhích mép 2 block hàng xóm bị đè;
    /// KHÔNG chạy lại canh giờ, KHÔNG đụng chữ/nhịp câu khác.
    private func timelineAddLine(_ t: Double) {
        let d = 5.0
        let T = max(0, t)
        let newLine = LyricLine(text: "", start: T, end: T + d, source: .auto)
        let newID = newLine.id
        store.perform(L("Thêm câu mới")) {
            var ls = store.project.lines
            for i in ls.indices {
                guard let s = ls[i].start, let e = ls[i].end else { continue }
                // Chỉ NHÍCH MÉP block hàng xóm, KHÔNG đụng words của chúng.
                if s <= T && e > T + 0.05 { ls[i].end = max(s + 0.1, T) }          // phủ T → cắt end
                if s >= T && s < T + d {
                    if e <= T + d {                                                // nằm gọn → dời hẳn
                        let sh = (T + d) - s
                        ls[i].start = s + sh; ls[i].end = e + sh
                        ls[i].words = shiftWords(ls[i].words, by: sh)
                    } else {
                        ls[i].start = T + d                                        // ló đuôi → đẩy start
                    }
                }
            }
            ls.append(newLine)
            ls.sort { ($0.start ?? 0) < ($1.start ?? 0) }
            store.project.lines = ls
        }
        if let idx = store.project.lines.firstIndex(where: { $0.id == newID }) {
            currentLineIndex = idx
            seekTo(T + store.project.karaokeClipStart)   // T = giây trong bài → giờ-timeline
        }
    }

    private func shiftWords(_ words: [LyricWord], by d: Double) -> [LyricWord] {
        words.map { var w = $0; if let s = w.start { w.start = s + d }; if let e = w.end { w.end = e + d }; return w }
    }

    /// Dán lời (clipboard) cho câu `i` → chia đều mốc cho từng chữ (CHỈ câu này).
    private func timelinePasteLine(_ i: Int) {
        guard store.project.lines.indices.contains(i),
              let s = store.project.lines[i].start, let e = store.project.lines[i].end else { return }
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { store.lastError = L("Clipboard trống — hãy copy lời trước."); return }
        store.perform(L("Dán lời câu mới")) {
            var l = store.project.lines[i]
            l.text = clean
            var tmp = l; tmp.start = s; tmp.end = e
            l.words = WordTiming.distribute(tmp)
            store.project.lines[i] = l
        }
    }

    // MARK: - Timeline P1: chọn nhiều · dời · xoá · copy/paste · nhân bản · nudge

    /// Bản sao 1 câu, DỜI toàn bộ mốc theo `d` giây, cấp `id` mới.
    private func shiftedCopy(_ src: LyricLine, by d: Double) -> LyricLine {
        var l = LyricLine(text: src.text,
                          start: src.start.map { max(0, $0 + d) },
                          end: src.end.map { max(0.05, $0 + d) },
                          source: src.source)
        l.words = src.words.map {
            var w = $0
            if let s = w.start { w.start = max(0, s + d) }
            if let e = w.end { w.end = max(0, e + d) }
            return w
        }
        return l
    }

    /// Dời nhiều block cùng lúc (kéo thân). Mỗi phần tử: (id, startMới, endMới).
    private func timelineMoveLines(_ changes: [(UUID, Double, Double)]) {
        guard !changes.isEmpty else { return }
        store.perform(L("Dời câu trên timeline")) {
            for (id, ns, ne) in changes {
                guard let i = store.project.lines.firstIndex(where: { $0.id == id }) else { continue }
                let oldS = store.project.lines[i].start ?? ns
                let dS = max(0, ns) - oldS
                store.project.lines[i].start = max(0, ns)
                store.project.lines[i].end = max(max(0, ns) + 0.05, ne)
                store.project.lines[i].words = shiftWords(store.project.lines[i].words, by: dS)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        syncSelectionIndex()
    }

    private func timelineDeleteLines(_ ids: [UUID]) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        store.perform(L("Xoá câu")) {
            store.project.lines.removeAll { set.contains($0.id) }
        }
        currentLineIndex = min(currentLineIndex, max(0, store.project.lines.count - 1))
    }

    private func timelineCopyLines(_ ids: [UUID]) {
        let set = Set(ids)
        let picked = store.project.lines.filter { set.contains($0.id) }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        guard !picked.isEmpty else { return }
        timelineClipboard = picked
    }

    /// Dán clipboard tại vạch đỏ, GIỮ khoảng cách tương đối giữa các câu đã copy.
    private func timelinePasteAtPlayhead() {
        guard !timelineClipboard.isEmpty else {
            store.lastError = L("Chưa copy câu nào (chọn câu rồi ⌘C)."); return
        }
        let base = timelineClipboard.first?.start ?? 0
        let shift = playheadSongTime - base
        var newIDs: [UUID] = []
        store.perform(L("Dán câu")) {
            for src in timelineClipboard {
                let l = shiftedCopy(src, by: shift)
                newIDs.append(l.id)
                store.project.lines.append(l)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        if let first = newIDs.first,
           let idx = store.project.lines.firstIndex(where: { $0.id == first }) {
            currentLineIndex = idx
        }
    }

    /// Nhân bản: đặt bản sao ngay SAU nhóm đang chọn.
    private func timelineDuplicateLines(_ ids: [UUID]) {
        let set = Set(ids)
        let picked = store.project.lines.filter { set.contains($0.id) }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        guard let firstS = picked.first?.start, let lastE = picked.last?.end else { return }
        let shift = (lastE - firstS) + 0.3
        var newIDs: [UUID] = []
        store.perform(L("Nhân bản câu")) {
            for src in picked {
                let l = shiftedCopy(src, by: shift)
                newIDs.append(l.id)
                store.project.lines.append(l)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        if let first = newIDs.first,
           let idx = store.project.lines.firstIndex(where: { $0.id == first }) {
            currentLineIndex = idx
        }
    }

    /// ← → : dời sớm/trễ các câu đang chọn (Shift = 0.5s, thường = 0.1s).
    private func timelineNudgeLines(_ ids: [UUID], _ d: Double) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        store.perform(d < 0 ? L("Dời sớm") : L("Dời trễ")) {
            for i in store.project.lines.indices where set.contains(store.project.lines[i].id) {
                guard let s = store.project.lines[i].start else { continue }
                let dd = max(d, -s)
                store.project.lines[i].start = s + dd
                if let e = store.project.lines[i].end { store.project.lines[i].end = e + dd }
                store.project.lines[i].words = shiftWords(store.project.lines[i].words, by: dd)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        syncSelectionIndex()
    }

    private func syncSelectionIndex() {
        guard store.project.lines.indices.contains(currentLineIndex) else {
            currentLineIndex = max(0, store.project.lines.count - 1); return
        }
    }

    /// P3: kéo mốc BẮT ĐẦU từng chữ của câu `i` về nhịp giọng hát dò được (onset).
    /// Dùng bản vocal đã tách nếu có, không thì bản gốc. End nối tiếp start chữ sau.
    private func timelineSnapWordsToOnset(_ i: Int) {
        guard store.project.lines.indices.contains(i) else { return }
        let line = store.project.lines[i]
        guard !line.words.isEmpty, let s = line.start, let e = line.end, e > s else { return }
        guard let url = beatSepProxy.vocalURL ?? resolvedAudioURL else {
            store.lastError = L("Chưa có file audio/vocal để dò nhịp."); return
        }
        let n = line.words.count
        timelineSnapBusy = true
        Task.detached {
            let hits = AudioOnsetDetector.onsets(url: url, start: s - 0.35, end: e + 0.35,
                                                 maxCount: max(8, n * 3))
            await MainActor.run {
                timelineSnapBusy = false
                guard hits.count >= 2 else {
                    store.lastError = L("Không dò đủ nhịp trong đoạn câu này (nhạc to / giọng nhỏ).")
                    return
                }
                guard store.project.lines.indices.contains(i),
                      store.project.lines[i].words.count == n else { return }
                store.perform(L("Khớp chữ vào nhịp")) {
                    var w = store.project.lines[i].words
                    for k in w.indices {
                        guard let ws = w[k].start else { continue }
                        if let near = hits.min(by: { abs($0 - ws) < abs($1 - ws) }),
                           abs(near - ws) < 0.45 {
                            w[k].start = near
                        }
                    }
                    // ép tăng dần + end chữ = start chữ kế
                    for k in w.indices {
                        if k > 0, let ps = w[k - 1].start, let cs = w[k].start, cs <= ps + 0.03 {
                            w[k].start = ps + 0.06
                        }
                        if k > 0 { w[k - 1].end = w[k].start }
                    }
                    if let lastS = w.last?.start { w[w.count - 1].end = max(lastS + 0.06, e) }
                    if let f = w.first?.start, f < (store.project.lines[i].start ?? f) {
                        store.project.lines[i].start = max(0, f)
                    }
                    store.project.lines[i].words = w
                }
            }
        }
    }

    private func clearAllTiming() {
        guard store.project.hasAnyTiming else { return }
        clearedTimingBackup = store.project.lines
        store.perform(L("Reset toàn bộ timing")) {
            TimingEditor.clearAll(lines: &store.project.lines)
        }
    }

    private func restoreClearedTiming() {
        guard let backup = clearedTimingBackup else { return }
        store.perform(L("Hoàn tác xoá timing")) {
            store.project.lines = backup
        }
        clearedTimingBackup = nil
    }

    // MARK: - Audio

    private func importAudio() {
        guard let url = FilePanels.chooseAudioToImport() else { return }
        loadAudio(from: url)
    }

    /// Nạp 1 file nhạc (từ nút Chọn HOẶC kéo–thả từ Finder).
    private func loadAudio(from url: URL) {
        if beatSepProxy.usingUserStems {
            store.lastError = L("Đang dùng beat + vocal bạn đưa vào. Bấm \"Bỏ\" ở phần dưới trước nếu muốn dùng file nhạc thường.")
            return
        }
        let ok = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac"]
        guard ok.contains(url.pathExtension.lowercased()) else {
            store.lastError = L("Chỉ nhận file nhạc (MP3, WAV, M4A…).")
            return
        }
        let reference = AudioLoader.makeReference(for: url)
        store.perform(L("Import nhạc")) {
            store.project.audio = reference
            if store.project.name == "Untitled" {
                store.project.name = url.deletingPathExtension().lastPathComponent
            }
        }
        playback.load(url: url)
        beatSep.refresh(for: url)
        SpectrumStore.ensure(for: url)          // sẵn phổ cho "sóng nhạc"
    }

    /// Nhận file nhạc thả từ Finder vào (dùng ở bước ①).
    private func handleAudioDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { loadAudio(from: url) }
        }
        return true
    }

    private func syncPlaybackWithProject() {
        guard let audio = store.project.audio else { playback.unload(); beatSep.refresh(for: nil); return }
        if let url = AudioLoader.resolveURL(from: audio) {
            playback.load(url: url)
            adoptOrRefreshBeatSep(for: url)
        } else {
            playback.unload()
            beatSep.refresh(for: nil)
        }
    }

    /// Ưu tiên vocal/beat GÓI SẴN trong project (`vocalStem`/`beatStem`, xem `ProjectPackage`) —
    /// mở ở máy chưa có cache tách nhạc riêng cho bài này vẫn dùng được ngay. Không có (project
    /// cũ, hoặc chưa tách bao giờ) → quét cache máy này như cũ.
    private func adoptOrRefreshBeatSep(for source: URL?) {
        let v = store.project.vocalStem.flatMap(AudioLoader.resolveURL(from:))
        let b = store.project.beatStem.flatMap(AudioLoader.resolveURL(from:))
        if beatSep.adoptFromProject(vocal: v, beat: b) { return }
        beatSep.refresh(for: source)
    }

    // MARK: - Nhập lời

    private func clearLyricsBox() {
        guard !store.project.rawLyrics.isEmpty else { return }
        clearedLyricsBackup = store.project.rawLyrics
        store.perform(L("Xoá ô lời")) { store.project.rawLyrics = "" }
        lyricsImportNote = nil
    }

    private func importLyrics() {
        guard let url = FilePanels.chooseLyricsToImport() else { return }

        // .ass / .ssa — đọc riêng (có thể kèm mốc từng chữ \k).
        let ext = url.pathExtension.lowercased()
        if ext == "ass" || ext == "ssa" {
            guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url)) else {
                store.lastError = L("Không đọc được file \(url.lastPathComponent).")
                return
            }
            let lines = AssParser.parse(raw)
            guard !lines.isEmpty else { store.lastError = L("File ASS không có dòng hợp lệ."); return }
            let joined = lines.map(\.text).joined(separator: "\n")
            if store.project.lines.contains(where: { $0.isTimed }) {
                pendingReplace = .srt(lines: lines, joined: joined)
                showReplaceLinesAlert = true
            } else {
                applySrt(lines: lines, joined: joined, source: url.lastPathComponent)
            }
            defocusTextEditing()
            return
        }

        do {
            let outcome = try TextImport.load(from: url)
            switch outcome {
            case .plainText(let text):
                store.perform(L("Nạp lời từ file")) { store.project.rawLyrics = text }
                clearedLyricsBackup = nil
                lyricsImportNote = String(format: L("Đã nạp lời từ %@. Bấm \"Tách thành dòng\"."), url.lastPathComponent)
            case .timedLines(let lines, let joined):
                guard !lines.isEmpty else {
                    store.lastError = L("File SRT không có dòng hợp lệ.")
                    return
                }
                if store.project.lines.contains(where: { $0.isTimed }) {
                    pendingReplace = .srt(lines: lines, joined: joined)
                    showReplaceLinesAlert = true
                } else {
                    applySrt(lines: lines, joined: joined, source: url.lastPathComponent)
                }
            }
        } catch {
            store.lastError = error.localizedDescription
        }
        defocusTextEditing()
    }

    private func performPendingReplace() {
        switch pendingReplace {
        case .splitFromText: applyLyricsSplit()
        case .srt(let lines, let joined): applySrt(lines: lines, joined: joined, source: "SRT")
        case .none: break
        }
        pendingReplace = nil
    }

    private func applyLyricsSplit() {
        let texts = LyricsParser.split(store.project.rawLyrics)
        store.perform(L("Tách thành dòng")) {
            store.project.lines = texts.map { LyricLine(text: $0) }
        }
        lyricsImportNote = nil
        currentLineIndex = 0
        defocusTextEditing()
    }

    private func applySrt(lines: [LyricLine], joined: String, source: String) {
        var ls = lines
        TimingEditor.removeOverlaps(lines: &ls)
        // SRT không có mốc chữ → chia đều. ASS có sẵn \k → GIỮ.
        for i in ls.indices where ls[i].isTimed && ls[i].words.isEmpty {
            ls[i].words = WordTiming.distribute(ls[i])
        }
        TimingEditor.makeContiguous(lines: &ls)     // block khít nhau; words = khoảng hát thật

        store.perform(L("Nhập lời từ \(source)")) {
            store.project.lines = ls
            store.project.rawLyrics = joined
        }
        currentLineIndex = 0
        clearedLyricsBackup = nil
        lyricsImportNote = String(format: L("Đã nhập %d dòng kèm timing từ %@."), ls.count, source)
    }

    // MARK: - Xuất

    private func exportSRT() {
        let content = SrtExporter.makeSRT(from: store.project)
        guard !content.isEmpty else {
            store.lastError = L("Chưa có dòng nào có timing để export.")
            return
        }
        guard let url = FilePanels.chooseSRTSaveLocation(defaultName: store.project.name) else { return }

        var data = Data()
        if store.project.exportSettings.srtIncludeBOM {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(Data(content.utf8))

        do {
            try data.write(to: url, options: .atomic)
            store.project.exportSettings.lastMode = .srt
            store.markDirty()
            exportNote = String(format: L("Đã xuất %d dòng ra %@"), SrtExporter.timedCues(from: store.project).count, url.lastPathComponent)
        } catch {
            store.lastError = L("Không ghi được file SRT: \(error.localizedDescription)")
        }
    }

    private func exportASS() {
        let content = AssExporter.make(from: store.project)
        guard let url = FilePanels.chooseASSSaveLocation(defaultName: store.project.name) else { return }
        do {
            try Data(content.utf8).write(to: url, options: .atomic)
            store.markDirty()
            exportNote = String(format: L("Đã xuất phụ đề karaoke ra %@"), url.lastPathComponent)
        } catch {
            store.lastError = L("Không ghi được file .ass: \(error.localizedDescription)")
        }
    }

    private func exportTransparentVideo() {
        clearColorBypass()   // an toàn: không xuất ở chế độ "xem bản gốc"
        let output = exportOutput

        // Xác định file âm thanh sẽ ghép vào video.
        let audioForExport: URL?
        switch exportAudioChoice {
        case .none:
            audioForExport = nil
        case .original:
            audioForExport = resolvedAudioURL
        case .beat:
            guard let beat = beatSepProxy.beatURL else {
                store.lastError = L("Chưa có beat. Bấm \"Tạo beat\" ở trên, hoặc chọn lại âm thanh khác.")
                return
            }
            audioForExport = beat
        }

        FilePanels.chooseVideoSaveLocation(
            defaultName: store.project.name + "-karaoke",
            opaque: !output.isTransparent,
            preferMOV: exportProRes
        ) { url in
            guard let url else { return }
            store.project.exportSettings.lastMode = .transparentVideo
            store.markDirty()

            var solid: CGColor?
            var image: CGImage?
            var video: URL?
            switch output {
            case .transparentMOV: break
            case .solidMP4(let color): solid = color
            case .imageMP4: image = backgroundImage
            case .videoMP4: video = bgVideoURL
            }

            videoExporter.export(
                project: store.project, to: url, duration: videoExportDuration,
                solidBackground: solid, backgroundImage: image, backgroundVideoURL: video,
                audioURL: audioForExport, preferProRes: exportProRes
            )
        }
    }

    /// Xuất CHỈ sóng nhạc, nền trong suốt (chất lượng theo lựa chọn, không tiếng).
    private func exportVisualizerOnly() {
        clearColorBypass()
        FilePanels.chooseVideoSaveLocation(
            defaultName: store.project.name + "-songnhac",
            opaque: false, preferMOV: true
        ) { url in
            guard let url else { return }
            store.markDirty()
            videoExporter.export(
                project: store.project, to: url, duration: videoExportDuration,
                solidBackground: nil, backgroundImage: nil, backgroundVideoURL: nil,
                audioURL: nil, preferProRes: false, visualizerOnly: true
            )
        }
    }
}
