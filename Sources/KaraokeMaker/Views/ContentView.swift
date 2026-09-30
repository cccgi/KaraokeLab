import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

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

    @FocusState var isNameFieldFocused: Bool
    @FocusState var textOverlayEditing: Bool

    @State var showReplaceLinesAlert = false
    @State var pendingReplace: PendingLineReplace?
    @State var clearedLyricsBackup: String?
    @State var lyricsImportNote: String?

    @State var currentLineIndex = 0
    /// M-C — zoom timeline (points/sec) đưa lên đây để lệnh / menu điều khiển được.
    @State var timelineZoom: Double = 60
    @State var timelineViewportW: Double = 800
    @State var timelineFitTick: Int = 0
    /// Mở project (hay đổi tab) → "Vừa khung" đúng 1 lần khi biết được bề rộng khung nhìn THẬT
    /// (trước đó `timelineViewportW` chỉ là giá trị mặc định 800, chưa phản ánh kích thước panel
    /// thật của user) — khỏi phải tự bấm "Vừa khung" mỗi lần mở lại project.
    @State var didInitialTimelineFit = false
    /// (2026-09-24) SỬA "Vừa khung" RA SÓNG VUÔNG + THỪA KHOẢNG XÁM: `timelineViewportW` đổi
    /// NHIỀU LẦN liên tiếp lúc mới mở (panel 3 cột còn đang dàn xong) — nếu "Vừa khung" tự động
    /// chốt luôn ở LẦN ĐỔI ĐẦU TIÊN, có thể đang dùng bề rộng TẠM (nhỏ hơn thật), ra zoom quá
    /// thấp (khớp sóng bị vuông/thô) và khung nhìn thật (rộng hơn) thừa mảng xám. Chờ bề rộng
    /// ĐỨNG YÊN (không đổi thêm) một chút rồi mới "Vừa khung" bằng con số CUỐI CÙNG.
    @State var pendingInitialFitGen = 0
    /// (2026-09-24) SỬA "Import nhạc lần đầu vào project TRỐNG không tự Vừa khung": trước chỉ
    /// tự "Vừa khung" theo `timelineViewportW` đổi — với project MỚI/TRỐNG, bề rộng khung đã
    /// biết (và "chốt" luôn) ngay từ lúc mở, TRƯỚC KHI user import nhạc, nên lúc nhạc thật vào
    /// (đổi `playback.duration` từ 0 → có giá trị) không còn ai gọi lại "Vừa khung" nữa. Theo
    /// dõi THÊM mốc "nhạc vừa có" (độc lập với mốc bề rộng ở trên) — cái nào tới sau thì tự sửa
    /// lại đúng (`timelineFitToWindow()` luôn tính lại từ số MỚI NHẤT, không cộng dồn).
    @State var didAutoFitForDuration = false
    @State var pendingDurationFitGen = 0
    /// Clip lớp đè đã chép (⌘C) — để dán (⌘V) tại vạch đỏ.
    @State var copiedOverlay: OverlayClip?
    @State var clearedTimingBackup: [LyricLine]?
    @State var timelineClipboard: [LyricLine] = []
    @State var timelineSnapBusy = false
    @State var selectedOverlayID: UUID?
    @State var selectedOverlayIDs: Set<UUID> = []
    /// Tab đang mở trong bảng sửa lớp chữ.
    @State var textInspTab: TextInspTab = .content
    /// (U6) Kho media kéo-thả.
    @State var mediaPoolDropTargeted = false

    /// Dòng vừa bấm T (đã có điểm bắt đầu, chưa có kết thúc) và mốc phải reset nếu quá lâu.
    @State var pendingTapLine: Int?
    @State var pendingTapDeadline: TimeInterval?
    let tapTimeoutSeconds: TimeInterval = 20

    /// Pop-up "Xuất" (kiểu CapCut) — mở từ nút Xuất trên thanh trên, không còn tab Xuất trong inspector.
    @State var showExportSheet = false
    @State var previewBackground: PreviewBackground = .dark
    /// Ảnh nền hiện tại (Mode C, kind == .image) — dùng chung Preview + xuất video.
    @State var backgroundImage: CGImage?
    @State var bgImageLoadToken: URL?   // ảnh nền đang chờ nạp (chống đua)
    /// URL video nền đã giải được (kind == .video).
    @State var bgVideoURL: URL?
    /// Chất lượng khung video nền khi xem thử.
    @State var previewQuality: PreviewQuality = .medium

    /// K1 — canh lời chính xác (forced alignment).
    @ObservedObject var textPresets = TextLayerPresetStore.shared
    @ObservedObject var kfClip = KeyframeClipboard.shared
    @StateObject var aligner = ForcedAligner()
    @State var alignLyricsInput = ""
    /// Karaoke đã tạo → 2 nút "Tạo nhanh / Tạo chất lượng" (và "Không cần lời") KHOÁ cho tới khi người dùng DÁN LẠI lời,
    /// SỬA lời ở ô tạo karaoke, hoặc ĐỔI file nhạc (luật chủ dự án 2026-09-29). Chưa có karaoke thì luôn mở.
    @State var karaokeInputChanged = false
    // "Tự động tạo Karaoke — Không cần lời" (Auto Karaoke): đường THỨ HAI sau khi nhập nhạc. Chạy nền; bước cuối gọi CHÍNH hàm canh giờ
    // (`runKaraokeTiming`) mà đường "Có lời" gọi — không có bộ canh giờ mới.
    @StateObject var autoKaraoke = AutoKaraokeFlow()
    enum CreateMode { case hasLyrics, noLyrics }
    /// Cách tạo Karaoke đã chọn sau khi nhập nhạc (nil = chưa chọn).
    @State var createMode: CreateMode?
    /// Từ máy chưa chắc của karaoke tự động, gắn theo dòng đã canh giờ (trong bộ nhớ; hiện ở tab "Sửa lời").
    @State var autoUncertain: [AutoUncertainWord] = []
    @State var showSrtPreview = false
    @State var exportNote: String?
    /// Ảnh chụp project khi bắt đầu kéo slider, để "chốt" một bước undo lúc thả.
    @State var settingSnapshot: KaraokeProject?

    @StateObject var videoExporter = TransparentVideoExporter()

    // (2026-09-17) Xem `BeatSepProxy`/`AdvancedKaraokeProxy` ở đầu file — KHÔNG giữ
    // `BeatSeparation`/`AdvancedKaraoke` bằng `@StateObject` trực tiếp nữa (publish tiến độ
    // nhiều lần/giây từng kéo CẢ `ContentView` dựng lại). `beatSep`/`advanced` bên dưới là lối
    // tắt gọi HÀM (KHÔNG đọc thuộc tính đổi liên tục qua đây — đọc qua `beatSepProxy`/`advancedProxy`).
    @StateObject var beatSepProxy = BeatSepProxy()
    @StateObject var advancedProxy = AdvancedKaraokeProxy()
    var beatSep: BeatSeparation { beatSepProxy.source }
    /// Phần "Tạo Karaoke cao cấp" (nghe‑chép giọng hát) — độc lập với các bước cũ.
    var advanced: AdvancedKaraoke { advancedProxy.source }
    @State var exportAudioChoice: ExportAudioChoice = .original
    @State var exportProRes = false
    @State var exportAdvancedOpen = false
    /// Kiểu sóng nhạc TRƯỚC khi bấm "Cột mảnh cổ điển" — bấm lần nữa trả về đúng kiểu này (chỉ bộ nhớ).
    @State var classicVizBackup: MusicVisualizer?
    @AppStorage("kmShowSafeArea") var showSafeArea = false

    // Song ca / đánh dấu người hát
    @State var duetMode = false

    // (Dưới đây: @State thuộc về các panel đã tách ra file `ContentView+*.swift` — Swift extension
    // không thể khai báo stored property, nên PHẢI ở lại struct chính này; property/type liên quan
    // chỗ dùng vẫn nằm ở file tách.)

    // ContentView+ColorPanel.swift
    @State var colorExpanded: Set<String> = []
    @State var hslBand: Int = 0
    @State var curveChan: Int = 0
    @State var bypassColor = false
    @State var copiedColor: ColorAdjust?

    // ContentView+CreateKaraoke.swift
    @State var leftPanelTab: LeftPanelTab = .steps
    @State var audioDropTargeted = false
    @State var userBeatURL: URL?
    @State var userVocalURL: URL?
    @State var beatDropTargeted = false
    @State var vocalDropTargeted = false
    @State var audioInputMode: AudioInputMode = .whole
    @State var aiLinesListExpanded = false
    @State var alignPhase: AlignPhase = .idle

    // ContentView+OverlaysAndMedia.swift
    /// Mặc định BẬT karaoke — hễ có beat là phát beat (nút xanh).
    @State var karaokeOn = false
    /// Bấm ＋1 Chữ / ＋1 Dòng → tăng để timeline tạo item trên "track tạm".
    @State var stageWordTick = 0
    @State var stageLineTick = 0
    /// ⌘Z ngay sau khi thả item tạm → trả nó về làn cam thay vì mất.
    @State var restageTick = 0
    @State var restageItem: TimelineEditor.StageItem?
    @State var lastStageDrop: TimelineEditor.StageItem?

    /// Âm thanh gắn vào video khi xuất.
    enum ExportAudioChoice: String, CaseIterable, Identifiable {
        case original = "Nhạc gốc (có lời)"
        case beat     = "Chỉ beat (không lời)"
        case none     = "Không tiếng"
        var id: String { rawValue }
    }

    enum PendingLineReplace {
        case splitFromText
        case srt(lines: [LyricLine], joined: String)
    }

    /// Giây TRONG BÀI tại vạch đỏ = giờ-timeline − mốc clip ★ KARAOKE. Dùng cho MỌI
    /// thao tác gán/đọc timing LỜI (lời lưu theo giây trong bài, không theo timeline).
    var playheadSongTime: TimeInterval {
        max(0, playback.currentTime - store.project.karaokeClipStart)
    }

    var activeLineIndex: Int? {
        TimingEditor.activeIndex(store.project.lines, at: playheadSongTime)
    }

    /// Có dòng nào đang ghi dở (bắt đầu rồi, chưa có kết thúc) không.
    var hasRecordingLine: Bool {
        store.project.lines.contains { $0.start != nil && $0.end == nil }
    }

    // MARK: - Bố cục

    var body: some View {
        mainLayout
        .frame(minWidth: 1180, minHeight: 720)
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
    func syncStemRefsIntoProject() {
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

    var mainLayout: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            VSplitView {
                HSplitView {
                    // DESIGN_SYSTEM §9: preview luôn ưu tiên — 2 cột bên hẹp, preview giãn.
                    leftPanel
                        .frame(minWidth: 340, idealWidth: 400, maxWidth: 560)
                        .clipped()
                    centerColumn
                        .frame(minWidth: 440, maxWidth: .infinity)
                        .layoutPriority(1)
                        .clipped()
                    inspectorColumn
                        .frame(minWidth: 320, idealWidth: 340, maxWidth: 440)
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
    var exportSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.inkDim)
                Text(L("Xuất")).font(Theme.Typo.sheetTitle).foregroundColor(Theme.ink)
                Spacer()
                Button(L("Đóng")) { showExportSheet = false }
                    .buttonStyle(.kmSecondarySmall)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Theme.Space.xl).padding(.vertical, Theme.Space.l)
            Divider().overlay(Theme.stroke)
            ScrollView { exportTabContent.padding(Theme.Space.xl) }
        }
        .frame(width: 560, height: 560)   // 640 → 560: mặc định (Nâng cao gập) để trống ~1/3 dưới (ảnh ui-check); mở Nâng cao thì cuộn
        .background(Theme.panel)
    }

    /// Dòng gần nhất với mốc thời gian `t` (để tua wave thì danh sách cuộn theo).
    func lineIndexNearestTime(_ t: TimeInterval) -> Int {
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
    func seekTo(_ t: TimeInterval) {
        playback.seek(to: t)
        let songT = max(0, t - store.project.karaokeClipStart)   // t = giờ-timeline
        store.lastPreviewTime = songT
        currentLineIndex = clampedIndex(lineIndexNearestTime(songT))
        clearPendingTap()
    }

    // MARK: - Tự reset câu bấm T dở dang

    func checkPendingTapTimeout() {
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

    func clearPendingTap() {
        pendingTapLine = nil
        pendingTapDeadline = nil
    }

    @ViewBuilder
    var errorBar: some View {
        if let error = store.lastError ?? playback.lastError ?? videoExporter.lastError {
            Divider()
            // Thanh lỗi mảnh: icon đỏ + chữ thường (không tô đỏ cả dòng) — DESIGN_SYSTEM §19.
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Theme.error)
                Text(error).font(Theme.Typo.label).foregroundStyle(Theme.ink).lineLimit(2)
                Spacer()
                Button(L("Ẩn")) { store.lastError = nil; playback.clearError() }
                    .buttonStyle(.kmSecondarySmall)
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
            .background(Theme.panelAlt)
        }
    }
}
