import SwiftUI
import AppKit
import Combine

/// Timeline chuyên nghiệp: chọn 1/nhiều/vùng · kéo có ngưỡng + preview 1 lần ·
/// Delete/⌘C/⌘V/⌘X/⌘D/←→ trên tuyển chọn · sửa chữ mức từng ô.
/// Mọi mutation đi qua `store.perform` (1 undo / thao tác).
struct TimelineEditor: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var playback: PlaybackController
    /// (2026-09-17) CHỈ để đọc `seekGeneration` — xem comment ở `PlaybackClock` trong
    /// `PlaybackController.swift`: tách khỏi `playback` để KHÔNG kéo `ContentView` dựng lại mỗi
    /// lần tua (`ContentView` không giữ `@EnvironmentObject var clock`, chỉ view này mới cần).
    @EnvironmentObject var clock: PlaybackClock

    let currentLineIndex: Int
    let onSelect: (Int) -> Void
    let onSeek: (Double) -> Void
    let onCommit: ([(Int, Double, Double)]) -> Void          // kéo 1 mép block
    let onWordsCommit: (Int, [LyricWord], String) -> Void
    let onLineTextRemap: (Int, String) -> Void               // double-click DÒNG → rải lời vào các ô chữ
    let onAddLine: (Double) -> Void
    let onPasteLine: (Int) -> Void
    let onAddWordAtPlayhead: (Int) -> Void
    // Track TẠM (staging)
    let stageWordTick: Int
    let stageLineTick: Int
    let restageTick: Int
    let restageItem: TimelineEditor.StageItem?
    let onStageWordDrop: (Int, Double, Double, String) -> Void
    let onStageLineDrop: (Double, Double, [LyricWord], String) -> Void
    // P1
    let onMoveLines: ([(UUID, Double, Double)]) -> Void
    let onDeleteLines: ([UUID]) -> Void
    let onCopyLines: ([UUID]) -> Void
    let onPasteAtPlayhead: () -> Void
    let onDuplicateLines: ([UUID]) -> Void
    let onNudgeLines: ([UUID], Double) -> Void
    let overlays: [OverlayClip]
    var overlayGroups: [OverlayGroup] = []
    var vizKeyframeTimes: [Double] = []      // giây trong BÀI — hình thoi trên thước
    var textKeyframeTimes: [Double] = []     // giây trong BÀI
    let selectedOverlayID: UUID?
    var selectedOverlayIDs: Set<UUID> = []
    let onOverlaySelect: (UUID?) -> Void
    var onOverlaySelectMulti: (Set<UUID>) -> Void = { _ in }
    var onSelectGroup: (UUID) -> Void = { _ in }
    var onEditTextOverlay: (UUID) -> Void = { _ in }                     // bấm đúp lớp CHỮ
    var onOverlayMove: (UUID, Double, Int) -> Void = { _, _, _ in }       // id, start mới, lane mới
    var onOverlayTrim: (UUID, Double, Double) -> Void = { _, _, _ in }    // id, start mới, thời lượng mới
    var onOverlayFade: (UUID, Double, Double) -> Void = { _, _, _ in }    // id, fadeIn, fadeOut
    var onOverlayRename: (UUID, String) -> Void = { _, _ in }
    var onOverlayTransition: (UUID, Double) -> Void = { _, _ in }         // id clip SAU, độ dài chuyển cảnh
    var onOverlayDelete: (UUID) -> Void = { _ in }
    var onOverlaySplit: (UUID, Double) -> Void = { _, _ in }             // id, mốc cắt (giây)
    var onOverlayDuplicate: (UUID) -> Void = { _ in }
    var onToggleLaneHidden: (Int) -> Void = { _ in }
    var onToggleLaneLocked: (Int) -> Void = { _ in }
    var onToggleLaneAudioMuted: (Int) -> Void = { _ in }
    var onMediaDrop: (String, Double, Int) -> Void = { _, _, _ in }   // id kho, mốc giây, làn
    /// M-A — điểm vào lệnh chung (toolbar timeline gọi cái này, giống phím tắt / menu).
    var run: (EditorCommand) -> Void = { _ in }
    var canPasteClip: Bool = false
    // Chế độ Song ca: bấm khối câu → chọn icon người hát.
    var duetMode: Bool = false
    var singerColors: [String: RGBAColor] = [:]
    var onAssignSinger: ((Int, SingerRole?) -> Void)? = nil
    /// Bước 1 — kéo clip ★ KARAOKE → mốc bắt đầu mới (giây). ContentView bọc `store.perform`.
    var onKaraokeClipMove: (Double) -> Void = { _ in }
    /// Tăng mỗi lần bấm "Vừa khung" → canvas kéo cuộn về đầu (x=0).
    var fitTick: Int = 0
    /// Từ máy chưa chắc (karaoke tự động): khoá "\(lineID)#\(chỉ số từ)" → gạch chân màu cảnh báo trên timeline.
    var uncertainWordKeys: Set<String> = []

    // M-C — do ContentView sở hữu để lệnh / menu điều khiển zoom.
    @Binding var pointsPerSecond: Double
    @Binding var viewportWidth: Double

    // Luôn chừa tối thiểu 3 làn "Lớp đè" — kể cả khi trống — để timeline trông có
    // cấu trúc track như CapCut, kéo thả xuống là thấy chỗ đặt ngay.
    private var overlayLaneCount: Int {
        max(3, min(4, (overlays.map(\.lane).max() ?? 0) + 1))
    }
    // Khớp với `TimelineCanvasView.totalHeight`. "277"/"50" phải đổi CÙNG LÚC với
    // `gWave`/`gLyricBand`/`gOverlayLane` bên dưới NẾU đổi các hàng cao thấp (xem
    // `TimelineCanvasView.totalHeight` để tính lại — công thức 2 bên vốn không khớp tuyệt đối,
    // chỉ cần GIỮ ĐÚNG độ lệch cũ (~30px dư ra phía SwiftUI) để không hụt chiều cao.
    private var totalHeight: Double {
        277 + Double(gKaraoke) + Double(gKaraokeGap) + (Double(overlayLaneCount) * 50 + 6)
    }
    /// Thời lượng timeline. Chưa có nhạc → dùng độ dài đủ chứa các lớp đè + tối thiểu 60s,
    /// để timeline vẫn hiện & sửa được (đường app-edit: không bắt buộc nạp nhạc trước).
    private var duration: Double {
        // Bước 2c — cả bản karaoke (nhạc + lời) dời sang phải `karaokeClipStart` trên timeline.
        let k = max(0, store.project.karaokeClipStart)
        let overlayEnd = (overlays.map(\.end).max() ?? 0) + 10
        let lineEnd = (store.project.lines.compactMap(\.end).max() ?? 0) + k + 10
        return max(playback.duration + k, overlayEnd, lineEnd, 60)
    }

    // ---- Geometry PHẢI KHỚP TimelineCanvasView (2026-09-12: các hàng cao hơn, rõ ràng hơn) ----
    private let gRuler: CGFloat = 20
    private let gWave: CGFloat = 84
    private let gGap: CGFloat = 10
    private let gLyricBand: CGFloat = 105     // 3 làn × (32 + 3)
    private let gKaraokeGap: CGFloat = 6      // khe trước dải ★ KARAOKE
    private let gKaraoke: CGFloat = 22        // clip ★ KARAOKE — dưới "Lời", trên "Lớp đè 1"
    private let gOverlayGap: CGFloat = 8
    private let gOverlayLane: CGFloat = 50    // overlayLaneH 48 + gap 2

    private func laneAllHidden(_ lane: Int) -> Bool {
        let inLane = overlays.filter { $0.lane == lane }
        return !inLane.isEmpty && inLane.allSatisfy { $0.isHidden }
    }
    private func laneAnyLocked(_ lane: Int) -> Bool {
        overlays.contains { $0.lane == lane && $0.isLocked }
    }
    private func laneHasClip(_ lane: Int) -> Bool {
        overlays.contains { $0.lane == lane }
    }
    /// Làn có clip mang tiếng (audio, hoặc video có thể bật tiếng)?
    private func laneHasAudio(_ lane: Int) -> Bool {
        overlays.contains { $0.lane == lane && ($0.kind == .audio || $0.kind == .video) }
    }
    private func laneAudioMuted(_ lane: Int) -> Bool {
        let a = overlays.filter { $0.lane == lane && ($0.kind == .audio || $0.kind == .video) }
        return !a.isEmpty && a.allSatisfy { $0.audioMuted }
    }

    /// Cột đầu track cố định bên trái (không cuộn ngang) — kiểu CapCut.
    private var trackHeaderColumn: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: gRuler)
            musicHeadRow.frame(height: gWave)
            Color.clear.frame(height: gGap)
            lyricHeadRow.frame(height: gLyricBand)
            Color.clear.frame(height: gKaraokeGap)
            karaokeHeadRow.frame(height: gKaraoke)
            Color.clear.frame(height: gOverlayGap)
            ForEach(0..<overlayLaneCount, id: \.self) { lane in
                overlayHeadRow(lane).frame(height: gOverlayLane)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 92)
        .background(Color.black.opacity(0.18))
        .overlay(Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.08)), alignment: .trailing)
    }

    /// Hàng "★ Karaoke" — clip gốc kéo được. Nút loa dùng CHUNG `audioMuted`:
    /// tắt ở đây = tắt tiếng cả bản karaoke (như user chốt).
    private var karaokeHeadRow: some View {
        let muted = store.project.audioMuted
        return HStack(spacing: 5) {
            Image(systemName: "music.mic")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text("Karaoke").font(Theme.Typo.badge).foregroundStyle(Theme.inkDim)
            Spacer(minLength: 0)
            Button {
                store.perform(muted ? L("Bật tiếng karaoke") : L("Tắt tiếng karaoke")) { store.project.audioMuted.toggle() }
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 10))
                    .foregroundStyle(muted ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless).help(L("Tắt / bật tiếng cả bản karaoke"))
        }
        .padding(.horizontal, 7).padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Hàng "Nhạc" — nút tắt/bật tiếng nhanh (giữ nguyên âm lượng đã đặt).
    private var musicHeadRow: some View {
        let muted = store.project.audioMuted
        return HStack(spacing: 5) {
            Image(systemName: "waveform").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(L("Nhạc")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                store.perform(muted ? L("Bật tiếng nhạc") : L("Tắt tiếng nhạc")) { store.project.audioMuted.toggle() }
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 10))
                    .foregroundStyle(muted ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless).help(L("Tắt / bật tiếng nhạc"))
        }
        .padding(.horizontal, 7).padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Hàng "Lời" — có nút ẩn/hiện lớp chữ karaoke trong preview + khi xuất.
    private var lyricHeadRow: some View {
        let hidden = store.project.lyricsHidden
        return HStack(spacing: 5) {
            Image(systemName: "textformat").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(L("Lời")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                store.perform(hidden ? L("Hiện lời") : L("Ẩn lời")) { store.project.lyricsHidden.toggle() }
            } label: {
                Image(systemName: hidden ? "eye.slash.fill" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(hidden ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless).help(L("Ẩn / hiện lớp chữ karaoke"))
        }
        .padding(.horizontal, 7).padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func headRow(_ title: String, icon: String, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(L(title)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .padding(.top, 3)
    }

    private func overlayHeadRow(_ lane: Int) -> some View {
        let has = laneHasClip(lane)
        let hidden = laneAllHidden(lane)
        let locked = laneAnyLocked(lane)
        let hasAudio = laneHasAudio(lane)
        let aMuted = laneAudioMuted(lane)
        return HStack(spacing: 3) {
            Text(String(format: L("Lớp đè %d"), lane + 1))
                .font(Theme.Typo.badge)
                .foregroundStyle(has ? Theme.inkDim : Theme.inkFaint)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button { onToggleLaneAudioMuted(lane) } label: {
                Image(systemName: aMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    .font(.system(size: 10))
                    .foregroundStyle(aMuted ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless).disabled(!hasAudio).help(L("Tắt / bật tiếng cả làn"))
            Button { onToggleLaneHidden(lane) } label: {
                Image(systemName: hidden ? "eye.slash.fill" : "eye")
                    .font(.system(size: 10))
                    .foregroundStyle(hidden ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless).disabled(!has).help(L("Ẩn / hiện cả làn"))
            Button { onToggleLaneLocked(lane) } label: {
                Image(systemName: locked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(locked ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless).disabled(!has).help(L("Khoá / mở khoá cả làn"))
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Group {
                HStack(alignment: .top, spacing: 0) {
                trackHeaderColumn
                GeometryReader { geo in
                    TimelineScrollRepresentable(
                        samples: playback.waveform, duration: duration,
                        pointsPerSecond: pointsPerSecond, playback: playback,
                        seekGen: clock.seekGeneration, isPlaying: playback.isPlaying,
                        lines: store.project.lines,
                        selectedIndex: currentLineIndex,
                        onSelect: onSelect, onSeek: onSeek, onCommit: onCommit,
                        onWordsCommit: onWordsCommit, onLineTextRemap: onLineTextRemap,
                        onAddLine: onAddLine,
                        onPasteLine: onPasteLine,
                        stageWordTick: stageWordTick, stageLineTick: stageLineTick,
                        restageTick: restageTick, restageItem: restageItem,
                        onStageWordDrop: onStageWordDrop, onStageLineDrop: onStageLineDrop,
                        onAddWordAtPlayhead: onAddWordAtPlayhead,
                        onMoveLines: onMoveLines, onDeleteLines: onDeleteLines,
                        onCopyLines: onCopyLines, onPasteAtPlayhead: onPasteAtPlayhead,
                        onDuplicateLines: onDuplicateLines, onNudgeLines: onNudgeLines,
                        onZoom: { f in setZoom(pointsPerSecond * Double(f)) },
                        overlays: overlays, overlayGroups: overlayGroups,
                        vizKeyframeTimes: vizKeyframeTimes, textKeyframeTimes: textKeyframeTimes,
                        selectedOverlayID: selectedOverlayID,
                        selectedOverlayIDs: selectedOverlayIDs,
                        onOverlaySelect: onOverlaySelect, onOverlaySelectMulti: onOverlaySelectMulti,
                        onSelectGroup: onSelectGroup,
                        onEditTextOverlay: onEditTextOverlay,
                        onOverlayMove: onOverlayMove, onOverlayTrim: onOverlayTrim,
                        onOverlayFade: onOverlayFade,
                        onOverlayRename: onOverlayRename, onOverlayTransition: onOverlayTransition,
                        onOverlayDelete: onOverlayDelete, onOverlaySplit: onOverlaySplit,
                        onOverlayDuplicate: onOverlayDuplicate, onMediaDrop: onMediaDrop,
                        run: run, canPasteClip: canPasteClip,
                        duetMode: duetMode, singerColors: singerColors,
                        onAssignSinger: onAssignSinger,
                        karaokeClipStart: store.project.karaokeClipStart,
                        karaokeClipLen: max(playback.duration, store.project.lines.compactMap(\.end).max() ?? 0),
                        karaokeSongLen: playback.duration,
                        karaokeMuted: store.project.audioMuted,
                        karaokeHasContent: playback.duration > 0.1 || !store.project.lines.isEmpty,
                        onKaraokeClipMove: onKaraokeClipMove,
                        fitTick: fitTick,
                        uncertainWordKeys: uncertainWordKeys
                    )
                    .onAppear { viewportWidth = geo.size.width }
                    .onChange(of: geo.size.width) { viewportWidth = $0 }
                }
                // (2026-09-24) SỬA MẤT THANH CUỘN NGANG: trước ép CỨNG cao = `totalHeight`
                // (chiều cao NỘI DUNG, không liên quan khung ngoài) — khi kéo viền chia nhỏ
                // khung Timeline lại, NSScrollView bên trong vẫn đòi đúng `totalHeight`, phần
                // dư (gồm cả thanh cuộn ở đáy) bị `.clipped()` ở ContentView cắt mất. Đổi
                // sang cho co giãn đúng theo khung THẬT được cấp (đã có `minHeight: 300` chặn
                // dưới từ ContentView) — NSScrollView tự cắt/đủ chỗ đúng bên trong nó, thanh
                // cuộn luôn nằm trong khung nhìn thấy được.
                .frame(maxHeight: .infinity)
                }
                .background(Theme.bg.opacity(0.35))

                Text(playback.isLoaded
                     ? L("Click thước/sóng = tua vạch đỏ · kéo clip lớp đè = dời (kéo dọc đổi làn), kéo mép = cắt · ⌘K = tách tại vạch đỏ · Delete = xoá · double-click sửa · S tách / M gộp ô chữ · ⌘C/⌘V dán · ←→ nudge.")
                     : L("Chưa có nhạc vẫn dùng được: click thước để tua vạch đỏ, ▶ để chạy thử. Kéo nhạc/ảnh/video từ “File của bạn” xuống các làn bên dưới."))
                    .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).lineLimit(1).truncationMode(.tail)
            }
        }
        .onAppear { playback.virtualDuration = duration }
        .onChange(of: duration) { playback.virtualDuration = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Timeline")).sectionHeaderStyle()
            if playback.isAnalyzingWaveform {
                Text(L("đang phân tích sóng…")).font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
            }

            Divider().frame(height: 16).padding(.horizontal, 2)

            // Bộ công cụ (giống CapCut) — đi qua EditorCommand chung (giống phím tắt / menu).
            toolButton("scissors", L("Tách lớp đè tại vạch đỏ (⌘K)"), enabled: selectedOverlayID != nil) {
                run(.splitAtPlayhead)
            }
            toolButton("plus.square.on.square", L("Nhân đôi lớp đè"), enabled: selectedOverlayID != nil) {
                run(.duplicateSelection)
            }
            toolButton("trash", L("Xoá lớp đè"), enabled: selectedOverlayID != nil) {
                run(.deleteSelection)
            }

            Spacer()
            toolButton("minus.magnifyingglass", L("Thu nhỏ (⌘−)"), enabled: true) { run(.zoomOut) }
            toolButton("plus.magnifyingglass", L("Phóng to (⌘=)"), enabled: true) { run(.zoomIn) }
            Button(L("Vừa khung")) { run(.zoomToFit) }
                .buttonStyle(.kmSecondarySmall)
        }
    }

    @ViewBuilder
    private func toolButton(_ icon: String, _ help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(.kmIcon)
        .disabled(!enabled)
        .help(help)
    }
    private func setZoom(_ v: Double) { pointsPerSecond = min(400, max(8, v)) }
}

extension TimelineEditor {
    /// Gói dữ liệu 1 item ở làn tạm — để ⌘Z sau khi thả có thể dựng lại y như cũ.
    struct StageItem: Equatable {
        var isLine: Bool
        var start: Double
        var end: Double
        var text: String
        var words: [LyricWord]
    }
}

// MARK: - Cầu nối AppKit

private struct TimelineScrollRepresentable: NSViewRepresentable {
    let samples: [Float]; let duration: Double; let pointsPerSecond: Double
    let playback: PlaybackController   // strong: `unowned` từng crash khi SwiftUI copy struct lúc teardown
    let seekGen: Int; let isPlaying: Bool
    let lines: [LyricLine]; let selectedIndex: Int
    let onSelect: (Int) -> Void; let onSeek: (Double) -> Void
    let onCommit: ([(Int, Double, Double)]) -> Void
    let onWordsCommit: (Int, [LyricWord], String) -> Void
    let onLineTextRemap: (Int, String) -> Void
    let onAddLine: (Double) -> Void; let onPasteLine: (Int) -> Void
    let stageWordTick: Int; let stageLineTick: Int
    let restageTick: Int; let restageItem: TimelineEditor.StageItem?
    let onStageWordDrop: (Int, Double, Double, String) -> Void
    let onStageLineDrop: (Double, Double, [LyricWord], String) -> Void
    let onAddWordAtPlayhead: (Int) -> Void
    let onMoveLines: ([(UUID, Double, Double)]) -> Void
    let onDeleteLines: ([UUID]) -> Void
    let onCopyLines: ([UUID]) -> Void
    let onPasteAtPlayhead: () -> Void
    let onDuplicateLines: ([UUID]) -> Void
    let onNudgeLines: ([UUID], Double) -> Void
    let onZoom: (CGFloat) -> Void
    let overlays: [OverlayClip]
    var overlayGroups: [OverlayGroup] = []
    var vizKeyframeTimes: [Double] = []
    var textKeyframeTimes: [Double] = []
    let selectedOverlayID: UUID?
    var selectedOverlayIDs: Set<UUID> = []
    let onOverlaySelect: (UUID?) -> Void
    var onOverlaySelectMulti: (Set<UUID>) -> Void = { _ in }
    var onSelectGroup: (UUID) -> Void = { _ in }
    var onEditTextOverlay: (UUID) -> Void = { _ in }
    var onOverlayMove: (UUID, Double, Int) -> Void = { _, _, _ in }
    var onOverlayTrim: (UUID, Double, Double) -> Void = { _, _, _ in }
    var onOverlayFade: (UUID, Double, Double) -> Void = { _, _, _ in }
    var onOverlayRename: (UUID, String) -> Void = { _, _ in }
    var onOverlayTransition: (UUID, Double) -> Void = { _, _ in }
    var onOverlayDelete: (UUID) -> Void = { _ in }
    var onOverlaySplit: (UUID, Double) -> Void = { _, _ in }
    var onOverlayDuplicate: (UUID) -> Void = { _ in }
    var onMediaDrop: (String, Double, Int) -> Void = { _, _, _ in }
    var run: (EditorCommand) -> Void = { _ in }
    var canPasteClip: Bool = false
    var duetMode: Bool = false
    var singerColors: [String: RGBAColor] = [:]
    var onAssignSinger: ((Int, SingerRole?) -> Void)? = nil
    // Bước 1 — clip ★ KARAOKE (chỉ kéo)
    var karaokeClipStart: Double = 0
    var karaokeClipLen: Double = 0
    var karaokeSongLen: Double = 0
    var karaokeMuted: Bool = false
    var karaokeHasContent: Bool = false
    var onKaraokeClipMove: (Double) -> Void = { _ in }
    var fitTick: Int = 0
    var uncertainWordKeys: Set<String> = []

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        // (2026-09-24) SỬA: `autohidesScrollers = true` khiến AppKit tự tính "có cần hiện thanh
        // cuộn ngang không" — khi kéo khung Timeline thấp xuống (viền giữa 3 cột trên/Timeline),
        // nội dung Timeline (nhiều làn: nhạc/lời/karaoke/lớp đè) cao hơn khung nhìn NHƯNG không
        // có thanh cuộn dọc (`hasVerticalScroller = false`) — phép tính bị nhầm, ẩn mất luôn
        // thanh cuộn NGANG dù vẫn cần (bài dài hơn khung nhìn theo chiều ngang). Luôn hiện thanh
        // cuộn ngang, khỏi phụ thuộc phép tính tự động dễ sai này.
        scroll.autohidesScrollers = false
        let canvas = TimelineCanvasView()
        canvas.identifier = NSUserInterfaceItemIdentifier("KMTimelineCanvas")
        canvas.registerForDraggedTypes([.string])
        scroll.documentView = canvas
        context.coordinator.canvas = canvas
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let c = context.coordinator.canvas else { return }

        // Nghe TRỰC TIẾP `isPlaying` (đồng bộ ngay trong `pause()`), không chờ vòng
        // cập nhật SwiftUI → ghim vạch đỏ đúng vị trí audio dừng, hết "giật lùi".
        if context.coordinator.playSink == nil {
            context.coordinator.playSink = playback.$isPlaying
                .sink { [weak c, weak playback] playing in
                    guard let c, let playback, !playing else { return }
                    c.freezePlayhead(atTime: CGFloat(playback.audioTimeRaw))
                }
        }
        c.onSelect = onSelect; c.onSeek = onSeek; c.onCommit = onCommit
        c.onWordsCommit = onWordsCommit; c.onLineTextRemap = onLineTextRemap; c.onAddLine = onAddLine
        c.onStageWordDrop = onStageWordDrop; c.onStageLineDrop = onStageLineDrop
        if stageWordTick != context.coordinator.lastStageWordTick {
            context.coordinator.lastStageWordTick = stageWordTick
            c.beginStageWord(atTime: CGFloat(playback.renderTime))
        }
        if stageLineTick != context.coordinator.lastStageLineTick {
            context.coordinator.lastStageLineTick = stageLineTick
            c.beginStageLine(atTime: CGFloat(playback.renderTime))
        }
        if restageTick != context.coordinator.lastRestageTick {
            context.coordinator.lastRestageTick = restageTick
            if let it = restageItem { c.restage(it) }
        }
        c.onPasteLine = onPasteLine; c.onAddWordAtPlayhead = onAddWordAtPlayhead
        c.onMoveLines = onMoveLines; c.onDeleteLines = onDeleteLines
        c.onCopyLines = onCopyLines; c.onPasteAtPlayhead = onPasteAtPlayhead
        c.onDuplicateLines = onDuplicateLines; c.onNudgeLines = onNudgeLines
        c.onZoom = onZoom
        c.onOverlaySelect = onOverlaySelect
        c.onOverlaySelectMulti = onOverlaySelectMulti
        c.onSelectGroup = onSelectGroup
        c.overlayGroups = overlayGroups
        c.vizKeyframeTimes = vizKeyframeTimes
        c.textKeyframeTimes = textKeyframeTimes
        c.onEditTextOverlay = onEditTextOverlay
        c.onOverlayMove = onOverlayMove
        c.onOverlayTrim = onOverlayTrim
        c.onOverlayFade = onOverlayFade
        c.onOverlayRename = onOverlayRename
        c.onOverlayTransition = onOverlayTransition
        c.onOverlayDelete = onOverlayDelete
        c.onOverlaySplit = onOverlaySplit
        c.onMediaDrop = onMediaDrop
        c.run = run
        c.canPasteClip = canPasteClip
        c.onKaraokeClipMove = onKaraokeClipMove
        c.requestFitToStart(tick: fitTick)
        c.setKaraokeClip(start: CGFloat(max(0, karaokeClipStart)),
                         len: CGFloat(max(0, karaokeClipLen)),
                         songLen: CGFloat(max(0, karaokeSongLen)),
                         muted: karaokeMuted, hasContent: karaokeHasContent)
        c.onAssignSinger = onAssignSinger
        c.singerColors = singerColors
        c.setUncertainWordKeys(uncertainWordKeys)
        c.setDuetMode(duetMode)
        c.followScroll = false   // "Theo playhead" đã bỏ — user cuộn tay
        c.timeProvider = { [weak playback] in playback?.renderTime ?? 0 }
        c.applyState(samples: samples, duration: CGFloat(max(duration, 0.1)),
                     pointsPerSecond: CGFloat(pointsPerSecond), lines: lines, selectedIndex: selectedIndex,
                     overlays: overlays, selOverlayID: selectedOverlayID, selOverlayIDs: selectedOverlayIDs)
        let justStopped = c.setPlaying(isPlaying)
        if justStopped {
            // `pause()` cũng bump `seekGeneration` — nuốt lần bump đó, vì `freezePlayhead`
            // (từ Combine sink) đã ghim vạch đỏ đúng chỗ rồi. Nắn thêm = thấy trượt.
            c.consumeSeekGen(seekGen)
        } else {
            c.noteSeekGen(seekGen)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        weak var canvas: TimelineCanvasView?
        var playSink: AnyCancellable?
        var lastStageWordTick = 0
        var lastStageLineTick = 0
        var lastRestageTick = 0
    }
}

// MARK: - Canvas

/// `NSMenuItem` gọi 1 closure (context menu timeline).
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

private final class TimelineCanvasView: NSView, NSTextFieldDelegate {
    var onSelect: ((Int) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onCommit: (([(Int, Double, Double)]) -> Void)?
    var onWordsCommit: ((Int, [LyricWord], String) -> Void)?
    var onLineTextRemap: ((Int, String) -> Void)?
    var onAddLine: ((Double) -> Void)?
    var onPasteLine: ((Int) -> Void)?
    var onAddWordAtPlayhead: ((Int) -> Void)?
    var onMoveLines: (([(UUID, Double, Double)]) -> Void)?
    var onDeleteLines: (([UUID]) -> Void)?
    var onCopyLines: (([UUID]) -> Void)?
    var onPasteAtPlayhead: (() -> Void)?
    var onDuplicateLines: (([UUID]) -> Void)?
    var onNudgeLines: (([UUID], Double) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onOverlaySelect: ((UUID?) -> Void)?
    var onEditTextOverlay: ((UUID) -> Void)?
    var onOverlayMove: ((UUID, Double, Int) -> Void)?
    var onOverlayTrim: ((UUID, Double, Double) -> Void)?
    var onOverlayFade: ((UUID, Double, Double) -> Void)?
    var onOverlayRename: ((UUID, String) -> Void)?
    var onOverlayTransition: ((UUID, Double) -> Void)?
    var onOverlayDelete: ((UUID) -> Void)?
    var onOverlaySplit: ((UUID, Double) -> Void)?
    var onMediaDrop: ((String, Double, Int) -> Void)?
    var onKaraokeClipMove: ((Double) -> Void)?
    var run: ((EditorCommand) -> Void)?
    var canPasteClip = false

    /// Điểm đang rê file kho lên timeline — (mốc giây, làn) để tô sáng chỗ sắp thả.
    private var dropHover: (t: CGFloat, lane: Int)?

    // ----- Chế độ Song ca -----
    var onAssignSinger: ((Int, SingerRole?) -> Void)?
    var singerColors: [String: RGBAColor] = [:]
    private var duetMode = false
    private var duetPickerLine: Int?          // khối câu đang mở bảng chọn icon
    func setDuetMode(_ on: Bool) {
        guard on != duetMode else { return }
        duetMode = on
        if !on { duetPickerLine = nil }
        needsDisplay = true
    }
    /// Vẽ icon người hát (VECTOR, giữ tỉ lệ) canh giữa trong ô `box`, tô đúng MÀU vai đã chọn.
    private func drawSingerIcon(_ role: SingerRole, in box: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let asp = SingerIcon.aspect(role)
        guard asp > 0, box.width > 0, box.height > 0 else { return }
        let sc = min(box.width / asp, box.height)
        let w = sc * asp, h = sc
        let c = (singerColors[role.rawValue] ?? SingerRole.defaultColor(role)).nsColor
        SingerIcon.draw(role, in: ctx, rect: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h),
                        color: c.usingColorSpace(.sRGB)?.cgColor ?? c.cgColor)
    }
    /// Rect 4 nút phía TRÊN khối câu `i` (toạ độ view). [nam, nữ, duet, XOÁ].
    private func duetIconRects(for i: Int) -> [CGRect] {
        let b = blockRect(i)
        let s: CGFloat = 26, gap: CGFloat = 6
        let totalW = s * 4 + gap * 3
        let x0 = min(max(2, b.minX), max(2, bounds.width - totalW - 2))
        let y = b.minY - s - 6
        return (0..<4).map { CGRect(x: x0 + CGFloat($0) * (s + gap), y: y, width: s, height: s) }
    }

    private var pendingZoomAnchor: (time: CGFloat, screenX: CGFloat)?
    private var lastFitTick = Int.min
    /// "Vừa khung": neo về đầu timeline (0s ở mép trái) — `applyState` sẽ cuộn tới.
    func requestFitToStart(tick: Int) {
        guard tick != lastFitTick else { return }
        if lastFitTick != Int.min { pendingZoomAnchor = (time: 0, screenX: 0) }
        lastFitTick = tick
    }
    private var samples: [Float] = []
    private var duration: CGFloat = 1
    private var pps: CGFloat = 60
    private var currentTime: CGFloat = 0
    private var lines: [LyricLine] = []
    private var selectedIndex = -1

    // ----- Selection -----
    private var selIDs: Set<UUID> = []
    private var selWord = -1
    /// Chọn NHIỀU chữ trong dòng đang active — Cmd+click từng ô (cộng dồn) hoặc Cmd+kéo
    /// (khoanh vùng). Chỉ có ý nghĩa trong PHẠM VI 1 dòng nên luôn xoá khi đổi dòng active.
    private var selWords: Set<Int> = []
    private var wordMarqueeLine: Int?
    private var wordMarqueeAnchor: NSPoint?
    private var wordMarqueeBase: Set<Int> = []
    private var wordMarqueeRect: CGRect?
    private var dragKeptLineGroup: UUID?

    // ----- Lớp đè -----
    private var overlays: [OverlayClip] = []
    private var selOverlayID: UUID?
    private var selOverlayIDs: Set<UUID> = []
    var overlayGroups: [OverlayGroup] = []
    var vizKeyframeTimes: [Double] = []
    var textKeyframeTimes: [Double] = []
    var onOverlaySelectMulti: ((Set<UUID>) -> Void)?
    var onSelectGroup: ((UUID) -> Void)?
    /// Xem trước KÉO NHÓM: id → (start mới, lane mới).
    private var overlayMultiPreview: [UUID: (s: Double, lane: Int)]?
    /// Delta lane khi bắt đầu kéo nhóm (để tính start/lane từng clip).
    private var multiDragBase: [UUID: (s: Double, lane: Int)] = [:]

    // Kéo / cắt clip lớp đè trên timeline.
    private enum OverlayZone { case move, left, right, fadeIn, fadeOut }
    private struct OverlayDrag {
        var id: UUID
        var zone: OverlayZone
        var aStart: CGFloat
        var aDur: CGFloat
        var aLane: Int
        var aFadeIn: CGFloat = 0
        var aFadeOut: CGFloat = 0
        var downX: CGFloat
        var downY: CGFloat
        var moved = false
    }
    private var overlayDrag: OverlayDrag?
    /// Trạng thái xem trước khi đang kéo/cắt clip (giữ tới khi model mới về).
    private var overlayPreview: (id: UUID, start: CGFloat, dur: CGFloat, lane: Int)?
    /// Xem trước fade khi kéo tay nắm (id, fadeIn, fadeOut) — giây.
    private var overlayFadePreview: (id: UUID, fin: CGFloat, fout: CGFloat)?

    // ----- Bước 1–2 · Clip ★ KARAOKE (track đầu — "tay cầm" dời / cắt cả cụm) -----
    private var karaokeClipStart: CGFloat = 0     // giây — mốc bắt đầu trên dòng dựng
    private var karaokeClipLen: CGFloat = 0       // giây — độ dài dự phòng khi chưa có bài
    private var karaokeSongLen: CGFloat = 0       // giây — độ dài bài thật (0 = chưa nạp)
    private var karaokeMuted = false
    /// Từ chưa chắc → gạch chân (DESIGN_SYSTEM §14). `uncertainLineIDs` lọc nhanh trước khi xét từng từ.
    private var uncertainWordKeys: Set<String> = []
    private var uncertainLineIDs: Set<String> = []
    func setUncertainWordKeys(_ keys: Set<String>) {
        guard keys != uncertainWordKeys else { return }
        uncertainWordKeys = keys
        uncertainLineIDs = Set(keys.compactMap { $0.split(separator: "#").first.map(String.init) })
        needsDisplay = true
    }
    /// Từ `wi` của dòng có phải từ máy chưa chắc không (chỉ khi số ô chữ khớp số từ trong câu).
    private func isUncertain(_ line: LyricLine, _ wi: Int) -> Bool {
        let lid = line.id.uuidString
        guard uncertainLineIDs.contains(lid), uncertainWordKeys.contains("\(line.id)#\(wi)") else { return false }
        return line.words.count == line.text.split(whereSeparator: { $0.isWhitespace }).count
    }
    private func drawUncertainMark(_ r: CGRect) {
        Theme.NS.warning.setFill()
        NSBezierPath(rect: CGRect(x: r.minX + 1, y: r.maxY - 2.5, width: max(2, r.width - 2), height: 2)).fill()
    }
    private var karaokeHasContent = false
    // Clip ★ CHỈ KÉO — không cắt, không sửa gì khác (user chốt 2026-09-08).
    private struct KaraokeDrag { var aStart: CGFloat; var downX: CGFloat; var moved = false }
    private var karaokeDrag: KaraokeDrag?
    /// Xem-trước khi đang kéo (giữ tới khi model mới về qua `applyState`).
    private var karaokePreviewStart: CGFloat?

    func setKaraokeClip(start: CGFloat, len: CGFloat, songLen: CGFloat, muted: Bool, hasContent: Bool) {
        var dirty = false
        if karaokeDrag == nil, abs(start - karaokeClipStart) > 0.0001 { karaokeClipStart = start; dirty = true }
        if abs(len - karaokeClipLen) > 0.0001 { karaokeClipLen = len; dirty = true }
        if abs(songLen - karaokeSongLen) > 0.0001 { karaokeSongLen = songLen; dirty = true }
        if muted != karaokeMuted { karaokeMuted = muted; dirty = true }
        if hasContent != karaokeHasContent { karaokeHasContent = hasContent; dirty = true }
        // Model đã về → bỏ xem-trước để clip khớp giá trị thật (không giật).
        if karaokeDrag == nil, karaokePreviewStart != nil { karaokePreviewStart = nil; dirty = true }
        if dirty { needsDisplay = true }
    }

    /// Mốc bắt đầu ĐANG hiển thị (ưu tiên xem-trước lúc kéo).
    private var karaokeShownStart: CGFloat { karaokePreviewStart ?? karaokeClipStart }
    /// Bước 2c — LỜI lưu theo giây-trong-bài; trên timeline vẽ tại `giây-bài + lyricOff`.
    /// = mốc clip ★ (chạy theo tức thì khi kéo clip). Vạch đỏ + thước + lớp đè KHÔNG dời.
    private var lyricOff: CGFloat { karaokeShownStart }
    /// Độ dài clip ★ = độ dài bài (hoặc lời nếu chưa nạp nhạc).
    private var karaokeShownLen: CGFloat {
        karaokeSongLen > 0.5 ? karaokeSongLen : karaokeClipLen
    }
    private let karaokeStripH: CGFloat = 22

    private let rulerH: CGFloat = 20
    private let waveHeight: CGFloat = 84
    private let gap: CGFloat = 10
    private let laneHeight: CGFloat = 32
    private let laneGap: CGFloat = 3
    private let maxLanes = 3
    private let selBlockH: CGFloat = 54
    /// Thanh DÒNG (dải trên, mảnh) tách hẳn khỏi hàng CHỮ (dải dưới) bằng 1 khe trống
    /// → rà/bấm/kéo không bao giờ lẫn giữa dòng và chữ.
    private let lineBarH: CGFloat = 15
    private let bandGap: CGFloat = 4
    private var wordBandTop: CGFloat { lineBarH + bandGap }        // 19
    private let handleW: CGFloat = 12
    private let wordHandleW: CGFloat = 6
    private let minWidthForHandles: CGFloat = 34
    private let dragThreshold: CGFloat = 3

    private var laneOf: [Int: Int] = [:]
    /// Clip video đang CHỜ khung đầu (bất đồng bộ) — tránh xếp hàng vẽ-lại nhiều lần cho 1 clip.
    private var pendingThumbRedraw: Set<UUID> = []

    // ----- Drag state machine -----
    private enum Hit: Equatable {
        case none, ruler
        case blockBody(Int), blockLeft(Int), blockRight(Int)
        case wordBody(Int, Int), wordLeft(Int, Int), wordRight(Int, Int)

        var lineIdx: Int? {
            switch self {
            case .blockBody(let i), .blockLeft(let i), .blockRight(let i),
                 .wordBody(let i, _), .wordLeft(let i, _), .wordRight(let i, _): return i
            default: return nil
            }
        }
        var wordIdx: (Int, Int)? {
            switch self {
            case .wordBody(let l, let w), .wordLeft(let l, let w), .wordRight(let l, let w): return (l, w)
            default: return nil
            }
        }
    }

    /// Ô đang bị chuột rà qua — sáng nhẹ để dễ nhắm.
    private var hoverHit: Hit = .none
    private var hoverTrack: NSTrackingArea?

    // ----- Item CHỜ (staging) -----
    // (2026-09-23) TRƯỚC chỉ 1 ô nhớ CHUNG cho cả "chữ" lẫn "dòng" — bấm Thêm dòng rồi bấm
    // Thêm chữ làm MẤT LUÔN item dòng vừa tạo (ghi đè). User yêu cầu 2 thứ phải tồn tại
    // SONG SONG, không cái nào đè cái nào → tách riêng `stagingWord`/`stagingLine`, mỗi cái
    // 1 hàng riêng trong khu vực tạm (xếp chồng khi cả 2 cùng có).
    private struct Staging {
        var isLine: Bool
        var s: CGFloat
        var e: CGFloat
        var words: [LyricWord] = []   // chỉ dùng khi isLine
        var text: String
    }
    private enum StageKind { case word, line }
    private var stagingWord: Staging?
    private var stagingLine: Staging?
    private func staging(_ k: StageKind) -> Staging? { k == .word ? stagingWord : stagingLine }
    private func setStaging(_ k: StageKind, _ v: Staging?) {
        if k == .word { stagingWord = v } else { stagingLine = v }
    }
    private var stagingDrag: CGSize = .zero
    private var stagingDragging = false
    private var stagingDownP: NSPoint = .zero
    private var stagingDragBase: CGSize = .zero
    private var stagingDropLine: Int?
    private var stagingDropGap: (lo: CGFloat, hi: CGFloat)?   // khe trống đang nhắm tới (kéo DÒNG)
    private var stagingDragKind: StageKind?          // kind nào đang bị KÉO (nil = không kéo)
    private var editingStageKind: StageKind?         // kind nào đang GÕ CHỮ (khi editing sentinel)
    /// Item CHỜ nào đang được "chọn" (bấm vào, chưa chắc đã kéo) — để Delete biết xoá cái nào.
    private var stagingSelected: StageKind?
    /// Vùng đang nắm khi kéo item tạm: giữa = dời, mép = kéo dãn.
    private enum StageZone { case move, left, right }
    private var stagingZone: StageZone = .move
    private var stagingBaseS: CGFloat = 0
    private var stagingBaseE: CGFloat = 0

    var onStageWordDrop: ((Int, Double, Double, String) -> Void)?
    var onStageLineDrop: ((Double, Double, [LyricWord], String) -> Void)?

    private func stagingRect(_ k: StageKind) -> CGRect? {
        guard let st = staging(k) else { return nil }
        let w = max(28, (st.e - st.s) * pps)
        let off = (stagingDragKind == k) ? stagingDrag : .zero
        return CGRect(x: (st.s + lyricOff) * pps + off.width,
                      y: stagingLaneY(k) + off.height,
                      width: w, height: stagingLaneH - 6)
    }
    private enum WZone { case move, left, right }
    private enum DState {
        case pending(Hit, NSPoint)
        case scrub
        case marquee(NSPoint, NSPoint)
        case blocks(idx: [Int], anchor: [Int: (CGFloat, CGFloat)], primary: Int, downX: CGFloat)
        case blockEdge(idx: Int, left: Bool, aS: CGFloat, aE: CGFloat, downX: CGFloat,
                       prev: Int?, next: Int?)
        case word(line: Int, word: Int, zone: WZone, aS: CGFloat, aE: CGFloat,
                  prevS: CGFloat, prevE: CGFloat, nextS: CGFloat, nextE: CGFloat,
                  hi: CGFloat, downX: CGFloat)
        /// Kéo CẢ NHÓM chữ đã chọn (`selWords`) cùng lúc — cả cụm dời như 1 khối, khoảng cách
        /// giữa các chữ TRONG nhóm giữ nguyên; 2 hàng xóm ở NGOÀI 2 đầu cụm (nếu có) bị đụng
        /// thì THU NGẮN lại (y hệt kéo 1 chữ), không đè chồng lên nhau như trước.
        case wordsGroup(line: Int, idxs: [Int], anchor: [Int: (CGFloat, CGFloat)],
                        prevS: CGFloat, prevE: CGFloat, nextS: CGFloat, nextE: CGFloat, downX: CGFloat)
    }
    private var dstate: DState?
    private var previewBlocks: [Int: (CGFloat, CGFloat)] = [:]      // idx -> (start,end) khi kéo
    private var previewNeighbor: (index: Int, start: CGFloat, end: CGFloat)?
    private var wordPreview: [(w: Int, s: CGFloat, e: CGFloat)] = []
    private var marqueeRect: CGRect?
    /// Sau khi thả chuột: GIỮ preview cho tới khi `applyState` nhận model đã cập nhật
    /// → không còn cảnh "thả ra khối thụt về chỗ cũ 1 nhịp rồi mới nhảy đúng".
    private var holdPreview = false

    // ----- Nam châm (P2) -----
    private let snapPx: CGFloat = 6
    private var snapOff = false               // giữ ⌘ khi kéo = tắt nam châm
    private var snapGuideT: CGFloat?          // giây — để vẽ vạch canh vàng
    private var readout: (t: CGFloat, at: NSPoint)?   // ô mm:ss.cc nổi cạnh con trỏ

    /// Nam châm ("hít") ĐÃ TẮT theo yêu cầu — kéo tới đâu đứng đó (1px).
    private func snapTime(_ t: CGFloat, exclude: Set<Int>) -> CGFloat {
        snapGuideT = nil
        return t
    }

    private func fmtTime(_ t: CGFloat) -> String {
        let ti = max(0, Double(t))
        let m = Int(ti) / 60, s = Int(ti) % 60
        let cc = Int(round((ti - floor(ti)) * 100)) % 100
        return String(format: "%d:%02d.%02d", m, s, cc)
    }

    private var editField: NSTextField?
    private var editing: (line: Int, word: Int)?

    private var waveformImage: NSImage?
    private var waveformKey: (count: Int, width: Int)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let playheadLayer: CALayer = {
        let l = CALayer(); l.backgroundColor = Theme.NS.playhead.cgColor; l.zPosition = 100; return l
    }()
    private let triLayer: CALayer = {
        let l = CALayer(); l.backgroundColor = Theme.NS.playhead.cgColor; l.zPosition = 100; return l
    }()
    private let sweepLayer: CALayer = {
        let l = CALayer(); l.backgroundColor = Theme.accentNS.withAlphaComponent(0.28).cgColor
        l.zPosition = 40; return l
    }()
    private var selBlockFrame: CGRect?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        if playheadLayer.superlayer == nil {
            layer?.addSublayer(sweepLayer); layer?.addSublayer(playheadLayer); layer?.addSublayer(triLayer)
            layoutPlayhead()
        }
    }

    private func layoutPlayhead() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if playAnimActive {
            // Đang để CoreAnimation tự chạy vạch đỏ — không đụng vào position,
            // chỉ cập nhật chiều cao (đề phòng đổi số làn) + vệt quét.
            playheadLayer.bounds.size = CGSize(width: 2, height: totalHeight)
            triLayer.bounds.size = CGSize(width: 8, height: 7)
        } else {
            let x = currentTime * pps
            playheadLayer.frame = CGRect(x: x - 1, y: 0, width: 2, height: totalHeight)
            triLayer.frame = CGRect(x: x - 4, y: 0, width: 8, height: 7)
        }
        updateSweep()
        CATransaction.commit()
    }
    private func updateSweep() {
        guard let f = selBlockFrame else { sweepLayer.frame = .zero; return }
        let filled = min(max(0, currentTime * pps - f.minX), f.width)
        sweepLayer.frame = CGRect(x: f.minX, y: f.minY, width: filled, height: f.height)
    }

    private var contentWidth: CGFloat { max(1, duration * pps) }
    private var waveTop: CGFloat { rulerH }
    private var laneAreaTop: CGFloat { waveTop + waveHeight + gap }
    private func laneY(_ l: Int) -> CGFloat { laneAreaTop + CGFloat(l) * (laneHeight + laneGap) }

    /// Dải clip ★ KARAOKE — dưới "Lời", NGAY TRÊN "Lớp đè 1". Dịch xuống khi có item chờ.
    private let karaokeStripGap: CGFloat = 6
    private var karaokeStripTop: CGFloat { lyricAreaBottom + karaokeStripGap + stagingAreaH }
    private var karaokeStripBottom: CGFloat { karaokeStripTop + karaokeStripH }

    /// Ô clip ★ KARAOKE trên timeline (toạ độ view) — chỉ KÉO, phủ trọn bài.
    private func karaokeClipRect() -> CGRect {
        let len = max(karaokeShownLen, karaokeSongLen > 0.5 ? 0.5 : (duration > 0 ? min(duration, 8) : 8))
        return CGRect(x: karaokeShownStart * pps, y: karaokeStripTop + 2,
                      width: max(24, len * pps), height: karaokeStripH - 4)
    }
    private func inKaraokeStrip(_ p: NSPoint) -> Bool {
        p.y >= karaokeStripTop && p.y < karaokeStripBottom
    }

    // ----- Lớp đè (overlay track) -----
    private let overlayLaneH: CGFloat = 48
    private let overlayLaneGap: CGFloat = 2
    private let minOverlayLanes = 3          // luôn hiện ≥3 làn kể cả trống (như CapCut)
    private var overlayLaneCount: Int {
        max(minOverlayLanes, min(4, (overlays.map(\.lane).max() ?? 0) + 1))
    }
    private var lyricAreaBottom: CGFloat { laneAreaTop + CGFloat(maxLanes) * (laneHeight + laneGap) }

    // ----- Item CHỜ (staging) — NGAY DƯỚI hàng lời, màu cam. Chỉ hiện khi có item chờ.
    // Kéo item LÊN thả vào khe trống trong dải "Lời" phía trên để đặt thật.
    private let stagingLaneH: CGFloat = 30
    private var stagingActiveCount: Int { (stagingLine != nil ? 1 : 0) + (stagingWord != nil ? 1 : 0) }
    private var stagingActive: Bool { stagingActiveCount > 0 }
    /// Dòng CHỜ ở hàng trên, chữ CHỜ ở hàng dưới (khi cả 2 cùng có) — không đè lên nhau.
    private func stagingLaneY(_ k: StageKind) -> CGFloat {
        let base = lyricAreaBottom + 6
        return k == .line ? base : base + (stagingLine != nil ? stagingLaneH + 6 : 0)
    }
    private var stagingAreaH: CGFloat {
        stagingActiveCount == 0 ? 0
            : CGFloat(stagingActiveCount) * stagingLaneH + CGFloat(stagingActiveCount - 1) * 6 + 10
    }

    private var overlayAreaTop: CGFloat { karaokeStripBottom + 8 }
    private var overlayAreaHeight: CGFloat {
        overlayLaneCount == 0 ? 0 : CGFloat(overlayLaneCount) * (overlayLaneH + overlayLaneGap) + 6
    }
    private var totalHeight: CGFloat { overlayAreaTop + overlayAreaHeight + 20 }

    private func overlayLaneY(_ lane: Int) -> CGFloat {
        overlayAreaTop + CGFloat(min(max(0, lane), max(0, overlayLaneCount - 1))) * (overlayLaneH + overlayLaneGap)
    }
    private func overlayRect(_ i: Int) -> CGRect {
        let c = overlays[i]
        var s = CGFloat(c.start), dur = CGFloat(max(0.1, c.duration)), lane = c.lane
        if let mp = overlayMultiPreview?[c.id] { s = CGFloat(mp.s); lane = mp.lane }
        else if let pv = overlayPreview, pv.id == c.id { s = pv.start; dur = pv.dur; lane = pv.lane }
        return CGRect(x: s * pps, y: overlayLaneY(lane),
                      width: max(6, dur * pps), height: overlayLaneH)
    }

    var followScroll = true
    var timeProvider: (() -> TimeInterval)?
    private var displayLink: DisplayLink?
    private var linkRunning = false
    private var lastState: (Int, CGFloat, Int, Int, Int) = (0, 0, 0, 0, 0)

    /// Khi phát: CoreAnimation tự nội suy vạch đỏ trên render-server (mượt tuyệt đối,
    /// KHÔNG tốn luồng chính). Luồng chính chỉ đụng vào lúc play / pause / seek / zoom.
    private var playAnimActive = false
    private var animPPS: CGFloat = 0
    private var animDur: CGFloat = 0
    private var lastAuxTick: CFTimeInterval = 0
    private var lastSeekGen = Int.min

    deinit { displayLink?.stop() }

    func applyState(samples: [Float], duration: CGFloat, pointsPerSecond: CGFloat,
                    lines: [LyricLine], selectedIndex: Int,
                    overlays: [OverlayClip], selOverlayID: UUID?, selOverlayIDs: Set<UUID> = []) {
        self.samples = samples
        self.duration = max(duration, 0.1)
        self.pps = pointsPerSecond
        self.lines = lines
        self.overlays = overlays
        self.selOverlayID = selOverlayID
        self.selOverlayIDs = selOverlayIDs
        if overlayDrag == nil, overlayMultiPreview != nil { overlayMultiPreview = nil }
        // Model mới đã về → bỏ xem-trước khi không còn kéo.
        if overlayDrag == nil, overlayPreview != nil { overlayPreview = nil }
        if overlayDrag == nil, overlayFadePreview != nil { overlayFadePreview = nil }
        if selectedIndex != self.selectedIndex {
            endEdit(commit: true)
            // (2026-09-24) SỬA LỖI "Cmd+click chữ đầu tiên không ăn": khi bấm Cmd vào 1 chữ của
            // dòng CHƯA active, `mouseDown` tự kích hoạt dòng đó NGAY (gán `selIDs` cục bộ +
            // gọi `onSelect?`) để nhận diện đúng chữ trong CÙNG 1 lần bấm — khỏi phải bấm 2 lần.
            // NHƯNG `onSelect?` chỉ cập nhật `currentLineIndex` bên SwiftUI KHÔNG ĐỒNG BỘ; khi
            // `applyState` này chạy lại (trễ hơn) với đúng `selectedIndex` đó, nếu vẫn xoá
            // `selWords`/`selWord` như cũ thì chữ vừa chọn được sẽ bị XOÁ NGAY SAU KHI CHỌN —
            // trông y như "bấm không ăn". Nếu dòng active CỤC BỘ (`activeLine`) đã khớp sẵn với
            // `selectedIndex` mới rồi (tức đây chỉ là SwiftUI xác nhận lại điều đã biết, không
            // phải người dùng vừa đổi dòng khác) → GIỮ NGUYÊN `selWord`/`selWords`, không xoá.
            let alreadyMatchesLocally = activeLine == selectedIndex
            self.selectedIndex = selectedIndex
            if selIDs.count <= 1, lines.indices.contains(selectedIndex) {
                selIDs = [lines[selectedIndex].id]
                if !alreadyMatchesLocally { selWord = -1 }
            }
            if !alreadyMatchesLocally { selWords = [] }
        }
        // Bỏ các id đã biến mất khỏi danh sách.
        let present = Set(lines.map(\.id))
        selIDs.formIntersection(present)

        // Model đã phản ánh thao tác vừa commit → giờ mới xoá preview (khớp liền, không giật).
        if holdPreview {
            previewBlocks = [:]; previewNeighbor = nil; wordPreview = []
            snapGuideT = nil; readout = nil; holdPreview = false
            needsDisplay = true
        }

        recomputeLanes()
        recomputeSelBlock()

        let size = NSSize(width: contentWidth, height: totalHeight)
        if frame.size != size { setFrameSize(size) }
        layoutPlayhead()

        // Zoom / đổi độ dài khi đang phát → toạ độ pixel của animation cũ sai → phát lại.
        if playAnimActive, pps != animPPS || duration != animDur {
            startPlayheadAnimation(from: CGFloat(timeProvider?() ?? Double(currentTime)))
        }

        if let a = pendingZoomAnchor, let sv = enclosingScrollView {
            let maxX = max(0, contentWidth - sv.contentView.bounds.width)
            let nx = min(max(0, a.time * pps - a.screenX), maxX)
            sv.contentView.scroll(to: NSPoint(x: nx, y: 0))
            sv.reflectScrolledClipView(sv.contentView)
            pendingZoomAnchor = nil
        }

        var h = Hasher()
        for l in lines {
            h.combine(l.id); h.combine(l.start ?? -1); h.combine(l.end ?? -1)
            h.combine(l.words.count); h.combine(l.words.first?.start ?? -1)
            h.combine(l.words.last?.end ?? -1); h.combine(l.text)
            h.combine(l.singer)
        }
        h.combine(duetMode)
        var scHash = 0                               // hash dict KHÔNG cấp phát, không phụ thuộc thứ tự
        for (k, v) in singerColors { scHash ^= (k.hashValue &* 31 &+ v.hashValue) }
        h.combine(scHash)
        for c in overlays {
            h.combine(c.id); h.combine(c.start); h.combine(c.duration); h.combine(c.lane)
            h.combine(c.isHidden); h.combine(c.name)
            h.combine(c.fadeIn); h.combine(c.fadeOut)
        }
        let selHash = selIDs.reduce(0) { $0 ^ $1.hashValue } ^ (selWord << 1)
            ^ selWords.reduce(0) { $0 ^ ($1 &* 5) }
            ^ (selOverlayID?.hashValue ?? 0)
            ^ selOverlayIDs.reduce(0) { $0 ^ ($1.hashValue &* 7) }
            ^ overlayGroups.reduce(0) { $0 ^ ($1.id.hashValue &* 13 &+ $1.name.hashValue &+ $1.memberIDs.count) }
            ^ vizKeyframeTimes.reduce(0) { $0 ^ Int(($1 * 100).rounded()) }
            ^ textKeyframeTimes.reduce(0) { $0 ^ (Int(($1 * 100).rounded()) &* 3) }
        let now = (samples.count, pointsPerSecond, selectedIndex, h.finalize(), selHash)
        if lastState != now { lastState = now; needsDisplay = true }
    }

    private func recomputeSelBlock() {
        guard selIDs.count == 1, let id = selIDs.first,
              let i = lines.firstIndex(where: { $0.id == id }), let s = lines[i].start,
              let hi = lines[i].words.last?.end ?? lines[i].end,
              let lo = lines[i].words.first?.start ?? lines[i].start else { selBlockFrame = nil; return }
        _ = s
        // Vệt quét bám HÀNG CHỮ (dải dưới), không phủ thanh dòng.
        selBlockFrame = CGRect(x: (CGFloat(lo) + lyricOff) * pps, y: laneY(laneOf[i] ?? 0) + wordBandTop,
                               width: max(2, CGFloat(hi - lo) * pps),
                               height: max(6, selBlockH - wordBandTop))
    }

    /// Trả `true` nếu lần gọi này VỪA chuyển từ phát → dừng (để bên ngoài khỏi nắn lại vạch đỏ).
    @discardableResult
    func setPlaying(_ playing: Bool) -> Bool {
        guard playing != linkRunning else { return false }
        linkRunning = playing
        if playing {
            startPlayheadAnimation(from: CGFloat(timeProvider?() ?? Double(currentTime)))
            if displayLink == nil {
                displayLink = DisplayLink { [weak self] in self?.playTick() }
            }
            displayLink?.start()
            return false
        } else {
            displayLink?.stop()
            stopPlayheadAnimation()
            return true
        }
    }

    /// Tua (seek) — lúc phát thì phát lại animation từ mốc mới; lúc dừng thì đặt vạch đỏ.
    func noteSeekGen(_ g: Int) {
        guard g != lastSeekGen else { return }
        let first = lastSeekGen == Int.min
        lastSeekGen = g
        let t = CGFloat(timeProvider?() ?? Double(currentTime))
        if linkRunning {
            if !first { startPlayheadAnimation(from: t) }
        } else {
            setPlayheadTime(t, follow: false)
        }
    }

    /// Ghi nhận `seekGen` mà KHÔNG làm gì (dùng khi vừa pause — freezePlayhead đã lo).
    func consumeSeekGen(_ g: Int) { lastSeekGen = g }

    /// (2026-09-13) ĐỔI CƠ CHẾ: trước dùng 1 `CABasicAnimation` chạy trên render-server suốt
    /// lúc phát (mượt, không tốn luồng chính MỖI KHUNG) — nhưng đo bằng `sample` lúc user báo
    /// "lag toàn bộ app, làm gì cũng lag" phát hiện: hễ có BẤT KỲ CAAnimation nào đang chạy
    /// trong cửa sổ, AppKit tự đồng bộ CẢ CỬA SỔ theo vsync và CHẠY LẠI Auto Layout của TOÀN BỘ
    /// cây view mỗi lần — rất nặng trên máy Intel cũ (gần 1 nửa thời gian luồng chính), dù nhẹ
    /// tênh trên Apple Silicon nên trước giờ không lộ ra. Giờ tự set `position.x` mỗi khung
    /// (đọc thẳng đồng hồ mượt `timeProvider`, không nội suy riêng — "TIME là nguồn sự thật")
    /// qua `DisplayLink` sẵn có — KHÔNG còn `CAAnimation` nào chạy nên không còn kéo cả cửa sổ
    /// vào chế độ đồng bộ vsync đó nữa. KHÔNG đổi điểm GỌI (play/seek/zoom) hay phần vệt-quét/
    /// tự-cuộn 15Hz đã tinh chỉnh trước đó (xem [[smoothness-standard]] — khu vực này đã từng
    /// sửa hỏng 1 lần, "ĐỪNG SỬA KÈM").
    private func startPlayheadAnimation(from t0: CGFloat) {
        guard duration > 0, pps > 0 else { return }
        currentTime = max(0, min(duration, t0))
        let x0 = currentTime * pps
        animPPS = pps; animDur = duration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playheadLayer.position.x = x0
        triLayer.position.x = x0
        updateSweep()
        CATransaction.commit()
        playAnimActive = true
    }

    /// Ghim vạch đỏ ngay lúc `pause()` (gọi từ Combine sink, ĐỒNG BỘ).
    func freezePlayhead(atTime _: CGFloat) { freezeAnimationInPlace() }

    private func stopPlayheadAnimation() { freezeAnimationInPlace() }

    /// Dừng cập nhật mỗi khung — vị trí layer đã đúng sẵn từ lần `playTick` gần nhất (đọc thẳng
    /// đồng hồ mượt), không còn animation nào để "đóng băng" hay nắn lại như cách CAAnimation cũ.
    private func freezeAnimationInPlace() {
        guard playAnimActive else { return }
        playAnimActive = false
        currentTime = max(0, min(duration, CGFloat(timeProvider?() ?? Double(currentTime))))
    }

    /// Mỗi khung (không throttle): CHỈ set vị trí vạch đỏ — thay cho CAAnimation cũ.
    /// 15Hz (không phải mỗi vsync): vệt quét + tự cuộn — GIỮ NGUYÊN nhịp cũ, không đụng.
    /// (2026-09-14) Vị trí vạch đỏ hạ còn ~30Hz (không phải mỗi vsync) — CỨ MỖI LẦN cửa sổ
    /// commit CATransaction theo vsync (không riêng gì có animation hay không), AppKit chạy lại
    /// Auto Layout CẢ CỬA SỔ (đo bằng `sample`); bỏ CAAnimation ở đây (2026-09-13) không đủ vì
    /// việc tự set `position` mỗi khung CŨNG tạo ra đúng chi phí đó. Giảm tần suất giảm chi phí.
    private var lastPlayheadDraw: CFTimeInterval = 0

    private func playTick() {
        if playAnimActive, let tp = timeProvider {
            let nowClock = CACurrentMediaTime()
            if nowClock - lastPlayheadDraw >= 1.0 / 30.0 {
                lastPlayheadDraw = nowClock
                let t = CGFloat(min(duration, max(0, tp())))
                let x = t * pps
                CATransaction.begin(); CATransaction.setDisableActions(true)
                playheadLayer.position.x = x
                triLayer.position.x = x
                CATransaction.commit()
            }
        }
        let now = CACurrentMediaTime()
        guard now - lastAuxTick >= 1.0 / 15.0 else { return }
        lastAuxTick = now
        guard let tp = timeProvider else { return }
        let t = CGFloat(tp())
        currentTime = t
        CATransaction.begin(); CATransaction.setDisableActions(true)
        updateSweep()
        CATransaction.commit()
        if followScroll { followPlayheadScroll(x: t * pps) }
    }

    /// Chỉ cuộn khi vạch đỏ chạm vùng 12% mép phải (hoặc lọt khỏi mép trái) — cuộn
    /// theo "trang", KHÔNG cuộn liên tục từng khung (đó là thứ gây khựng khi phát).
    private func followPlayheadScroll(x: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        let vw = sv.contentView.bounds.width
        let ox = sv.contentView.bounds.origin.x
        guard x > ox + vw * 0.88 || x < ox else { return }
        let target = max(0, min(x - vw * 0.15, max(0, contentWidth - vw)))
        guard abs(target - ox) > 1 else { return }
        sv.contentView.scroll(to: NSPoint(x: target, y: 0))
        sv.reflectScrolledClipView(sv.contentView)
    }

    func setPlayheadTime(_ t: CGFloat, follow: Bool) {
        let newX = t * pps
        // Bỏ qua dịch dưới 0.5px (nhiễu làm tròn khi dừng) — khỏi giật vặt.
        if abs(newX - currentTime * pps) < 0.5 { return }
        currentTime = t
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playheadLayer.position.x = newX
        triLayer.position.x = newX
        updateSweep()
        CATransaction.commit()
        if follow { followPlayheadScroll(x: newX) }
    }

    private func renderEnd(of l: LyricLine) -> CGFloat {
        guard let s = l.start else { return 0 }
        return CGFloat(l.end ?? max(Double(currentTime), s + 0.05))
    }

    private func recomputeLanes() {
        laneOf.removeAll()
        let timed = lines.indices.filter { lines[$0].start != nil }
            .sorted { (lines[$0].start ?? 0) < (lines[$1].start ?? 0) }
        var laneEnd: [CGFloat] = []
        for i in timed {
            let s = CGFloat(lines[i].start!), e = renderEnd(of: lines[i])
            if let lane = laneEnd.firstIndex(where: { $0 <= s + 0.001 }) {
                laneEnd[lane] = e; laneOf[i] = lane
            } else if laneEnd.count < maxLanes {
                laneEnd.append(e); laneOf[i] = laneEnd.count - 1
            } else { laneOf[i] = maxLanes - 1 }
        }
    }

    private var activeLine: Int? {
        guard selIDs.count == 1, let id = selIDs.first else {
            return lines.indices.contains(selectedIndex) ? selectedIndex : nil
        }
        return lines.firstIndex { $0.id == id }
    }

    private func blockRect(_ i: Int) -> CGRect {
        var s = CGFloat(lines[i].start ?? 0)
        var e = renderEnd(of: lines[i])
        if let pv = previewBlocks[i] { s = pv.0; e = pv.1 }
        if let n = previewNeighbor, n.index == i { s = n.start; e = n.end }
        let h = (i == activeLine) ? selBlockH : laneHeight
        return CGRect(x: (s + lyricOff) * pps, y: laneY(laneOf[i] ?? 0), width: max(10, (e - s) * pps), height: h)
    }

    // MARK: Vẽ

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let width = contentWidth
        if let img = waveformImageIfNeeded() {
            // Bước 2c — sóng "Nhạc" cũng dời theo clip ★: đầu timeline là khoảng TRỐNG,
            // sóng bắt đầu ở `lyricOff` và dài đúng bằng bài.
            let songW = (karaokeSongLen > 0.5 ? karaokeSongLen : max(0, duration - lyricOff)) * pps
            img.draw(in: CGRect(x: lyricOff * pps, y: waveTop, width: max(1, songW), height: waveHeight))
        }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: rulerH))
        ctx.setFillColor(NSColor.separatorColor.cgColor)
        ctx.fill(CGRect(x: 0, y: rulerH - 1, width: width, height: 1))
        let mAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]
        let labelStep: Int = pps >= 90 ? 1 : (pps >= 45 ? 2 : (pps >= 20 ? 5 : (pps >= 9 ? 10 : 30)))
        let tickStep = max(1, labelStep / 5)
        var sec = 0
        while CGFloat(sec) <= duration {
            let x = CGFloat(sec) * pps
            if x >= dirty.minX - 60, x <= dirty.maxX + 4 {
                let major = sec % labelStep == 0
                ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
                ctx.fill(CGRect(x: x, y: major ? 3 : rulerH - 6, width: 1, height: major ? rulerH - 4 : 5))
                if major {
                    ("\(sec)" as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: mAttrs)
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
                    ctx.fill(CGRect(x: x, y: rulerH, width: 1, height: totalHeight - rulerH))
                }
            }
            sec += tickStep
        }

        // Hình thoi keyframe SÓNG NHẠC / KHỐI CHỮ KARAOKE trên mép dưới thước (giờ bài + mốc ★).
        func drawRulerDiamonds(_ times: [Double], _ color: NSColor, yTop: CGFloat) {
            guard !times.isEmpty else { return }
            color.setFill()
            for songT in times {
                let x = CGFloat(songT + Double(karaokeClipStart)) * pps
                guard x >= dirty.minX - 6, x <= dirty.maxX + 6 else { continue }
                let d: CGFloat = 3
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x, y: yTop)); p.line(to: NSPoint(x: x + d, y: yTop + d))
                p.line(to: NSPoint(x: x, y: yTop + d * 2)); p.line(to: NSPoint(x: x - d, y: yTop + d))
                p.close(); p.fill()
            }
        }
        drawRulerDiamonds(vizKeyframeTimes, Theme.NS.accent, yTop: rulerH - 8)
        drawRulerDiamonds(textKeyframeTimes, Theme.NS.warning, yTop: rulerH - 8)

        // Nhãn track ở mép trái (như CapCut) + nền mờ cho dải "Lời".
        let trackLabel: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.quaternaryLabelColor]
        (L("Nhạc") as NSString).draw(at: NSPoint(x: 4, y: waveTop + 2), withAttributes: trackLabel)
        let lyricBand = CGRect(x: 0, y: laneAreaTop - 4, width: width,
                               height: CGFloat(maxLanes) * (laneHeight + laneGap))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.022).cgColor)
        ctx.fill(lyricBand)
        (L("Lời") as NSString).draw(at: NSPoint(x: 4, y: laneAreaTop - 3), withAttributes: trackLabel)

        drawKaraokeClip(ctx, width: width)

        let act = activeLine
        for i in lines.indices where i != act { drawBlock(ctx, i: i, dirty: dirty) }
        if let a = act { drawBlock(ctx, i: a, dirty: dirty) }

        drawStaging(ctx, width: width)
        drawOverlayStrip(ctx, width: width)

        // Đang rê file từ kho lên → tô sáng làn + vạch chỗ sắp thả.
        if let dh = dropHover {
            let y = overlayLaneY(dh.lane)
            let laneR = CGRect(x: 0, y: y, width: width, height: overlayLaneH)
            Theme.accentNS.withAlphaComponent(0.18).setFill()
            NSBezierPath(rect: laneR).fill()
            let x = dh.t * pps
            Theme.accentNS.setStroke()
            let g = NSBezierPath()
            g.move(to: NSPoint(x: x, y: y - 3)); g.line(to: NSPoint(x: x, y: y + overlayLaneH + 3))
            g.lineWidth = 2; g.stroke()
        }

        if let m = marqueeRect ?? wordMarqueeRect {
            let p = NSBezierPath(rect: m)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); p.fill()
            NSColor.controlAccentColor.setStroke(); p.lineWidth = 1
            p.setLineDash([4, 3], count: 2, phase: 0); p.stroke()
        }

        // Vạch canh nam châm (P2).
        if let gt = snapGuideT {
            let x = gt * pps
            let g = NSBezierPath()
            g.move(to: NSPoint(x: x, y: rulerH)); g.line(to: NSPoint(x: x, y: totalHeight))
            NSColor.systemYellow.setStroke(); g.lineWidth = 1
            g.setLineDash([3, 3], count: 2, phase: 0); g.stroke()
        }
        // Ô đọc mm:ss.cc nổi cạnh con trỏ.
        if let r = readout {
            let str = fmtTime(r.t)
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white]
            let sz = (str as NSString).size(withAttributes: a)
            let bx = min(max(0, r.at.x + 12), width - sz.width - 10)
            let by = min(max(rulerH + 4, r.at.y - 24), totalHeight - sz.height - 6)
            let box = CGRect(x: bx, y: by, width: sz.width + 8, height: sz.height + 4)
            NSColor.black.withAlphaComponent(0.82).setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            (str as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: a)
        }

        drawDuetLayer(width: width)
    }

    /// Icon người hát đã gán + bảng chọn 3 icon (chế độ Song ca).
    private func drawDuetLayer(width: CGFloat) {
        // Badge trên các khối đã gán (luôn hiện, kể cả ngoài chế độ).
        for i in lines.indices where lines[i].start != nil {
            guard let role = lines[i].singer else { continue }
            let b = blockRect(i)
            drawSingerIcon(role, in: CGRect(x: b.minX + 2, y: b.minY - 19, width: 20, height: 17))
        }
        guard duetMode else { return }
        // Viền accent + nhãn báo "đang ở chế độ Song ca".
        NSColor.controlAccentColor.setStroke()
        let edge = NSBezierPath(rect: CGRect(x: 1.5, y: rulerH + 1.5, width: width - 3, height: totalHeight - rulerH - 3))
        edge.lineWidth = 2.5; edge.setLineDash([7, 4], count: 2, phase: 0); edge.stroke()
        let lbl = L("CHẾ ĐỘ SONG CA — bấm khối câu để chọn người hát")
        let la: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
        let lsz = (lbl as NSString).size(withAttributes: la)
        let lbox = CGRect(x: 8, y: rulerH + 4, width: lsz.width + 12, height: lsz.height + 5)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: lbox, xRadius: 4, yRadius: 4).fill()
        (lbl as NSString).draw(at: NSPoint(x: lbox.minX + 6, y: lbox.minY + 2), withAttributes: la)

        guard let li = duetPickerLine, lines.indices.contains(li) else { return }
        let rects = duetIconRects(for: li)
        let bg = rects[0].union(rects[3]).insetBy(dx: -6, dy: -6)
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6).fill()
        NSColor.controlAccentColor.setStroke()
        let bp = NSBezierPath(roundedRect: bg, xRadius: 6, yRadius: 6); bp.lineWidth = 1; bp.stroke()
        for (k, r) in rects.enumerated() {
            if k < 3 {
                drawSingerIcon(SingerRole.allCases[k], in: r.insetBy(dx: 1, dy: 1))
            } else {
                // ô XOÁ (✕)
                NSColor.systemRed.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
                let x = NSBezierPath()
                let ir = r.insetBy(dx: 8, dy: 8)
                x.move(to: NSPoint(x: ir.minX, y: ir.minY)); x.line(to: NSPoint(x: ir.maxX, y: ir.maxY))
                x.move(to: NSPoint(x: ir.minX, y: ir.maxY)); x.line(to: NSPoint(x: ir.maxX, y: ir.minY))
                NSColor.systemRed.setStroke(); x.lineWidth = 2; x.lineCapStyle = .round; x.stroke()
            }
        }
    }

    /// Bước 1–2 — clip ★ KARAOKE: track đầu, màu riêng (xanh ngọc) + dấu ★. Kéo thân =
    /// dời cả cụm; kéo mép = cắt đầu/cuối bài. KHÔNG đụng timing/chữ — chỉ là "tay cầm".
    private func drawKaraokeClip(_ ctx: CGContext, width: CGFloat) {
        // Nền dải (mảnh) — luôn hiện để có cấu trúc track như CapCut.
        let bandRect = CGRect(x: 0, y: karaokeStripTop, width: width, height: karaokeStripH)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.03).cgColor)
        ctx.fill(bandRect)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        ctx.fill(CGRect(x: 0, y: karaokeStripTop + karaokeStripH - 1, width: width, height: 1))

        guard karaokeHasContent else {
            (L("KARAOKE — tạo karaoke xong sẽ hiện ở đây") as NSString).draw(
                at: NSPoint(x: 8, y: karaokeStripTop + 5),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: Theme.NS.inkFaint])
            return
        }

        let r = karaokeClipRect()
        let teal = Theme.NS.trackKaraoke
        let dragging = karaokeDrag != nil
        let body = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        teal.withAlphaComponent(dragging ? 0.42 : 0.30).setFill(); body.fill()
        teal.setStroke(); body.lineWidth = dragging ? 2 : 1.5; body.stroke()

        // Nhãn: icon micro (+ icon tắt tiếng nếu tắt tiếng chung) + "KARAOKE" — SF Symbols thay emoji.
        let la: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        var clip = r.insetBy(dx: 8, dy: 2)
        if clip.width > 20 {
            for name in (karaokeMuted ? ["speaker.slash.fill", "music.mic"] : ["music.mic"]) {
                guard clip.width > 14, let img = Theme.NS.symbol(name, size: 9) else { continue }
                let s = img.size
                img.draw(in: CGRect(x: clip.minX, y: r.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 0.92, respectFlipped: true, hints: nil)
                clip.origin.x += s.width + 4; clip.size.width -= s.width + 4
            }
            if clip.width > 20 {
                ("KARAOKE" as NSString).draw(with: clip,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: la)
            }
        }

        // Mốc bắt đầu > 0 → vạch mảnh nối về 0 để thấy "đã dời".
        if karaokeShownStart > 0.001 {
            teal.withAlphaComponent(0.5).setStroke()
            let lead = NSBezierPath()
            lead.move(to: NSPoint(x: 0, y: r.midY))
            lead.line(to: NSPoint(x: r.minX, y: r.midY))
            lead.lineWidth = 1
            lead.setLineDash([3, 2], count: 2, phase: 0)
            lead.stroke()
        }
    }

    /// Khu vực CHỜ (staging) — dòng và chữ được vẽ ở 2 hàng riêng, không đè lên nhau.
    // (2026-09-23) Bỏ hẳn nút "✕ Huỷ" — nó luôn đứng CHỒNG lên câu hướng dẫn kế bên (bug cũ,
    // 2 rect gần như trùng toạ độ) và giờ càng rối khi ô nhập chữ mở ngay khi tạo item. Muốn
    // bỏ 1 item CHỜ: bấm phím Esc (đã có sẵn từ trước, xem `keyDown`). Câu hướng dẫn cũng ẨN
    // trong lúc đang GÕ CHỮ (mở ngay khi bấm "Thêm chữ"/"Thêm dòng") để khỏi chồng lên ô nhập.
    private func drawStaging(_ ctx: CGContext, width: CGFloat) {
        guard stagingActive else { return }
        let top = lyricAreaBottom + 6 - 3
        let h = CGFloat(stagingActiveCount) * stagingLaneH + CGFloat(stagingActiveCount - 1) * 6
        NSColor.white.withAlphaComponent(0.04).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: top, width: width, height: h)).fill()
        drawStagingItem(ctx, width: width, kind: .line)
        drawStagingItem(ctx, width: width, kind: .word)
    }

    /// Màu riêng theo loại — DÒNG = cam, CHỮ = xanh dương — để phân biệt rõ 2 thứ khi cả 2
    /// cùng đang chờ (trước đây cả 2 đều cam, dễ lẫn).
    private func stagingTint(_ k: StageKind) -> NSColor { k == .line ? Theme.NS.stagingLine : Theme.NS.stagingWord }

    private func drawStagingItem(_ ctx: CGContext, width: CGFloat, kind k: StageKind) {
        guard let st = staging(k), let sr = stagingRect(k) else { return }
        let tint = stagingTint(k)
        let dragging = stagingDragging && stagingDragKind == k
        let editingThis = editingStageKind == k
        let selected = stagingSelected == k

        // Highlight chỗ SẼ THẢ VÀO khi đang kéo — CHỮ: viền quanh DÒNG đang nhắm tới;
        // DÒNG: viền quanh KHE TRỐNG hiện tại (2026-09-23, trước chỉ có cho chữ, dòng không
        // có gì báo "thả đúng chỗ" — user báo thiếu, giờ thêm y hệt kiểu chữ).
        if dragging, !st.isLine, let li = stagingDropLine {
            let r = blockRect(li).insetBy(dx: -2, dy: -2)
            Theme.NS.success.withAlphaComponent(0.9).setStroke()
            let gp = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4); gp.lineWidth = 2; gp.stroke()
        }
        if dragging, st.isLine, let g = stagingDropGap {
            let r = CGRect(x: (g.lo + lyricOff) * pps, y: laneY(0),
                           width: max(2, (g.hi - g.lo) * pps), height: laneHeight).insetBy(dx: 2, dy: 2)
            Theme.NS.success.withAlphaComponent(0.9).setStroke()
            let gp = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4); gp.lineWidth = 2; gp.stroke()
        }

        let p = NSBezierPath(roundedRect: sr, xRadius: 4, yRadius: 4)
        tint.withAlphaComponent(dragging ? 0.42 : 0.30).setFill(); p.fill()
        (selected && !dragging ? NSColor.white : tint).setStroke()
        p.lineWidth = (selected && !dragging) ? 3 : 2
        p.stroke()
        // Chữ trong ô — ẩn khi đang gõ (ô nhập TO đã đè lên đúng chỗ này rồi).
        if !st.text.isEmpty, !editingThis {
            let ps = NSMutableParagraphStyle()
            ps.alignment = .center; ps.lineBreakMode = .byTruncatingTail
            (st.text as NSString).draw(with: sr.insetBy(dx: 4, dy: 3),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                             .foregroundColor: NSColor.labelColor, .paragraphStyle: ps])
        }

        // Tay nắm kéo dãn ở 2 mép (khi không kéo, không gõ).
        if !dragging, !editingThis {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            for gx in [sr.minX + 4, sr.maxX - 4] {
                let g = NSBezierPath()
                g.move(to: NSPoint(x: gx, y: sr.minY + 4)); g.line(to: NSPoint(x: gx, y: sr.maxY - 4))
                g.lineWidth = 1.5; g.stroke()
            }
        }

        // Câu hướng dẫn — bên cạnh item (ẩn khi đang kéo HOẶC đang gõ chữ).
        if !dragging, !editingThis {
            let msg = st.isLine
                ? L("Kéo LÊN thả vào chỗ trống trong hàng lời")
                : L("Kéo LÊN thả vào TRONG 1 dòng (chỗ còn trống)")
            let a: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: tint]
            let tsz = (msg as NSString).size(withAttributes: a)
            var tx = sr.maxX + 10
            if tx + tsz.width + 10 > width - 4 {              // hết chỗ bên phải → nhãn sang TRÁI item
                tx = max(2, sr.minX - tsz.width - 10)
            }
            (msg as NSString).draw(at: NSPoint(x: tx, y: sr.midY - tsz.height / 2), withAttributes: a)
        }
    }

    /// Ảnh đại diện cho clip `.image` — đọc thẳng (đồng bộ, đã cache sẵn), lặp lại thành vệt
    /// (ảnh tĩnh không có "nhiều khung khác nhau" để trải như video).
    private func overlayThumbnail(_ c: OverlayClip) -> CGImage? {
        guard c.kind == .image else { return nil }
        return OverlayImageStore.image(for: c)
    }

    /// Vẽ `img` phủ kín `rect` kiểu "aspect-fill" (cắt cho vừa, không méo), kẹp trong `rect`.
    private func drawAspectFillTile(_ img: CGImage, in rect: CGRect, ctx: CGContext) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0, rect.width > 0, rect.height > 0 else { return }
        let s = max(rect.width / iw, rect.height / ih)
        let w = iw * s, h = ih * s
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    /// Trải `thumb` thành nhiều ô vuông-ish lấp kín `r` — dùng cho clip ẢNH (1 khung, lặp lại).
    private func drawFilmstrip(_ thumb: CGImage, in r: CGRect, ctx: CGContext) {
        let tileW = max(28, r.height)
        var x = r.minX
        while x < r.maxX {
            let tile = CGRect(x: x, y: r.minY, width: min(tileW, r.maxX - x), height: r.height)
            drawAspectFillTile(thumb, in: tile, ctx: ctx)
            x += tileW
        }
    }

    /// Filmstrip THẬT cho clip VIDEO — mỗi "lát" hiển thị 1 khung KHÁC NHAU lấy đều dọc theo
    /// đoạn clip đang dùng (không lặp y hệt 1 khung như ảnh tĩnh). Khung lấy từ
    /// `VideoFilmstripStore` (cache riêng, 6 khung/clip, không phụ thuộc độ rộng vẽ) — thiếu khung
    /// nào thì tự hẹn vẽ lại sau khi có, dồn tối đa 1 lần hẹn cho mỗi clip.
    private func drawVideoFilmstrip(_ c: OverlayClip, in r: CGRect, ctx: CGContext) {
        guard let url = c.resolveURL() else { return }
        let tileW = max(28, r.height)
        let nTiles = max(1, Int((r.width / tileW).rounded(.up)))
        let total = VideoFilmstripStore.frameCount
        var missing = false
        var x = r.minX
        var tileIdx = 0
        while x < r.maxX {
            let tile = CGRect(x: x, y: r.minY, width: min(tileW, r.maxX - x), height: r.height)
            let frac = nTiles > 1 ? Double(tileIdx) / Double(nTiles - 1) : 0
            let fIndex = min(total - 1, max(0, Int((frac * Double(total - 1)).rounded())))
            if let img = VideoFilmstripStore.frame(path: c.lastKnownPath, url: url,
                                                    trimStart: c.trimStart, trimEnd: c.trimStart + c.duration,
                                                    index: fIndex) {
                drawAspectFillTile(img, in: tile, ctx: ctx)
            } else {
                missing = true
            }
            x += tileW; tileIdx += 1
        }
        if missing, pendingThumbRedraw.insert(c.id).inserted {
            let id = c.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.pendingThumbRedraw.remove(id)
                self?.needsDisplay = true
            }
        }
    }

    private func drawOverlayStrip(_ ctx: CGContext, width: CGFloat) {
        guard overlayLaneCount > 0 else { return }
        // Nền dải.
        let stripRect = CGRect(x: 0, y: overlayAreaTop - 4, width: width, height: overlayAreaHeight)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.03).cgColor)
        ctx.fill(stripRect)

        // Làn trống có sẵn (kể cả chưa có clip) — để trông có cấu trúc track như CapCut.
        for lane in 0..<overlayLaneCount {
            let y = overlayLaneY(lane)
            let laneRect = CGRect(x: 0, y: y, width: width, height: overlayLaneH)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.028).cgColor)
            NSBezierPath(roundedRect: laneRect.insetBy(dx: 0, dy: 0.5), xRadius: 2, yRadius: 2).fill()
            (String(format: L("Lớp đè %d"), lane + 1) as NSString).draw(
                at: NSPoint(x: 4, y: y + 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                 .foregroundColor: Theme.NS.inkFaint])
        }
        if overlays.isEmpty {
            (L("Kéo ảnh / video / nhạc từ “File của bạn” xuống đây") as NSString).draw(
                at: NSPoint(x: 70, y: overlayLaneY(0) + 3),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10),
                                 .foregroundColor: Theme.NS.inkFaint])
        }

        for i in overlays.indices {
            let c = overlays[i]
            let base = c.kind == .audio ? Theme.NS.trackAudio : (c.kind == .text ? Theme.NS.trackText : Theme.NS.trackMedia)
            let r = overlayRect(i)
            let sel = c.id == selOverlayID || selOverlayIDs.contains(c.id)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            // Ảnh → trải vệt "phim" (1 khung lặp lại). Video → filmstrip THẬT (nhiều khung khác
            // nhau dọc clip), kiểu CapCut/Premiere.
            let showThumb = (c.kind == .image || c.kind == .video) && !c.isHidden
            let imageThumb = c.kind == .image && showThumb ? overlayThumbnail(c) : nil
            if showThumb, c.kind == .video {
                ctx.saveGState()
                path.setClip()
                drawVideoFilmstrip(c, in: r, ctx: ctx)
                ctx.restoreGState()
                base.withAlphaComponent(sel ? 0.34 : 0.16).setFill(); path.fill()   // phủ nhẹ, vẫn thấy màu track
            } else if let imageThumb {
                ctx.saveGState()
                path.setClip()
                drawFilmstrip(imageThumb, in: r, ctx: ctx)
                ctx.restoreGState()
                base.withAlphaComponent(sel ? 0.34 : 0.16).setFill(); path.fill()
            } else {
                base.withAlphaComponent(c.isHidden ? 0.12 : (sel ? 0.5 : 0.26)).setFill(); path.fill()
            }
            (sel ? NSColor.white : base.withAlphaComponent(0.7)).setStroke()
            path.lineWidth = sel ? 2 : 1
            if c.isHidden { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
            // Nhãn kiểu "chip" nền tối — tên + thời lượng, LUÔN đọc rõ dù có ảnh phía sau.
            if r.width > 24 {
                let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
                // Icon SF Symbols (thay emoji 🎬 🎵 🅰 🚫 🔇): loại clip + ẩn + tắt tiếng.
                var icons: [String] = [c.kind == .video ? "film" : c.kind == .audio ? "music.note" : c.kind == .text ? "textformat" : "photo"]
                if c.isHidden { icons.append("eye.slash") }
                if c.kind == .audio && c.audioMuted { icons.append("speaker.slash.fill") }
                let imgs = icons.compactMap { Theme.NS.symbol($0, size: 8) }
                let iconsW = imgs.reduce(CGFloat(0)) { $0 + $1.size.width + 3 }
                let label = c.kind == .text ? (c.text.isEmpty ? L("Chữ") : c.text) : c.name
                let full = label + "   " + TimeFormatting.clock(c.duration)
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                             .foregroundColor: NSColor.white, .paragraphStyle: para]
                let maxW = max(10, r.width - 10 - iconsW)
                let textSize = (full as NSString).boundingRect(
                    with: CGSize(width: maxW, height: 20),
                    options: [.usesLineFragmentOrigin], attributes: attrs).size
                let chipRect = CGRect(x: r.minX + 3, y: r.maxY - textSize.height - 7,
                                      width: min(r.width - 6, iconsW + textSize.width + 10), height: textSize.height + 4)
                NSColor.black.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3).fill()
                var ix = chipRect.minX + 5
                for img in imgs where ix + img.size.width < chipRect.maxX - 4 {
                    img.draw(in: CGRect(x: ix, y: chipRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height),
                             from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
                    ix += img.size.width + 3
                }
                let textRect = CGRect(x: ix, y: chipRect.minY + 2, width: max(0, chipRect.maxX - 5 - ix), height: chipRect.height - 4)
                if textRect.width > 6 {
                    (full as NSString).draw(with: textRect,
                                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                }
            }
            // Dốc "hiện dần / mờ dần" (tam giác mờ ở 2 đầu) + tay nắm khi clip đang chọn.
            var fin = CGFloat(c.fadeIn), fout = CGFloat(c.fadeOut)
            if let fp = overlayFadePreview, fp.id == c.id { fin = fp.fin; fout = fp.fout }
            if fin > 0.01 || fout > 0.01 || sel {
                NSColor.white.withAlphaComponent(0.18).setFill()
                if fin > 0.01 {
                    let w = min(r.width, fin * pps)
                    let tri = NSBezierPath()
                    tri.move(to: NSPoint(x: r.minX, y: r.maxY))
                    tri.line(to: NSPoint(x: r.minX + w, y: r.minY))
                    tri.line(to: NSPoint(x: r.minX, y: r.minY)); tri.close(); tri.fill()
                }
                if fout > 0.01 {
                    let w = min(r.width, fout * pps)
                    let tri = NSBezierPath()
                    tri.move(to: NSPoint(x: r.maxX, y: r.maxY))
                    tri.line(to: NSPoint(x: r.maxX - w, y: r.minY))
                    tri.line(to: NSPoint(x: r.maxX, y: r.minY)); tri.close(); tri.fill()
                }
                if sel, r.width > 26 {   // tay nắm fade (chấm trắng ở mép trên)
                    NSColor.white.setFill()
                    for hx in [r.minX + fin * pps, r.maxX - fout * pps] {
                        NSBezierPath(ovalIn: CGRect(x: hx - 3, y: r.minY - 1, width: 6, height: 6)).fill()
                    }
                }
            }
            // Tay nắm cắt 2 mép khi clip đang chọn.
            if sel, r.width > 22 {
                NSColor.white.withAlphaComponent(0.95).setStroke()
                for gx in [r.minX + 3.5, r.maxX - 3.5] {
                    let g = NSBezierPath()
                    g.move(to: NSPoint(x: gx, y: r.minY + 3)); g.line(to: NSPoint(x: gx, y: r.maxY - 3))
                    g.lineWidth = 2; g.stroke()
                }
            }
            // Mốc CHUYỂN ĐỘNG (keyframe) — hình thoi trắng dọc theo clip.
            if !c.keyframes.isEmpty {
                for kf in c.keyframes {
                    let kx = r.minX + CGFloat(kf.t) * pps
                    guard kx >= r.minX - 1, kx <= r.maxX + 1 else { continue }
                    let d: CGFloat = 3.5
                    let dia = NSBezierPath()
                    dia.move(to: NSPoint(x: kx, y: r.midY - d))
                    dia.line(to: NSPoint(x: kx + d, y: r.midY))
                    dia.line(to: NSPoint(x: kx, y: r.midY + d))
                    dia.line(to: NSPoint(x: kx - d, y: r.midY))
                    dia.close()
                    NSColor.white.setFill(); dia.fill()
                    NSColor.black.withAlphaComponent(0.45).setStroke(); dia.lineWidth = 0.5; dia.stroke()
                }
            }
        }

        // Dải NHÓM — vạch + tên phía trên làn lớp đè 1.
        for gr in groupBands() {
            let y = overlayAreaTop - 11
            NSColor(calibratedRed: 0.14, green: 0.58, blue: 0.77, alpha: 0.9).setStroke()
            let ln = NSBezierPath()
            ln.move(to: NSPoint(x: gr.x0, y: y + 5)); ln.line(to: NSPoint(x: gr.x1, y: y + 5))
            ln.lineWidth = 2; ln.stroke()
            for hx in [gr.x0, gr.x1] {
                let t = NSBezierPath()
                t.move(to: NSPoint(x: hx, y: y + 2)); t.line(to: NSPoint(x: hx, y: y + 8)); t.lineWidth = 2; t.stroke()
            }
            (gr.name as NSString).draw(at: NSPoint(x: gr.x0 + 4, y: y - 4),
                withAttributes: [.font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                                 .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.95, alpha: 1)])
        }
    }

    /// Khoảng ngang (px) + tên mỗi nhóm dựa trên các clip thành viên đang có.
    private func groupBands() -> [(x0: CGFloat, x1: CGFloat, name: String, id: UUID)] {
        var out: [(CGFloat, CGFloat, String, UUID)] = []
        for g in overlayGroups {
            let mem = overlays.filter { g.memberIDs.contains($0.id) }
            guard mem.count >= 2 else { continue }
            let s = mem.map { CGFloat($0.start) }.min() ?? 0
            let e = mem.map { CGFloat($0.end) }.max() ?? 0
            out.append((s * pps, e * pps, g.name, g.id))
        }
        return out
    }

    private func drawBlock(_ ctx: CGContext, i: Int, dirty: NSRect) {
        guard lines.indices.contains(i), lines[i].start != nil else { return }
        let line = lines[i]
        let rect = blockRect(i)
        guard rect.insetBy(dx: -handleW, dy: 0).intersects(dirty) else { return }

        let recording = (line.end == nil)
        let isSel = selIDs.contains(line.id) || (selIDs.isEmpty && i == selectedIndex)
        let isActive = i == activeLine
        let empty = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recording
        let base: NSColor = empty ? Theme.NS.warning : Theme.accentNS

        let hoverLine = (hoverHit.wordIdx == nil && hoverHit.lineIdx == i)
        // Câu active có chữ: thân "dòng" chỉ là DẢI TRÊN mảnh; chữ vẽ ở dải dưới (có khe).
        let splitRow = isActive && !line.words.isEmpty && !recording
        let barRect = splitRow
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: lineBarH)
            : rect

        let body = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)
        let baseA: CGFloat = isSel ? 0.34 : (recording ? 0.3 : 0.16)
        base.withAlphaComponent(baseA + (hoverLine ? 0.12 : 0)).setFill(); body.fill()
        (isSel ? base : base.withAlphaComponent(0.55)).setStroke()
        body.lineWidth = isSel ? 2 : 1
        if recording { body.setLineDash([5, 3], count: 2, phase: 0) }
        body.stroke()

        let wide = !recording && rect.width >= minWidthForHandles
        if wide {
            let hoverBL = hoverHit == .blockLeft(i), hoverBR = hoverHit == .blockRight(i)
            base.withAlphaComponent(hoverBL ? 1.0 : 0.9).setFill()
            NSBezierPath(rect: CGRect(x: barRect.minX, y: barRect.minY, width: handleW, height: barRect.height)).fill()
            base.withAlphaComponent(hoverBR ? 1.0 : 0.9).setFill()
            NSBezierPath(rect: CGRect(x: barRect.maxX - handleW, y: barRect.minY, width: handleW, height: barRect.height)).fill()
        }

        let inL: CGFloat = wide ? handleW + 3 : 4
        let inner = CGRect(x: barRect.minX + inL, y: barRect.minY + 2,
                           width: max(0, barRect.width - inL - 4), height: max(8, barRect.height - 4))

        if empty {
            (L("＋ chuột phải để dán lời") as NSString).draw(
                at: NSPoint(x: inner.minX, y: inner.midY - 7),
                withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                 .foregroundColor: NSColor.labelColor])
            return
        }

        // Câu active: thanh dòng mảnh → hiện lời mờ để biết đang là câu nào.
        // (Đang sửa cả dòng thì ẩn đi, kẻo chồng với ô nhập.)
        let editingThisLine = editing?.line == i && editing?.word == -1
        if splitRow, inner.width > 24, !editingThisLine {
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail; ps.alignment = .center
            (line.text as NSString).draw(in: inner, withAttributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.65),
                .paragraphStyle: ps])
        }

        var wRemap: ((CGFloat) -> CGFloat)?
        if let pv = previewBlocks[i] {
            let oS = CGFloat(line.start ?? 0), oE = renderEnd(of: line)
            let dS = pv.0 - oS, dE = pv.1 - oE
            if abs(dS - dE) < 0.001 { wRemap = { $0 + dS } }   // dời cả câu → chữ đi theo
        } else if let nb = previewNeighbor, nb.index == i {
            wRemap = nil   // hàng xóm chỉ nhích mép
        }

        if !line.words.isEmpty, inner.width > 20 {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail; para.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: isActive ? 12 : 10),
                .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
            for (wi, word) in line.words.enumerated() {
                guard let wsD = word.start, let weD = word.end else { continue }
                var cs = CGFloat(wsD), ce = CGFloat(weD)
                if let r = wRemap { cs = r(cs); ce = r(ce) }
                if isActive, let pv = wordPreview.first(where: { $0.w == wi }) { cs = pv.s; ce = pv.e }
                if isActive {
                    // Ô chữ vẽ ĐÚNG mốc thật — KHÔNG kẹp vào bề rộng thanh dòng
                    // (kẹp/không-kẹp lúc kéo dòng = "chữ tự dãn ra 1 chút").
                    let cx0 = (cs + lyricOff) * pps, cx1 = (ce + lyricOff) * pps
                    guard cx1 > cx0 - 1 else { continue }
                    let chip = CGRect(x: cx0 + 1, y: rect.minY + wordBandTop,
                                      width: max(2, cx1 - cx0 - 2), height: rect.height - wordBandTop - 4)
                    let p = NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3)
                    let selW = wi == selWord || selWords.contains(wi)
                    let hoverW = (hoverHit.wordIdx.map { $0 == (i, wi) } ?? false)
                    let chipA: CGFloat = wi == editing?.word ? 0.03 : (selW ? 0.42 : 0.20)
                    base.withAlphaComponent(chipA + (hoverW ? 0.14 : 0)).setFill(); p.fill()
                    (selW ? NSColor.white : base.withAlphaComponent(0.9)).setStroke()
                    p.lineWidth = selW ? 2 : 1; p.stroke()
                    if chip.width >= 14 {
                        base.withAlphaComponent(0.85).setFill()
                        NSBezierPath(rect: CGRect(x: chip.minX, y: chip.minY, width: 3, height: chip.height)).fill()
                        NSBezierPath(rect: CGRect(x: chip.maxX - 3, y: chip.minY, width: 3, height: chip.height)).fill()
                    }
                    if wi != editing?.word, chip.width > 8 {
                        (word.text as NSString).draw(with: chip.insetBy(dx: 2, dy: 3),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                    }
                    if isUncertain(line, wi) { drawUncertainMark(chip) }
                } else {
                    let x0 = max(inner.minX, (cs + lyricOff) * pps), x1 = min(inner.maxX, (ce + lyricOff) * pps)
                    guard x1 > x0 - 1 else { continue }
                    if wi > 0, x0 > inner.minX + 1, x0 < inner.maxX - 1 {
                        ctx.setFillColor(base.withAlphaComponent(0.5).cgColor)
                        ctx.fill(CGRect(x: x0, y: rect.minY + 3, width: 1, height: rect.height - 6))
                    }
                    if x1 - x0 > 6, inner.width / CGFloat(line.words.count) >= 14 {
                        (word.text as NSString).draw(
                            with: CGRect(x: x0 + 1, y: inner.minY, width: x1 - x0 - 2, height: inner.height),
                            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                    }
                    if isUncertain(line, wi) {
                        drawUncertainMark(CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height))
                    }
                }
            }
            if !isActive, inner.width / CGFloat(max(1, line.words.count)) < 14 { drawLineText(line.text, in: inner) }
        } else {
            drawLineText(line.text, in: inner)
        }
    }

    private func drawLineText(_ t: String, in r: CGRect) {
        guard r.width > 6 else { return }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        (t as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
    }

    private func waveformImageIfNeeded() -> NSImage? {
        guard !samples.isEmpty else { return nil }
        let width = CGFloat(min(max(samples.count, 800), 8000))
        let key = (samples.count, Int(width))
        if let img = waveformImage, let ex = waveformKey, ex == key { return img }
        let img = NSImage(size: NSSize(width: max(1, width), height: waveHeight))
        img.lockFocusFlipped(true)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.45).cgColor)
            let cols = max(1, min(Int(width), 6000)); let step = width / CGFloat(cols)
            let midY = waveHeight / 2; let n = samples.count
            for c in 0..<cols {
                let idx = min(n - 1, Int(Double(c) / Double(cols) * Double(n)))
                let half = max(0.5, CGFloat(samples[idx]) * (waveHeight / 2 - 1))
                ctx.fill(CGRect(x: CGFloat(c) * step, y: midY - half, width: max(1, step), height: half * 2))
            }
        }
        img.unlockFocus()
        waveformImage = img; waveformKey = key
        return img
    }

    // MARK: Hit-test

    private func hitAt(_ p: NSPoint) -> Hit {
        if p.y >= 0, p.y <= rulerH { return .ruler }
        // Dải clip ★ KARAOKE — tương tác thật do mouseDown/Dragged/Up bắt riêng.
        if inKaraokeStrip(p) { return .none }
        let bottom = laneY(0) + max(selBlockH, CGFloat(maxLanes) * (laneHeight + laneGap))
        if p.y > waveTop, p.y < laneAreaTop { return p.y <= waveTop + waveHeight ? .ruler : .none }
        guard p.y >= laneAreaTop, p.y <= bottom else { return .none }

        // ----- Câu ĐANG active: chia THEO Y — dải trên = DÒNG, dải dưới = CHỮ.
        // Khe trống ở giữa nên KHÔNG bao giờ lẫn. Hit-rect chữ KHÔNG nới rộng → 2 chữ
        // sát nhau chia mép sạch (nửa hở: [cx, cx+cw)).
        if let a = activeLine {
            let r = blockRect(a)
            // (2026-09-24) SỬA "Cmd+click dòng thứ 2 không cộng dồn được": TRƯỚC `dy: 0` — không
            // có chút dung sai chiều dọc nào, bấm lệch vài pixel (rất dễ khi khối dòng mỏng) là
            // trượt hẳn ra `.none`, Cmd+click coi như bấm trượt nên không cộng dồn `selIDs` được.
            // Đồng bộ với dung sai đã nới cho phần CHỮ.
            if r.insetBy(dx: -handleW, dy: -6).contains(p) {
                if p.y <= r.minY + lineBarH {                       // --- thanh DÒNG
                    if lines[a].end != nil, r.width >= minWidthForHandles {
                        if p.x <= r.minX + handleW { return .blockLeft(a) }
                        if p.x >= r.maxX - handleW { return .blockRight(a) }
                    }
                    return .blockBody(a)
                }
                if p.y >= r.minY + wordBandTop, !lines[a].words.isEmpty {   // --- hàng CHỮ
                    for (wi, w) in lines[a].words.enumerated() {
                        guard let ws = w.start, let we = w.end else { continue }
                        let cx = (CGFloat(ws) + lyricOff) * pps, cw = max(3, CGFloat(we - ws) * pps)
                        guard p.x >= cx, p.x < cx + cw else { continue }
                        if cw < 16 { return .wordBody(a, wi) }
                        if p.x < cx + wordHandleW { return .wordLeft(a, wi) }
                        if p.x >= cx + cw - wordHandleW { return .wordRight(a, wi) }
                        return .wordBody(a, wi)
                    }
                }
                return .blockBody(a)                                // khe giữa / khoảng hở → DÒNG
            }
        }
        for i in lines.indices {
            guard lines[i].start != nil, i != activeLine else { continue }
            let r = blockRect(i)
            guard r.insetBy(dx: -handleW, dy: -6).contains(p) else { continue }
            if lines[i].end != nil, r.width >= minWidthForHandles {
                if p.x <= r.minX + handleW { return .blockLeft(i) }
                if p.x >= r.maxX - handleW { return .blockRight(i) }
            }
            return .blockBody(i)
        }
        return .none
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

    override func mouseMoved(with e: NSEvent) {
        guard dstate == nil, overlayDrag == nil, karaokeDrag == nil, !stagingDragging else { return }
        let p = convert(e.locationInWindow, from: nil)
        let h = hitAt(p)
        if h != hoverHit { hoverHit = h; needsDisplay = true }
        cursorFor(p).set()
    }

    override func mouseExited(with e: NSEvent) {
        if hoverHit != .none { hoverHit = .none; needsDisplay = true }
        NSCursor.arrow.set()
    }

    /// M-C — con trỏ theo thứ đang trỏ tới: mép clip = co giãn, thân clip/khối = bàn tay.
    private func cursorFor(_ p: NSPoint) -> NSCursor {
        // Item chờ (dòng / chữ)
        if let sr = stagingRect(.line), sr.insetBy(dx: -6, dy: -8).contains(p) { return .openHand }
        if let sr = stagingRect(.word), sr.insetBy(dx: -6, dy: -8).contains(p) { return .openHand }
        // Clip ★ KARAOKE — chỉ "bàn tay" (kéo ngang cả cụm), không cắt.
        if inKaraokeStrip(p) { return karaokeHasContent ? .openHand : .arrow }
        // Clip lớp đè
        if overlayLaneCount > 0, p.y >= overlayAreaTop - 4 {
            for i in overlays.indices.reversed() {
                let r = overlayRect(i)
                guard r.insetBy(dx: -3, dy: -3).contains(p) else { continue }
                let c = overlays[i]
                if c.id == selOverlayID, r.width > 26, p.y <= r.minY + overlayLaneH * 0.55 {
                    let fiX = r.minX + max(0, CGFloat(c.fadeIn) * pps)
                    let foX = r.maxX - max(0, CGFloat(c.fadeOut) * pps)
                    if abs(p.x - fiX) <= 10 || abs(p.x - foX) <= 10 { return .pointingHand }
                }
                let edge = min(12, r.width * 0.30)
                if r.width > 26, p.x <= r.minX + edge || p.x >= r.maxX - edge {
                    return .resizeLeftRight
                }
                return .openHand
            }
            return .arrow
        }
        switch hitAt(p) {
        case .blockLeft, .blockRight, .wordLeft, .wordRight: return .resizeLeftRight
        case .blockBody, .wordBody:                          return .openHand
        default:                                             return .arrow
        }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        hoverHit = .none
        if holdPreview {          // preview cũ chưa kịp đồng bộ — dọn trước khi thao tác mới
            holdPreview = false
            previewBlocks = [:]; previewNeighbor = nil; wordPreview = []
        }
        let p = convert(e.locationInWindow, from: nil)
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)

        // ----- Bước 1 · Clip ★ KARAOKE (dải dưới "Lời", trên "Lớp đè 1"): KÉO NGANG cả cụm.
        //   Chỉ kéo — không cắt. Không đụng chữ / timing / lớp đè.
        if inKaraokeStrip(p) {
            endEdit(commit: true)
            if karaokeHasContent {
                karaokeDrag = KaraokeDrag(aStart: karaokeClipStart, downX: p.x)
                karaokePreviewStart = karaokeClipStart
                NSCursor.closedHand.set()
                needsDisplay = true
            }
            return
        }

        // ----- CHẾ ĐỘ SONG CA: bấm khối câu → hiện 3 icon phía trên → chọn 1 để gán.
        //   Vẫn cho TUA bằng cách bấm thước / vùng sóng.
        if duetMode {
            if let li = duetPickerLine {
                for (k, r) in duetIconRects(for: li).enumerated() where r.insetBy(dx: -3, dy: -3).contains(p) {
                    onAssignSinger?(li, k < 3 ? SingerRole.allCases[k] : nil)   // ô thứ 4 = XOÁ
                    duetPickerLine = nil; needsDisplay = true; return
                }
            }
            if hitAt(p) == .ruler {                          // thước / sóng → tua như thường
                onSeek?(Double(max(0, p.x / pps)))
                dstate = .scrub; duetPickerLine = nil; needsDisplay = true; return
            }
            var hitLine: Int?
            for i in lines.indices where lines[i].start != nil {
                if blockRect(i).insetBy(dx: -3, dy: -2).contains(p) { hitLine = i; break }
            }
            if let i = hitLine {
                onSelect?(i)
                duetPickerLine = (duetPickerLine == i) ? nil : i
                if e.modifierFlags.contains(.option) { onAssignSinger?(i, nil) }  // ⌥+bấm = bỏ đánh dấu
            } else {
                duetPickerLine = nil
            }
            needsDisplay = true
            return
        }

        // Item CHỜ (staging): double-click = sửa lời · 1 click = bắt đầu KÉO lên track chính.
        // Kiểm tra CẢ 2 (dòng lẫn chữ) — 2 hàng riêng nên không lẫn vào nhau.
        for k: StageKind in [.line, .word] {
            guard let sr = stagingRect(k), sr.insetBy(dx: -6, dy: -8).contains(p) else { continue }
            stagingSelected = k                // bấm vào = "chọn" item này (Delete xoá được)
            if e.clickCount >= 2 { beginEditStaging(k); return }
            endEdit(commit: true)
            let edge = min(14, sr.width * 0.28)
            if sr.width > 40, p.x <= sr.minX + edge { stagingZone = .left }
            else if sr.width > 40, p.x >= sr.maxX - edge { stagingZone = .right }
            else { stagingZone = .move }
            if let st = staging(k) { stagingBaseS = st.s; stagingBaseE = st.e }
            stagingDragging = true
            stagingDragKind = k
            stagingDownP = p
            stagingDragBase = stagingDrag
            needsDisplay = true
            return
        }
        if stagingSelected != nil { stagingSelected = nil; needsDisplay = true }

        // Dải NHÓM (vạch phía trên làn lớp đè) → chọn cả nhóm.
        if overlayLaneCount > 0, p.y >= overlayAreaTop - 14, p.y < overlayAreaTop - 2 {
            for gr in groupBands() where p.x >= gr.x0 - 4 && p.x <= gr.x1 + 4 {
                onSelectGroup?(gr.id); needsDisplay = true; return
            }
        }

        // Dải lớp đè: chọn + kéo dời / kéo mép để cắt.
        if overlayLaneCount > 0, p.y >= overlayAreaTop - 4 {
            for i in overlays.indices.reversed() {
                let r = overlayRect(i)
                guard r.insetBy(dx: -3, dy: -3).contains(p) else { continue }
                let c = overlays[i]

                // ⌘ / Shift + bấm = thêm/bớt khỏi nhóm chọn (không kéo).
                if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.shift) {
                    if selOverlayIDs.isEmpty, let s = selOverlayID { selOverlayIDs = [s] }
                    if selOverlayIDs.contains(c.id) { selOverlayIDs.remove(c.id) }
                    else { selOverlayIDs.insert(c.id) }
                    selOverlayID = selOverlayIDs.contains(c.id) ? c.id : selOverlayIDs.first
                    onOverlaySelectMulti?(selOverlayIDs)
                    onOverlaySelect?(selOverlayID)
                    needsDisplay = true
                    return
                }

                // Bấm thường: nếu clip KHÔNG nằm trong nhóm → chọn 1 mình; nếu đã trong nhóm → giữ nhóm.
                if !selOverlayIDs.contains(c.id) {
                    selOverlayIDs = [c.id]
                    onOverlaySelectMulti?(selOverlayIDs)
                }
                selOverlayID = c.id
                onOverlaySelect?(c.id)
                if e.clickCount >= 2 {          // double-click = mở bảng sửa bên phải, không kéo
                    if c.kind == .text { onEditTextOverlay?(c.id) }
                    needsDisplay = true; return
                }
                // Tay nắm FADE ở nửa TRÊN clip (dấu chấm nơi dốc fade chạm mép trên).
                var zone: OverlayZone = .move
                let topHalf = p.y <= r.minY + overlayLaneH * 0.55
                if c.id == selOverlayID, r.width > 26, topHalf {
                    let fiX = r.minX + max(0, CGFloat(c.fadeIn) * pps)
                    let foX = r.maxX - max(0, CGFloat(c.fadeOut) * pps)
                    if abs(p.x - fiX) <= 10 { zone = .fadeIn }
                    else if abs(p.x - foX) <= 10 { zone = .fadeOut }
                }
                if zone == .move {
                    let edge = min(12, r.width * 0.30)
                    zone = (r.width > 26 && p.x <= r.minX + edge) ? .left
                        : (r.width > 26 && p.x >= r.maxX - edge) ? .right : .move
                }
                overlayDrag = OverlayDrag(id: c.id, zone: zone,
                                          aStart: CGFloat(c.start), aDur: CGFloat(max(0.1, c.duration)),
                                          aLane: c.lane,
                                          aFadeIn: CGFloat(c.fadeIn), aFadeOut: CGFloat(c.fadeOut),
                                          downX: p.x, downY: p.y)
                // Kéo NHÓM (chỉ khi kéo THÂN clip): chốt vị trí gốc mọi clip trong nhóm.
                multiDragBase = [:]
                if zone == .move, selOverlayIDs.count > 1, selOverlayIDs.contains(c.id) {
                    for cc in overlays where selOverlayIDs.contains(cc.id) {
                        multiDragBase[cc.id] = (cc.start, cc.lane)
                    }
                }
                switch zone {
                case .move: NSCursor.closedHand.set()
                case .fadeIn, .fadeOut: NSCursor.pointingHand.set()
                default: NSCursor.resizeLeftRight.set()
                }
                needsDisplay = true
                return
            }
            // Bấm vùng trống trong dải lớp đè → bỏ chọn + tua vạch đỏ tới đó.
            selOverlayID = nil; onOverlaySelect?(nil)
            selOverlayIDs = []; onOverlaySelectMulti?([])
            onSeek?(Double(max(0, p.x / pps)))
            dstate = .scrub
            needsDisplay = true
            return
        }

        // ----- Cmd + bấm/kéo trong hàng CHỮ → CHỌN NHIỀU CHỮ.
        // Cmd+click từng ô = cộng dồn (bật/tắt từng chữ); Cmd+kéo = khoanh vùng, chọn hết
        // chữ nằm trong vùng kéo. KHÔNG đụng tới chọn DÒNG (`selIDs`) hay kéo-dời chữ thường
        // (không giữ Cmd) — 2 thứ đó vẫn y như cũ.
        // (2026-09-24) SỬA LỖI "bấm Cmd lần đầu không ăn, phải bấm lại lần 2": `hitAt` chỉ
        // nhận diện được TỪNG CHỮ của dòng ĐANG ACTIVE — dòng chưa từng bấm qua thì chưa active,
        // nên Cmd+click lần đầu vào 1 chữ của nó chỉ trúng `.blockBody` (chọn cả DÒNG), KHÔNG
        // trúng chữ nào — lần bấm thứ 2 (dòng đã active rồi) mới thật sự chọn được chữ. Giờ tự
        // kích hoạt dòng chứa điểm bấm NGAY trong cùng 1 lần bấm rồi nhận diện lại — khỏi cần
        // bấm 2 lần. (`applyState` cũng đã sửa để KHÔNG xoá `selWords` khi dòng active vừa kích
        // hoạt cục bộ ở đây trùng với dòng SwiftUI xác nhận lại sau đó.)
        if cmd {
            let firstHit = hitAt(p)
            if let (l, w) = firstHit.wordIdx {
                endEdit(commit: true)
                var base = selWords
                // (2026-09-24) SỬA LỖI THẬT SỰ: bấm THƯỜNG (không Cmd) chọn 1 chữ chỉ ghi vào
                // `selWord` (biến "chọn đơn") — KHÔNG ghi vào `selWords` (danh sách nhiều chữ).
                // Nên khi Cmd+click chữ thứ 2, `base = selWords` rỗng, chữ 1 vừa chọn bằng bấm
                // thường bị "quên" mất ngay — đúng triệu chứng user báo "chữ đầu bị mất". Giờ:
                // nếu `selWords` đang rỗng mà đã có 1 chữ "chọn đơn" từ trước → đưa nó vào trước.
                if base.isEmpty, selWord >= 0 { base.insert(selWord) }
                if base.contains(w) { base.remove(w) } else { base.insert(w) }
                selWord = w
                selWords = base
                wordMarqueeLine = l; wordMarqueeAnchor = p; wordMarqueeBase = base; wordMarqueeRect = .zero
                needsDisplay = true
                return
            }
            if let target = firstHit.lineIdx, lines.indices.contains(target) {
                endEdit(commit: true)
                let wasAlreadyActive = target == activeLine
                if wasAlreadyActive {
                    // Click/kéo trong dòng ĐANG active nhưng không trúng chữ nào (khe hở giữa
                    // các chữ) — vẫn cho Cmd+kéo khoanh vùng chọn CHỮ như cũ.
                    var base = selWords
                    if base.isEmpty, selWord >= 0 { base.insert(selWord) }
                    selWords = base
                    wordMarqueeLine = target; wordMarqueeAnchor = p; wordMarqueeBase = base; wordMarqueeRect = .zero
                    needsDisplay = true
                    return
                }
                // (2026-09-24) SỬA LỖI "Cmd+click dòng thứ 2 không cộng dồn được vào nhóm nhiều
                // dòng": trước đây LUÔN `selIDs = [lines[target].id]` (THAY HẲN, xoá sạch các
                // dòng đã chọn trước đó) — đúng khi mục đích là "kích hoạt dòng CHƯA active này
                // để Cmd+click ĐÚNG 1 CHỮ của nó" (nhánh `firstHit.wordIdx` ở trên đã lo việc đó
                // rồi, có `return` riêng), nhưng nhánh NÀY chỉ còn được vào khi click KHÔNG
                // trúng chữ nào — tức user đang Cmd+click vào cả DÒNG (thanh dòng của dòng chưa
                // active) — phải TOGGLE cộng dồn vào `selIDs`, giống hệt cách Cmd+click lớp đè
                // (`selOverlayIDs.insert`/`.remove`), không được thay hẳn mất các dòng đã chọn.
                let id = lines[target].id
                if selIDs.contains(id) {
                    selIDs.remove(id)
                } else {
                    selIDs.insert(id)
                    onSelect?(target)
                }
                selWord = -1; selWords = []
                needsDisplay = true
                return
            }
            // (2026-09-24) SỬA: bấm KHÔNG trúng chữ nào lẫn KHÔNG trúng khối dòng nào (kể cả
            // ngoài `blockRect` — ví dụ điểm bấm lệch cao/thấp hơn hàng chữ vài pixel, rất dễ
            // xảy ra khi kéo chuột thật) — TRƯỚC rơi thẳng xuống khoanh-vùng-chọn-DÒNG cũ bên
            // dưới, khiến Cmd+kéo trông như "không chọn được gì" (chỉ có 1 dòng nên khoanh dòng
            // không thấy khác biệt). Cmd luôn có nghĩa "chọn CHỮ" trong app — còn dòng active thì
            // ưu tiên khoanh vùng chữ của dòng đó, không rơi về khoanh dòng, miễn không phải đang
            // ở thước kẻ/dải sóng phía trên (giữ nguyên hành vi tua ở đó).
            if p.y >= waveTop, let a = activeLine, lines[a].start != nil {
                endEdit(commit: true)
                wordMarqueeLine = a; wordMarqueeAnchor = p; wordMarqueeBase = selWords; wordMarqueeRect = .zero
                needsDisplay = true
                return
            }
        }

        // ----- Bấm+kéo KHÔNG giữ phím gì (không liên quan Cmd), bắt đầu GẦN hàng chữ của dòng
        // đang active nhưng KHÔNG trúng đúng 1 chữ nào → khoanh vùng chọn nhiều chữ. Bấm ĐÚNG
        // vào 1 chữ vẫn kéo-dời chữ đó như cũ (không đụng — nhánh này chỉ khớp khi
        // `hitAt(p).wordIdx == nil`). Bấm vào THANH DÒNG (phía trên hàng chữ) vẫn kéo-dời cả
        // dòng như cũ (chặn cứng bằng `r.minY + lineBarH`, không lấn vào đó).
        // (2026-09-24) SỬA: TRƯỚC bắt buộc `p.y` phải nằm ĐÚNG trong hàng chữ (dy: 0) — lệch
        // vài pixel lúc kéo chuột thật (rất dễ xảy ra, chữ nhỏ) là rơi thẳng về "tua + khoanh
        // DÒNG" cũ, trông như "không chọn được gì". Nới biên độ dung sai + tính từ mép DƯỚI
        // thanh dòng (không phải mép TRÊN hàng chữ) để dễ trúng hơn.
        // (2026-09-24, lần 2) VẪN báo không chọn được — nới RỘNG HẲN dung sai dưới (16→50px,
        // dư nhiều hơn cả chiều cao khối) vì user báo vẫn trật dù đã nới lần 1; đồng thời bỏ hẳn
        // yêu cầu `p.y >= waveTop` riêng (đã bao trong `r` rồi, thừa + có thể trật ở biên trên).
        // Có thêm 1 lưới an toàn giống hệt logic này ở nhánh `case .none:` bên dưới — phòng khi
        // do dữ liệu dòng cụ thể (vd. không có khoảng lặng trước chữ đầu) mà `hitAt` phân loại
        // khác đi khiến nhánh NÀY bị bỏ qua.
        if !cmd, !shift, e.clickCount < 2, selIDs.count <= 1, let a = activeLine, lines[a].start != nil,
           !lines[a].words.isEmpty, hitAt(p).wordIdx == nil {
            let r = blockRect(a)
            if p.y >= r.minY + lineBarH, r.insetBy(dx: -handleW, dy: -50).contains(p) {
                endEdit(commit: true)
                selWord = -1; selWords = []
                wordMarqueeLine = a; wordMarqueeAnchor = p; wordMarqueeBase = []; wordMarqueeRect = .zero
                needsDisplay = true
                return
            }
        }

        let hit = hitAt(p)
        // Bấm ra ngoài mọi clip (thước / vùng sóng / vùng trống) → LUÔN bỏ chọn lớp đè,
        // quay về bảng chỉnh karaoke. Gọi vô điều kiện để không kẹt khi state chưa kịp đồng bộ.
        selOverlayID = nil; selOverlayIDs = []
        onOverlaySelect?(nil); onOverlaySelectMulti?([]); needsDisplay = true

        switch hit {
        case .ruler:
            onSeek?(Double(max(0, p.x / pps))); dstate = .scrub
        case .none:
            // (2026-09-24) LƯỚI AN TOÀN: nhánh khoanh-vùng-chọn-CHỮ phía trên (trước `hit =
            // hitAt(p)`) lẽ ra đã bắt được click gần hàng chữ của dòng đang active — nhưng nếu
            // vì lý do gì đó (dữ liệu dòng cụ thể khiến `hitAt` phân loại khác) mà rơi tới tận
            // đây, THỬ LẠI 1 lần nữa với biên độ RỘNG RÃI trước khi coi là "khoanh DÒNG"/tua —
            // tránh im lặng biến thành khoanh dòng vô hình (kéo trong 1 dòng đang chọn sẵn thì
            // trông như "không có gì xảy ra", đúng triệu chứng user báo).
            if !cmd, !shift, e.clickCount < 2, selIDs.count <= 1, let a = activeLine, lines[a].start != nil, !lines[a].words.isEmpty {
                let r = blockRect(a)
                if p.y >= r.minY + lineBarH - 6, r.insetBy(dx: -40, dy: -60).contains(p) {
                    endEdit(commit: true)
                    selWord = -1; selWords = []
                    wordMarqueeLine = a; wordMarqueeAnchor = p; wordMarqueeBase = []; wordMarqueeRect = .zero
                    needsDisplay = true
                    return
                }
            }
            if !(cmd || shift) { selIDs = []; selWord = -1; selWords = [] }
            // Click vùng trống cũng tua vạch đỏ (như CapCut); kéo thì thành khoanh chọn.
            onSeek?(Double(max(0, p.x / pps)))
            dstate = .marquee(p, p); marqueeRect = .zero; needsDisplay = true
        case .blockBody(let i), .blockLeft(let i), .blockRight(let i):
            let id = lines[i].id
            if cmd || shift {
                if selIDs.contains(id) { selIDs.remove(id) } else { selIDs.insert(id) }
            } else if selIDs.contains(id), selIDs.count > 1 {
                // (2026-09-24) SỬA "giữ chuột kéo nhiều dòng thì mất hết, chỉ còn dòng dưới
                // chuột": bấm THƯỜNG vào 1 dòng ĐANG NẰM TRONG nhóm nhiều dòng đã chọn → GIỮ
                // nguyên nhóm để `promote` kéo dời cả nhóm (y hệt cách nhóm chữ / nhóm lớp đè).
                // Nếu chỉ bấm mà không kéo → `mouseUp` mới thu về đúng 1 dòng này.
                dragKeptLineGroup = id
            } else if selIDs != [id] {
                selIDs = [id]
            }
            selWord = -1; selWords = []        // bấm vào phần DÒNG luôn nhả chữ ra
            if lines.indices.contains(i) { onSelect?(i) }
            endEdit(commit: true)
            if e.clickCount >= 2, case .blockBody = hit {
                beginEditLine(i); dstate = nil; return
            }
            dstate = .pending(hit, p); needsDisplay = true
        case .wordBody(let l, let w), .wordLeft(let l, let w), .wordRight(let l, let w):
            // (2026-09-24) SỬA lần 2 "kéo nhiều dòng vẫn chỉ còn 1 dòng": dòng ACTIVE (vừa
            // Cmd+click cuối) hiện dạng thanh mảnh + hàng ô chữ — gần hết chiều cao là hàng chữ,
            // bấm vào đó rơi vào nhánh CHỮ và `selIDs = [1 dòng]` xoá sạch nhóm. Khi đang chọn
            // NHIỀU dòng và bấm THÂN 1 ô chữ (không phải mép co giãn) của dòng nằm trong nhóm →
            // coi là kéo NHÓM DÒNG (không kéo chữ lẻ), y hệt bấm thanh dòng.
            if selIDs.count > 1, selIDs.contains(lines[l].id), e.clickCount < 2,
               selWords.isEmpty, case .wordBody = hit {
                endEdit(commit: true)
                dragKeptLineGroup = lines[l].id
                selWord = -1; selWords = []
                dstate = .pending(.blockBody(l), p); needsDisplay = true
                return
            }
            selIDs = [lines[l].id]; onSelect?(l)
            endEdit(commit: true)
            if e.clickCount >= 2 { selWord = w; selWords = []; beginEditWord(line: l, word: w); dstate = nil; return }
            // Bấm (không Cmd) vào 1 chữ ĐANG NẰM TRONG nhóm đã chọn → GIỮ nhóm để `promote`
            // biết mà kéo dời cả nhóm. Bấm chữ khác → như cũ, chỉ chọn lại 1 chữ.
            let keepGroup = selWords.contains(w) && selWords.count > 1
            selWord = w
            if !keepGroup { selWords = [] }
            dstate = .pending(hit, p); needsDisplay = true
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)

        // Cmd+kéo trong hàng chữ → khoanh vùng CHỌN NHIỀU CHỮ (xem mouseDown).
        if let a = wordMarqueeLine, let anchor = wordMarqueeAnchor {
            let r = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                           width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
            wordMarqueeRect = r
            if hypot(p.x - anchor.x, p.y - anchor.y) > dragThreshold {
                let rowY = blockRect(a).minY + wordBandTop, rowH = blockRect(a).height - wordBandTop
                var sel = wordMarqueeBase
                for (wi, w) in lines[a].words.enumerated() {
                    guard let ws = w.start, let we = w.end else { continue }
                    let cx = (CGFloat(ws) + lyricOff) * pps, cw = max(3, CGFloat(we - ws) * pps)
                    if CGRect(x: cx, y: rowY, width: cw, height: rowH).intersects(r) { sel.insert(wi) }
                }
                selWords = sel
            }
            needsDisplay = true
            return
        }

        // Bước 1 · Clip ★ KARAOKE — CHỈ kéo ngang: đổi mốc bắt đầu (không âm, hít về 0 / vạch đỏ).
        if var kd = karaokeDrag {
            if abs(p.x - kd.downX) > dragThreshold { kd.moved = true }
            var ns = max(0, kd.aStart + (p.x - kd.downX) / pps)
            snapGuideT = nil
            if !e.modifierFlags.contains(.command) {
                let tol = 7 / pps
                for cand in [CGFloat(0), currentTime] where abs(cand - ns) <= tol {
                    ns = max(0, cand); snapGuideT = cand
                }
            }
            karaokeDrag = kd
            karaokePreviewStart = ns
            readout = (ns, p)
            needsDisplay = true
            return
        }

        if var od = overlayDrag {
            if hypot(p.x - od.downX, p.y - od.downY) > dragThreshold { od.moved = true }
            let dT = (p.x - od.downX) / pps

            // KÉO NHÓM (nhiều clip): dời start + lane theo CÙNG delta, không snap, không cắt.
            if od.zone == .move, !multiDragBase.isEmpty {
                let dLane = Int(((p.y - od.downY) / (overlayLaneH + overlayLaneGap)).rounded())
                var mp: [UUID: (s: Double, lane: Int)] = [:]
                for (id, base) in multiDragBase {
                    mp[id] = (max(0, base.s + Double(dT)),
                              min(max(0, base.lane + dLane), max(0, overlayLaneCount - 1)))
                }
                overlayDrag = od
                overlayMultiPreview = mp
                if let me = mp[od.id] { readout = (CGFloat(me.s), p) }
                needsDisplay = true
                return
            }

            // Kéo tay nắm FADE (không đụng start/dur/lane).
            if od.zone == .fadeIn || od.zone == .fadeOut {
                let maxFade = max(0.01, od.aDur - 0.05)
                var fin = CGFloat(overlays.first { $0.id == od.id }?.fadeIn ?? 0)
                var fout = CGFloat(overlays.first { $0.id == od.id }?.fadeOut ?? 0)
                if od.zone == .fadeIn { fin = min(max(0, od.aFadeIn + dT), maxFade) }
                else                  { fout = min(max(0, od.aFadeOut - dT), maxFade) }
                if fin + fout > od.aDur { if od.zone == .fadeIn { fin = od.aDur - fout } else { fout = od.aDur - fin } }
                overlayDrag = od
                overlayFadePreview = (od.id, max(0, fin), max(0, fout))
                readout = (od.zone == .fadeIn ? fin : fout, p)
                needsDisplay = true
                return
            }

            var s = od.aStart, dur = od.aDur, lane = od.aLane
            switch od.zone {
            case .move:
                s = max(0, od.aStart + dT)
                // Kéo dọc để đổi làn.
                let dy = p.y - overlayLaneY(od.aLane)
                let step = overlayLaneH + overlayLaneGap
                lane = min(max(0, od.aLane + Int((dy / step).rounded())), overlayLaneCount - 1)
            case .left:
                let ns = max(0, min(od.aStart + dT, od.aStart + od.aDur - 0.1))
                dur = od.aStart + od.aDur - ns
                s = ns
            case .right:
                dur = max(0.1, od.aDur + dT)
            case .fadeIn, .fadeOut:
                break   // đã xử ở trên
            }
            // Hít vào mép clip khác / vạch đỏ / t=0 (trừ khi giữ ⌘).
            snapGuideT = nil
            if !e.modifierFlags.contains(.command) {
                let tol = 7 / pps
                var snaps: [CGFloat] = [0, currentTime]
                for c in overlays where c.id != od.id {
                    snaps.append(CGFloat(c.start)); snaps.append(CGFloat(c.end))
                }
                for l in lines {                      // M-F — hít vào biên dòng lời
                    if let s = l.start { snaps.append(CGFloat(s)) }
                    if let en = l.end  { snaps.append(CGFloat(en)) }
                }
                func near(_ v: CGFloat) -> CGFloat? {
                    snaps.filter { abs($0 - v) <= tol }.min(by: { abs($0 - v) < abs($1 - v) })
                }
                switch od.zone {
                case .left:
                    if let t = near(s) { dur += (s - t); s = t; snapGuideT = t }
                case .right:
                    if let t = near(s + dur) { dur = max(0.1, t - s); snapGuideT = t }
                case .move:
                    if let t = near(s) { s = t; snapGuideT = t }
                    else if let t = near(s + dur) { s = t - dur; snapGuideT = t }
                    s = max(0, s)
                case .fadeIn, .fadeOut:
                    break
                }
            }
            overlayDrag = od
            overlayPreview = (od.id, s, dur, lane)
            readout = (s, p)
            needsDisplay = true
            return
        }

        if stagingDragging, let k = stagingDragKind {
            let dtT = (p.x - stagingDownP.x) / pps
            switch stagingZone {
            case .left:
                setStagingRange(k, min(stagingBaseS + dtT, stagingBaseE - 0.15), stagingBaseE)
                stagingDropLine = nil; stagingDropGap = nil; needsDisplay = true; return
            case .right:
                setStagingRange(k, stagingBaseS, max(stagingBaseE + dtT, stagingBaseS + 0.15))
                stagingDropLine = nil; stagingDropGap = nil; needsDisplay = true; return
            case .move:
                stagingDrag = CGSize(width: stagingDragBase.width + (p.x - stagingDownP.x),
                                     height: stagingDragBase.height + (p.y - stagingDownP.y))
            }
            // Chỗ đang nhắm tới (để tô sáng xanh lá) — CHỮ: dòng đang đè lên; DÒNG: khe trống
            // hiện tại (chỉ tính khi đã kéo LÊN gần khu vực hàng lời, không phải lúc còn nằm
            // dưới làn tạm — dùng đúng công thức `overMain` như lúc thả thật ở `resolveStagingDrop`).
            stagingDropLine = nil; stagingDropGap = nil
            if let sr = stagingRect(k) {
                if k == .word {
                    for i in lines.indices where lines[i].start != nil {
                        if blockRect(i).insetBy(dx: -6, dy: -6).contains(CGPoint(x: sr.midX, y: sr.midY)) {
                            stagingDropLine = i; break
                        }
                    }
                } else {
                    let overMain = sr.midY >= laneAreaTop - 12 && sr.midY <= lyricAreaBottom + 8
                    if overMain {
                        let dropT = max(0, sr.midX / pps - lyricOff)
                        stagingDropGap = lineGapAround(dropT)
                    }
                }
            }
            needsDisplay = true
            return
        }

        guard let st = dstate else { return }
        snapOff = e.modifierFlags.contains(.command)

        switch st {
        case .scrub:
            let t = max(0, p.x / pps)
            onSeek?(Double(t)); readout = (t, p); needsDisplay = true; return
        case .marquee(let o, _):
            let r = CGRect(x: min(o.x, p.x), y: min(o.y, p.y),
                           width: abs(p.x - o.x), height: abs(p.y - o.y))
            dstate = .marquee(o, p); marqueeRect = r
            selIDs = Set(lines.indices.filter { lines[$0].start != nil && blockRect($0).intersects(r) }
                .map { lines[$0].id })
            needsDisplay = true; return
        case .pending(let hit, let down):
            guard hypot(p.x - down.x, p.y - down.y) > dragThreshold else { return }
            dstate = promote(hit, downX: down.x)
            updatePreview(p)
        default:
            updatePreview(p)
        }
        needsDisplay = true
    }

    private func promote(_ hit: Hit, downX: CGFloat) -> DState {
        switch hit {
        case .blockLeft(let i), .blockRight(let i):
            let left = { if case .blockLeft = hit { return true } else { return false } }()
            var prev: Int?, next: Int?
            var pS: CGFloat = -1, nS: CGFloat = .greatestFiniteMagnitude
            let s = CGFloat(lines[i].start ?? 0)
            for (j, l) in lines.enumerated() where j != i {
                guard let ss = l.start.map({ CGFloat($0) }), l.end != nil else { continue }
                if ss <= s, ss > pS { pS = ss; prev = j }
                if ss > s, ss < nS { nS = ss; next = j }
            }
            return .blockEdge(idx: i, left: left, aS: s, aE: renderEnd(of: lines[i]),
                              downX: downX, prev: prev, next: next)
        case .blockBody(let i):
            let ids = selIDs.contains(lines[i].id) && selIDs.count > 1 ? selIDs : [lines[i].id]
            let idxs = lines.indices.filter { ids.contains(lines[$0].id) }
            var anchor: [Int: (CGFloat, CGFloat)] = [:]
            for j in idxs { anchor[j] = (CGFloat(lines[j].start ?? 0), renderEnd(of: lines[j])) }
            return .blocks(idx: idxs, anchor: anchor, primary: i, downX: downX)
        case .wordBody(let l, let w):
            // Bấm vào THÂN 1 chữ đang nằm trong nhóm đã chọn (Cmd+click/kéo trước đó, ≥2 chữ)
            // → kéo dời CẢ NHÓM. Bấm chữ ngoài nhóm / chỉ 1 chữ được chọn → như cũ (1 chữ).
            if selWords.contains(w), selWords.count > 1 {
                var anchor: [Int: (CGFloat, CGFloat)] = [:]
                for j in selWords where lines[l].words.indices.contains(j) {
                    let ws = CGFloat(lines[l].words[j].start ?? 0)
                    let we = CGFloat(lines[l].words[j].end ?? ws + 0.1)
                    anchor[j] = (ws, we)
                }
                let idxs = anchor.keys.sorted()
                guard let firstIdx = idxs.first, let lastIdx = idxs.last else {
                    return singleWordPromote(l, w, .move, downX)
                }
                // Hàng xóm NGOÀI 2 đầu cụm — như `singleWordPromote`, dùng để thu ngắn khi đụng.
                let prevS: CGFloat = firstIdx > 0 ? CGFloat(lines[l].words[firstIdx - 1].start ?? 0) : -1
                let prevE: CGFloat = firstIdx > 0
                    ? CGFloat(lines[l].words[firstIdx - 1].end ?? lines[l].words[firstIdx - 1].start ?? 0)
                    : max(0, CGFloat(lines[l].start ?? 0))
                let nextS: CGFloat = lastIdx + 1 < lines[l].words.count
                    ? CGFloat(lines[l].words[lastIdx + 1].start ?? .greatestFiniteMagnitude)
                    : .greatestFiniteMagnitude
                let nextE: CGFloat = lastIdx + 1 < lines[l].words.count
                    ? CGFloat(lines[l].words[lastIdx + 1].end ?? .greatestFiniteMagnitude)
                    : .greatestFiniteMagnitude
                return .wordsGroup(line: l, idxs: idxs, anchor: anchor,
                                   prevS: prevS, prevE: prevE, nextS: nextS, nextE: nextE, downX: downX)
            }
            return singleWordPromote(l, w, .move, downX)
        case .wordLeft(let l, let w):
            return singleWordPromote(l, w, .left, downX)
        case .wordRight(let l, let w):
            return singleWordPromote(l, w, .right, downX)
        default:
            return .scrub
        }
    }

    /// Kéo/co-giãn 1 CHỮ — logic THU NGẮN mép hàng xóm khi đụng (như cũ, tách riêng để
    /// `promote` còn rẽ nhánh sang kéo NHÓM khi bấm vào 1 chữ đang thuộc nhóm đã chọn).
    private func singleWordPromote(_ l: Int, _ w: Int, _ z: WZone, _ downX: CGFloat) -> DState {
        let ws = CGFloat(lines[l].words[w].start ?? 0)
        let we = CGFloat(lines[l].words[w].end ?? ws + 0.1)
        // Mép chữ HÀNG XÓM — kéo đụng thì THU NGẮN nó (end trước / start sau), không dời nó.
        let prevS = w > 0 ? CGFloat(lines[l].words[w - 1].start ?? 0) : -1
        let prevE = w > 0
            ? CGFloat(lines[l].words[w - 1].end ?? lines[l].words[w - 1].start ?? 0)
            : max(0, CGFloat(lines[l].start ?? 0))
        let nextS = w + 1 < lines[l].words.count
            ? CGFloat(lines[l].words[w + 1].start ?? Double(we)) : .greatestFiniteMagnitude
        let nextE = w + 1 < lines[l].words.count
            ? CGFloat(lines[l].words[w + 1].end ?? Double(we)) : .greatestFiniteMagnitude
        return .word(line: l, word: w, zone: z, aS: ws, aE: we,
                     prevS: prevS, prevE: prevE, nextS: nextS, nextE: nextE,
                     hi: duration, downX: downX)
    }

    private func updatePreview(_ p: NSPoint) {
        previewBlocks = [:]; previewNeighbor = nil; wordPreview = []
        snapGuideT = nil; readout = nil
        guard let st = dstate else { return }
        switch st {
        case .blocks(let idxs, let anchor, let primary, let downX):
            let rawD = (p.x - downX) / pps
            var d = rawD
            if let a = anchor[primary] {
                let snapped = snapTime(max(0, a.0 + rawD), exclude: Set(idxs))
                d = snapped - a.0
                readout = (snapped, p)
            }
            for j in idxs {
                guard let a = anchor[j] else { continue }
                let s = max(0, a.0 + d)
                previewBlocks[j] = (s, s + (a.1 - a.0))
            }
        case .blockEdge(let i, let left, let aS, let aE, let downX, let prev, let next):
            let d = (p.x - downX) / pps
            let minDur: CGFloat = 0.08
            var s = aS, en = aE
            let exSet: Set<Int> = [i, prev, next].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
            if left {
                s = snapTime(max(0, aS + d), exclude: exSet)
                s = min(s, aE - minDur)
                readout = (s, p)
                if let pI = prev, let ps = lines[pI].start.map({ CGFloat($0) }),
                   let pe = lines[pI].end.map({ CGFloat($0) }), s < pe {
                    let ns = max(s, ps + minDur); s = ns; previewNeighbor = (pI, ps, ns)
                }
            } else {
                en = snapTime(aE + d, exclude: exSet)
                en = max(aS + minDur, en)
                readout = (en, p)
                if let nI = next, let ns = lines[nI].start.map({ CGFloat($0) }),
                   let ne = lines[nI].end.map({ CGFloat($0) }), en > ns {
                    let ne2 = min(en, ne - minDur); en = ne2; previewNeighbor = (nI, ne2, ne)
                }
            }
            previewBlocks[i] = (s, en)
        case .word(let l, let w, let z, let aS, let aE, let prevS, let prevE, let nextS, let nextE, let hi, let downX):
            _ = l
            let d = (p.x - downX) / pps
            let m: CGFloat = 0.08                       // chữ tối thiểu 0.08s
            let hasPrev = w > 0, hasNext = nextS != .greatestFiniteMagnitude
            var s = aS, en = aE
            var prevPv: (Int, CGFloat, CGFloat)?        // (w-1, start, END mới — thu ngắn)
            var nextPv: (Int, CGFloat, CGFloat)?        // (w+1, START mới — thu ngắn, end)

            switch z {
            case .left:
                var ns = max(0, min(aS + d, en - m))
                if hasPrev, ns < prevE {
                    ns = max(ns, prevS + m)              // chữ trước không nhỏ hơn m
                    prevPv = (w - 1, prevS, ns)          // thu end chữ trước về ns
                }
                s = ns
                readout = (s, p)
            case .right:
                var ne = max(s + m, min(aE + d, hi))
                if hasNext, ne > nextS {
                    ne = min(ne, nextE - m)              // chữ sau không nhỏ hơn m
                    nextPv = (w + 1, ne, nextE)          // đẩy start chữ sau tới ne
                }
                en = ne
                readout = (en, p)
            case .move:
                let dur = aE - aS
                var ns = max(0, aS + d)
                var ne = ns + dur
                if hasPrev, ns < prevE {
                    if ns < prevS + m { ns = prevS + m; ne = ns + dur }
                    prevPv = (w - 1, prevS, ns)
                }
                if hasNext, ne > nextS {
                    if ne > nextE - m { ne = nextE - m; ns = max(hasPrev ? prevS + m : 0, ne - dur) }
                    nextPv = (w + 1, ne, nextE)
                    if hasPrev, ns < prevE { prevPv = (w - 1, prevS, ns) }
                }
                s = ns; en = max(ns + m, ne)
                readout = (s, p)
            }
            wordPreview = [(w, s, en)]
            if let pp = prevPv { wordPreview.append((pp.0, pp.1, pp.2)) }
            if let np = nextPv { wordPreview.append((np.0, np.1, np.2)) }
        case .wordsGroup(_, let idxs, let anchor, let prevS, let prevE, let nextS, let nextE, let downX):
            guard let firstIdx = idxs.first, let lastIdx = idxs.last,
                  let firstA = anchor[firstIdx], let lastA = anchor[lastIdx] else { return }
            let m: CGFloat = 0.08
            let hasPrev = prevS > -0.5      // sentinel prevS = -1 khi không có hàng xóm trước
            let hasNext = nextS != .greatestFiniteMagnitude
            var d = (p.x - downX) / pps
            if firstA.0 + d < 0 { d = -firstA.0 }               // cả nhóm không lùi quá 0
            var prevPv: (Int, CGFloat, CGFloat)?
            var nextPv: (Int, CGFloat, CGFloat)?
            // Đụng hàng xóm TRƯỚC cụm → thu ngắn nó (end trước → về đúng mép đầu cụm mới).
            if hasPrev, firstA.0 + d < prevE {
                let clamped = max(firstA.0 + d, prevS + m)
                d = clamped - firstA.0
                prevPv = (firstIdx - 1, prevS, clamped)
            }
            // Đụng hàng xóm SAU cụm → thu ngắn nó (start sau → về đúng mép cuối cụm mới).
            if hasNext, lastA.1 + d > nextS {
                let clamped = min(lastA.1 + d, nextE - m)
                d = clamped - lastA.1
                nextPv = (lastIdx + 1, clamped, nextE)
                // Vừa co d để né hàng xóm sau có thể làm đụng lại hàng xóm TRƯỚC → xét lại.
                if hasPrev, firstA.0 + d < prevE {
                    let clamped2 = max(firstA.0 + d, prevS + m)
                    d = clamped2 - firstA.0
                    prevPv = (firstIdx - 1, prevS, clamped2)
                }
            }
            readout = (firstA.0 + d, p)
            wordPreview = idxs.compactMap { j -> (w: Int, s: CGFloat, e: CGFloat)? in
                guard let a = anchor[j] else { return nil }
                return (w: j, s: a.0 + d, e: a.1 + d)
            }
            if let pp = prevPv { wordPreview.append((pp.0, pp.1, pp.2)) }
            if let np = nextPv { wordPreview.append((np.0, np.1, np.2)) }
        default: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        if wordMarqueeLine != nil {
            wordMarqueeLine = nil; wordMarqueeAnchor = nil; wordMarqueeBase = []; wordMarqueeRect = nil
            needsDisplay = true
            return
        }
        // Bước 1 · Clip ★ KARAOKE — chốt mốc mới 1 lần (undo qua store.perform ở ContentView).
        if let kd = karaokeDrag {
            karaokeDrag = nil
            readout = nil; snapGuideT = nil
            NSCursor.arrow.set()
            if kd.moved, let ns = karaokePreviewStart, abs(ns - kd.aStart) > 0.001 {
                onKaraokeClipMove?(Double(max(0, ns)))
                // giữ xem-trước tới khi applyState nhận model mới → không giật
            } else {
                karaokePreviewStart = nil
            }
            needsDisplay = true
            return
        }
        if let od = overlayDrag {
            overlayDrag = nil
            readout = nil
            snapGuideT = nil
            NSCursor.arrow.set()
            if od.zone == .fadeIn || od.zone == .fadeOut {
                if let fp = overlayFadePreview {
                    onOverlayFade?(od.id, Double(fp.fin), Double(fp.fout))
                } else { overlayFadePreview = nil }
                needsDisplay = true
                return
            }
            // KÉO NHÓM — chốt vị trí mọi clip trong nhóm.
            if let mp = overlayMultiPreview {
                if od.moved { for (id, v) in mp { onOverlayMove?(id, v.s, v.lane) } }
                else { overlayMultiPreview = nil }
                multiDragBase = [:]
                needsDisplay = true
                return
            }
            multiDragBase = [:]
            if od.moved, let pv = overlayPreview {
                switch od.zone {
                case .move:
                    onOverlayMove?(od.id, Double(pv.start), pv.lane)
                case .left, .right:
                    onOverlayTrim?(od.id, Double(pv.start), Double(pv.dur))
                case .fadeIn, .fadeOut:
                    break
                }
                // giữ preview tới khi model mới về (applyState xoá)
            } else {
                overlayPreview = nil
            }
            needsDisplay = true
            return
        }
        if stagingDragging { resolveStagingDrop(); stagingDropLine = nil; stagingDropGap = nil; return }

        let st = dstate
        dstate = nil
        marqueeRect = nil
        snapOff = false
        var committed = false

        // Bấm (không kéo) vào 1 dòng trong nhóm nhiều dòng → giờ mới thu nhóm về đúng dòng đó.
        if let keep = dragKeptLineGroup {
            dragKeptLineGroup = nil
            if case .pending = st { selIDs = [keep] }
        }

        switch st {
        case .blocks(let idxs, let anchor, _, _):
            var moved = false
            var changes: [(UUID, Double, Double)] = []
            for j in idxs {
                guard let pv = previewBlocks[j], let a = anchor[j] else { continue }
                if abs(pv.0 - a.0) > 0.001 { moved = true }
                changes.append((lines[j].id, Double(pv.0), Double(pv.1)))
            }
            if moved { onMoveLines?(changes); committed = true }

        case .blockEdge(let i, _, let aS, let aE, _, _, _):
            if let pv = previewBlocks[i],
               !(abs(pv.0 - aS) < 0.001 && abs(pv.1 - aE) < 0.001 && previewNeighbor == nil) {
                var ch: [(Int, Double, Double)] = [(i, Double(pv.0), Double(pv.1))]
                if let n = previewNeighbor { ch.append((n.index, Double(n.start), Double(n.end))) }
                onCommit?(ch); committed = true
            }

        case .word(let l, _, _, let aS, let aE, _, _, _, _, _, _):
            if let first = wordPreview.first,
               !(abs(first.s - aS) < 0.001 && abs(first.e - aE) < 0.001) {
                var words = lines[l].words
                for pv in wordPreview where words.indices.contains(pv.w) {
                    words[pv.w].start = Double(min(pv.s, pv.e))
                    words[pv.w].end = Double(max(pv.s, pv.e))
                }
                onWordsCommit?(l, words, joinWords(words)); committed = true
            }

        case .wordsGroup(let l, _, let anchor, _, _, _, _, _):
            var moved = false
            var words = lines[l].words
            for pv in wordPreview where words.indices.contains(pv.w) {
                if let a = anchor[pv.w], abs(a.0 - pv.s) > 0.001 { moved = true }
                words[pv.w].start = Double(min(pv.s, pv.e))
                words[pv.w].end = Double(max(pv.s, pv.e))
            }
            if moved { onWordsCommit?(l, words, joinWords(words)); committed = true }

        default: break
        }

        snapGuideT = nil; readout = nil
        if committed {
            // GIỮ preview: chờ `applyState` nhận model mới rồi mới xoá → không giật.
            holdPreview = true
        } else {
            previewBlocks = [:]; previewNeighbor = nil; wordPreview = []
        }
        needsDisplay = true
    }

    private func joinWords(_ w: [LyricWord]) -> String {
        w.map { $0.text }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
    }

    /// P3 — tách ô chữ `w` của câu `l` tại vạch đỏ: thời gian cắt tại playhead,
    /// text cắt ở khoảng trắng gần nhất (không có thì theo tỉ lệ ký tự).
    private func splitWordAtPlayhead(_ l: Int, _ w: Int) {
        var words = lines[l].words
        guard words.indices.contains(w), let ws = words[w].start, let we = words[w].end else { return }
        let t = min(max(Double(currentTime), ws + 0.05), we - 0.05)
        guard t > ws + 0.001, t < we - 0.001 else { return }
        let chars = Array(words[w].text)
        let frac = (t - ws) / (we - ws)
        var cut = max(1, min(max(1, chars.count - 1), Int((Double(chars.count) * frac).rounded())))
        var bd = Int.max
        for (k, ch) in chars.enumerated() where ch == " " {
            let d = abs(k - cut); if d < bd { bd = d; if d <= 3 { cut = k + 1 } }
        }
        let left = String(chars.prefix(cut)).trimmingCharacters(in: .whitespaces)
        let right = String(chars.dropFirst(cut)).trimmingCharacters(in: .whitespaces)
        let a = LyricWord(text: left.isEmpty ? words[w].text : left, start: ws, end: t)
        let b = LyricWord(text: right, start: t, end: we)
        words.replaceSubrange(w...w, with: [a, b])
        selWord = w; selWords = []
        onWordsCommit?(l, words, joinWords(words))
    }

    /// P3 — gộp ô chữ `w` với ô kế tiếp.
    private func mergeWordWithNext(_ l: Int, _ w: Int) {
        var words = lines[l].words
        guard words.indices.contains(w), words.indices.contains(w + 1) else { return }
        let a = words[w], b = words[w + 1]
        let text = [a.text, b.text]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        words.replaceSubrange(w...(w + 1),
                              with: [LyricWord(text: text, start: a.start ?? b.start, end: b.end ?? a.end)])
        selWord = w; selWords = []
        onWordsCommit?(l, words, joinWords(words))
    }

    // MARK: Bàn phím

    override func keyDown(with e: NSEvent) {
        // Lớp đè đang chọn: ⌘K tách tại vạch đỏ.
        if e.modifierFlags.contains(.command),
           e.charactersIgnoringModifiers?.lowercased() == "k",
           let oid = selOverlayID {
            onOverlaySplit?(oid, Double(currentTime)); return
        }
        if e.modifierFlags.contains(.command), let c = e.charactersIgnoringModifiers?.lowercased() {
            switch c {
            case "c": onCopyLines?(Array(selIDs)); return
            case "x": onCopyLines?(Array(selIDs)); onDeleteLines?(Array(selIDs)); selIDs = []; selWord = -1; selWords = []; return
            case "v": onPasteAtPlayhead?(); return
            case "d": onDuplicateLines?(Array(selIDs)); return
            case "a": selIDs = Set(lines.map(\.id)); selWord = -1; selWords = []; needsDisplay = true; return
            default: break
            }
        }
        // S = tách chữ tại vạch đỏ · M = gộp với chữ kế (khi đang chọn 1 ô chữ)
        if !e.modifierFlags.contains(.command), !e.modifierFlags.contains(.option),
           let c = e.charactersIgnoringModifiers?.lowercased(),
           let l = activeLine, selWord >= 0, lines[l].words.indices.contains(selWord) {
            if c == "s" { splitWordAtPlayhead(l, selWord); return }
            if c == "m" { mergeWordWithNext(l, selWord); return }
        }
        switch e.keyCode {
        case 53:                                                                      // Esc
            if stagingActive { cancelAllStaging(); return }
            selIDs = []; selWord = -1; selWords = []; needsDisplay = true; return
        case 51, 117:                                                                  // Delete
            // Item CHỜ (dòng/chữ chưa kéo lên) đang được chọn → xoá luôn, ưu tiên trước hết
            // (đây chính là thứ user vừa bấm vào — Esc trước đây xoá HẾT, giờ Delete xoá ĐÚNG
            // 1 item đang chọn, không đụng item còn lại nếu có cả 2).
            if let k = stagingSelected, staging(k) != nil {
                cancelStaging(k); return
            }
            if let l = activeLine, !selWords.isEmpty {
                var w = lines[l].words
                let idxs = selWords.filter { w.indices.contains($0) }
                if !idxs.isEmpty {
                    if idxs.count >= w.count {
                        for i in idxs { w[i].text = "" }        // xoá HẾT ô → chỉ xoá chữ, giữ ô + mốc
                    } else {
                        for i in idxs.sorted(by: >) { w.remove(at: i) }   // bỏ ô, để lại khoảng trống
                    }
                    selWord = -1; selWords = []
                    onWordsCommit?(l, w, joinWords(w))
                }
            } else if let l = activeLine, selWord >= 0, lines[l].words.indices.contains(selWord) {
                var w = lines[l].words
                let i = selWord
                if w.count > 1 {
                    w.remove(at: i)                 // chỉ BỎ ô — để lại khoảng trống, KHÔNG kéo hàng xóm dãn ra
                } else {
                    w[i].text = ""                  // câu 1 chữ: chỉ xoá chữ, giữ ô + mốc
                }
                selWord = -1
                onWordsCommit?(l, w, joinWords(w))
            } else if !selIDs.isEmpty {
                onDeleteLines?(Array(selIDs)); selIDs = []
            } else if selOverlayIDs.count > 1 {
                for id in selOverlayIDs { onOverlayDelete?(id) }
                selOverlayIDs = []; selOverlayID = nil
                onOverlaySelectMulti?([]); onOverlaySelect?(nil)
            } else if let oid = selOverlayID {
                onOverlayDelete?(oid); selOverlayID = nil; selOverlayIDs = []
                onOverlaySelect?(nil); onOverlaySelectMulti?([])
            }
            return
        case 123:                                                                      // ←
            onNudgeLines?(Array(selIDs), e.modifierFlags.contains(.shift) ? -0.5 : -0.1); return
        case 124:                                                                      // →
            onNudgeLines?(Array(selIDs), e.modifierFlags.contains(.shift) ? 0.5 : 0.1); return
        default: break
        }
        super.keyDown(with: e)
    }

    // MARK: Sửa chữ inline

    private func beginEditWord(line: Int, word: Int) {
        endEdit(commit: false)
        guard lines.indices.contains(line), lines[line].words.indices.contains(word),
              let ws = lines[line].words[word].start, let we = lines[line].words[word].end else { return }
        let cx = (CGFloat(ws) + lyricOff) * pps
        let cw = max(44, CGFloat(we - ws) * pps)
        let tf = NSTextField(frame: CGRect(x: cx, y: laneY(laneOf[line] ?? 0) + wordBandTop,
                                           width: cw, height: max(14, selBlockH - wordBandTop - 3)))
        tf.stringValue = lines[line].words[word].text
        tf.font = .systemFont(ofSize: 12); tf.alignment = .center
        tf.focusRingType = .none; tf.bezelStyle = .roundedBezel
        tf.delegate = self; tf.target = self; tf.action = #selector(editReturn)
        addSubview(tf); window?.makeFirstResponder(tf)
        editField = tf; editing = (line, word); needsDisplay = true
    }
    // MARK: Track TẠM (staging)

    // (2026-09-23) TRƯỚC phải double-click đúng vào ô cam bé xíu mới ra được ô gõ chữ — user
    // báo "vẫn như cũ, không thấy gì thay đổi" vì bấm "Thêm chữ"/"Thêm dòng" xong không biết
    // phải double-click mới gõ được. Giờ mở LUÔN ô gõ chữ (to, đã sửa ở `beginEditStaging`)
    // ngay khi bấm nút — không cần double-click nữa. Kéo-lên-để-chính-thức + chữ hướng dẫn
    // cạnh item GIỮ NGUYÊN không đổi.
    func beginStageWord(atTime t: CGFloat) {
        endEdit(commit: false)
        let s = max(0, t)
        setStaging(.word, Staging(isLine: false, s: s, e: s + 0.4, text: ""))
        stagingDrag = .zero; stagingDragging = false; stagingDragKind = nil; stagingSelected = .word
        setFrameSize(NSSize(width: contentWidth, height: totalHeight))
        layoutPlayhead()
        needsDisplay = true
        beginEditStaging(.word)
    }

    func beginStageLine(atTime t: CGFloat) {
        endEdit(commit: false)
        let s = max(0, t)
        setStaging(.line, Staging(isLine: true, s: s, e: s + 2.5, words: [], text: ""))
        stagingDrag = .zero; stagingDragging = false; stagingDragKind = nil; stagingSelected = .line
        setFrameSize(NSSize(width: contentWidth, height: totalHeight))
        layoutPlayhead()
        needsDisplay = true
        beginEditStaging(.line)
    }

    /// Bỏ 1 item CHỜ (dòng HOẶC chữ — không đụng cái còn lại).
    private func cancelStaging(_ k: StageKind) {
        setStaging(k, nil)
        if stagingDragKind == k { stagingDragging = false; stagingDrag = .zero; stagingDragKind = nil }
        if stagingSelected == k { stagingSelected = nil }
        stagingDropLine = nil; stagingDropGap = nil
        setFrameSize(NSSize(width: contentWidth, height: totalHeight))
        layoutPlayhead()
        // Item CÒN LẠI (nếu đang gõ dở) có thể vừa đổi hàng do item này biến mất — dời ô
        // nhập theo, không thì nó đứng lơ lửng sai chỗ (bug user báo "ô nhập add text lỗi").
        repositionEditFieldIfNeeded()
        needsDisplay = true
    }

    /// Bỏ HẾT item CHỜ (Esc khi không đang gõ chữ cụ thể nào).
    private func cancelAllStaging() {
        stagingWord = nil; stagingLine = nil
        stagingDrag = .zero; stagingDragging = false; stagingDragKind = nil
        stagingDropLine = nil; stagingDropGap = nil; stagingSelected = nil
        setFrameSize(NSSize(width: contentWidth, height: totalHeight))
        layoutPlayhead()
        needsDisplay = true
    }

    /// Dời khung ô nhập chữ đang mở theo đúng vị trí MỚI của item nó thuộc về — cần gọi lại
    /// sau bất kỳ thay đổi nào có thể làm 2 hàng CHỜ (dòng/chữ) đổi chỗ cho nhau (ví dụ item
    /// kia vừa bị bỏ/thả trong khi item này còn đang gõ dở).
    private func repositionEditFieldIfNeeded() {
        guard let ek = editingStageKind, let tf = editField, let sr = stagingRect(ek) else { return }
        let minW: CGFloat = 220, minH: CGFloat = 26
        tf.frame = CGRect(x: sr.minX - 6, y: sr.midY - minH / 2, width: max(minW, sr.width + 12), height: minH)
    }

    private func beginEditStaging(_ k: StageKind) {
        guard let sr = stagingRect(k) else { return }
        endEdit(commit: false)
        // (2026-09-23) TRƯỚC ô nhập bó KHÍT theo `stagingRect` — item mới tạo mặc định rất ngắn
        // (chữ ~0.4s, dòng ~2.5s) nên ô nhập chỉ rộng ~28-150px, cao ~24px, gõ vào gần như không
        // thấy chữ. Ô nhập giờ rộng/cao TỐI THIỂU cố định (không phụ thuộc độ dài mặc định của
        // item), neo theo mép trái của `stagingRect` — không đổi cách item được ĐẶT/KÉO (`stagingRect`
        // gốc vẫn nguyên, chỉ ô gõ chữ to hơn cho dễ nhìn). Ép nền SÁNG (Aqua) — nền tối/blend
        // với canvas khiến ô gần như vô hình, đúng cái user báo "chồng chữ, không thấy gì".
        let minW: CGFloat = 220, minH: CGFloat = 26
        let frame = CGRect(x: sr.minX - 6, y: sr.midY - minH / 2,
                           width: max(minW, sr.width + 12), height: minH)
        let tf = NSTextField(frame: frame)
        tf.stringValue = staging(k)?.text ?? ""
        tf.font = .systemFont(ofSize: 13, weight: .medium); tf.alignment = .center
        tf.focusRingType = .none; tf.bezelStyle = .roundedBezel
        tf.drawsBackground = true; tf.backgroundColor = .white; tf.textColor = .black
        tf.appearance = NSAppearance(named: .aqua)
        tf.delegate = self; tf.target = self; tf.action = #selector(editReturn)
        addSubview(tf); window?.makeFirstResponder(tf)
        editField = tf; editing = (Int.min, Int.min); editingStageKind = k   // sentinel: đang gõ item staging
        needsDisplay = true   // ẩn câu hướng dẫn ngay (đỡ chồng lên ô nhập)
    }

    /// Chia đều các chữ của `text` vào khoảng [s,e].
    private func evenWords(_ text: String, _ s: CGFloat, _ e: CGFloat) -> [LyricWord] {
        let toks = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !toks.isEmpty else { return [] }
        let dur = Double(e - s) / Double(toks.count)
        return toks.enumerated().map { k, tk in
            LyricWord(text: tk, start: Double(s) + Double(k) * dur, end: Double(s) + Double(k + 1) * dur)
        }
    }

    private func commitStagingText(_ k: StageKind, _ text: String) {
        guard var st = staging(k) else { return }
        st.text = text
        if st.isLine { st.words = evenWords(text, st.s, st.e) }
        setStaging(k, st)
        needsDisplay = true
    }

    /// Kéo dãn item tạm — đổi mép [ns,ne], chữ của dòng tự chia lại đều.
    private func setStagingRange(_ k: StageKind, _ ns: CGFloat, _ ne: CGFloat) {
        guard var st = staging(k) else { return }
        let a = max(0, min(ns, ne - 0.12))
        let b = max(a + 0.12, ne)
        st.s = a; st.e = b
        if st.isLine { st.words = evenWords(st.text, a, b) }
        setStaging(k, st)
        needsDisplay = true
    }

    /// Dựng lại 1 item ở làn tạm (dùng khi ⌘Z sau lúc thả không ưng ý).
    func restage(_ it: TimelineEditor.StageItem) {
        endEdit(commit: false)
        let k: StageKind = it.isLine ? .line : .word
        setStaging(k, Staging(isLine: it.isLine, s: CGFloat(it.start), e: CGFloat(it.end),
                              words: it.words, text: it.text))
        stagingDrag = .zero; stagingDragging = false; stagingDragKind = nil
        stagingDropLine = nil; stagingDropGap = nil
        setFrameSize(NSSize(width: contentWidth, height: totalHeight))
        layoutPlayhead()
        needsDisplay = true
    }

    /// Thả không hợp lệ → giữ item lại ở làn tạm (KHÔNG mất).
    private func bounceStaging() {
        stagingDrag = .zero; stagingDragging = false; stagingDragKind = nil
        stagingDropLine = nil; stagingDropGap = nil
        NSSound.beep()
        needsDisplay = true
    }

    /// Khe trống quanh thời điểm `t` giữa các CÂU đã có (giây). `nil` = `t` bị 1 câu che kín.
    private func lineGapAround(_ t: CGFloat) -> (lo: CGFloat, hi: CGFloat)? {
        var lo: CGFloat = 0
        var hi: CGFloat = max(duration, t + 5)
        for l in lines {
            guard let s = l.start.map({ CGFloat($0) }), let e = l.end.map({ CGFloat($0) }) else { continue }
            if e <= t + 0.05 { lo = max(lo, e) }
            else if s >= t - 0.05 { hi = min(hi, s) }
            else { return nil }
        }
        return (hi - lo) >= 0.45 ? (lo, hi) : nil
    }

    private func resolveStagingDrop() {
        guard let k = stagingDragKind else { stagingDragging = false; return }
        stagingDragging = false
        guard let st = staging(k), let sr = stagingRect(k) else { cancelStaging(k); return }
        let dropX = sr.midX
        let dropT = max(0, dropX / pps - lyricOff)      // giây TRONG BÀI (bỏ mốc clip ★)
        let overMain = sr.midY >= laneAreaTop - 12 && sr.midY <= lyricAreaBottom + 8
        guard overMain else { bounceStaging(); return }

        if !st.isLine {
            let wlen = st.e - st.s
            var li: Int?
            for i in lines.indices where lines[i].start != nil {
                if blockRect(i).insetBy(dx: -6, dy: -8).contains(CGPoint(x: dropX, y: sr.midY)) { li = i; break }
            }
            if li == nil {                                   // thả gần dòng nào theo thời gian
                var best = Double.greatestFiniteMagnitude
                for i in lines.indices {
                    guard let ls = lines[i].start else { continue }
                    let mid = (ls + (lines[i].end ?? ls)) * 0.5
                    let d = abs(mid - Double(dropT))
                    if d < best { best = d; li = i }
                }
            }
            guard let li else { bounceStaging(); return }

            // Khe trống trong dòng tại chỗ thả.
            let ws = lines[li].words
            let at = ws.firstIndex { CGFloat($0.start ?? .greatestFiniteMagnitude) > dropT } ?? ws.count
            let gapL = at > 0 ? CGFloat(ws[at - 1].end ?? ws[at - 1].start ?? 0)
                              : CGFloat(lines[li].start ?? 0)
            let gapR = at < ws.count ? CGFloat(ws[at].start ?? 0)
                                     : CGFloat(lines[li].end ?? (gapL + wlen))
            let free = gapR - gapL
            if free < 0.12 { bounceStaging(); return }        // KHÔNG còn khe → giữ ở làn tạm

            var ns = dropT, ne = dropT + wlen
            if ne - ns > free - 0.02 {                        // bóp cho vừa khe + canh giữa
                let c = (gapL + gapR) / 2, d = free - 0.04
                ns = c - d / 2; ne = c + d / 2
            }
            let wl = ne - ns
            ns = max(gapL + 0.01, min(ns, gapR - wl - 0.01)); ne = ns + wl
            onStageWordDrop?(li, Double(ns), Double(ne), st.text.isEmpty ? "…" : st.text)
            cancelStaging(k)

        } else {
            let dur = st.e - st.s
            guard let (lo, hi) = lineGapAround(dropT) else { bounceStaging(); return }
            let free = hi - lo
            var ns = dropT, ne = dropT + dur
            if ne - ns > free - 0.04 {                        // bóp cho vừa khe + canh giữa
                let c = (lo + hi) / 2, d = free - 0.06
                ns = c - d / 2; ne = c + d / 2
            }
            let dl = ne - ns
            ns = max(lo + 0.02, min(ns, hi - dl - 0.02)); ne = ns + dl
            let scale = Double(dl) / max(0.05, Double(dur))   // co giãn chữ theo tỉ lệ
            let shifted = st.words.map { w -> LyricWord in
                var x = w
                if let a = w.start { x.start = Double(ns) + (a - Double(st.s)) * scale }
                if let b = w.end { x.end = Double(ns) + (b - Double(st.s)) * scale }
                return x
            }
            onStageLineDrop?(Double(ns), Double(ne), shifted, st.text)
            cancelStaging(k)
        }
    }

    /// Double-click phần DÒNG → sửa cả câu, rồi rải vào các ô chữ (giữ mốc).
    private func beginEditLine(_ l: Int) {
        endEdit(commit: false)
        guard lines.indices.contains(l), let s = lines[l].start else { return }
        let e = renderEnd(of: lines[l])
        let x = (CGFloat(s) + lyricOff) * pps
        let wdt = max(160, (e - CGFloat(s)) * pps)
        let tf = NSTextField(frame: CGRect(x: max(2, x), y: laneY(laneOf[l] ?? 0) - 3,
                                           width: min(wdt, 620), height: lineBarH + 10))
        tf.stringValue = lines[l].text
        tf.font = .systemFont(ofSize: 12, weight: .medium); tf.alignment = .center
        tf.focusRingType = .none; tf.bezelStyle = .roundedBezel
        tf.drawsBackground = true
        tf.backgroundColor = .controlBackgroundColor
        tf.delegate = self; tf.target = self; tf.action = #selector(editReturn)
        addSubview(tf); window?.makeFirstResponder(tf)
        editField = tf; editing = (l, -1)               // word == -1 → đang sửa DÒNG
    }

    @objc private func editReturn() { endEdit(commit: true) }
    func controlTextDidEndEditing(_ obj: Notification) { endEdit(commit: true) }

    /// ESC khi đang gõ: bỏ luôn item tạm (nếu đang gõ trên track tạm), hoặc huỷ sửa.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        let wasStagingKind = (editing?.0 == Int.min) ? editingStageKind : nil
        editField?.removeFromSuperview(); editField = nil; editing = nil; editingStageKind = nil
        window?.makeFirstResponder(self)
        if let wasStagingKind { cancelStaging(wasStagingKind) } else { needsDisplay = true }
        return true
    }
    private func endEdit(commit: Bool) {
        guard let tf = editField, let (line, word) = editing else { return }
        let newText = tf.stringValue
        tf.removeFromSuperview(); editField = nil; editing = nil
        let stagingKind = editingStageKind; editingStageKind = nil
        window?.makeFirstResponder(self); needsDisplay = true
        if line == Int.min {                             // đang gõ item staging
            if commit, let k = stagingKind { commitStagingText(k, newText) }
            return
        }
        guard commit, lines.indices.contains(line) else { return }
        if word == -1 {                                  // sửa cả DÒNG → rải vào ô chữ
            onLineTextRemap?(line, newText); return
        }
        guard lines[line].words.indices.contains(word) else { return }
        var w = lines[line].words
        w[word].text = newText
        onWordsCommit?(line, w, joinWords(w))
    }

    // MARK: Chuột phải

    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        for i in lines.indices {
            guard lines[i].start != nil, lines[i].end != nil else { continue }
            guard blockRect(i).insetBy(dx: -3, dy: 0).contains(p) else { continue }
            onSelect?(i)
            selIDs = [lines[i].id]
            if lines[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onPasteLine?(i) }
            else { onAddWordAtPlayhead?(i) }
            return
        }
        onAddLine?(Double(max(0, p.x / pps - lyricOff)))   // giây TRONG BÀI
    }

    // MARK: Thả file từ kho xuống timeline (đúng làn + mốc)

    /// Làn lớp đè tại điểm `p` (toạ độ view). Ngoài dải lớp đè → làn 0.
    private func overlayLaneAtPoint(_ p: NSPoint) -> Int {
        let rel = p.y - overlayAreaTop
        guard rel >= -8 else { return 0 }
        let idx = Int(rel / (overlayLaneH + overlayLaneGap))
        return min(max(0, idx), overlayLaneCount - 1)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onMediaDrop == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onMediaDrop != nil else { return [] }
        let p = convert(sender.draggingLocation, from: nil)
        dropHover = (max(0, p.x / pps), overlayLaneAtPoint(p))
        needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHover = nil; needsDisplay = true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHover = nil; needsDisplay = true
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onMediaDrop,
              let str = sender.draggingPasteboard.string(forType: .string), !str.isEmpty
        else { dropHover = nil; needsDisplay = true; return false }
        let p = convert(sender.draggingLocation, from: nil)
        onMediaDrop(str, Double(max(0, p.x / pps)), overlayLaneAtPoint(p))
        dropHover = nil; needsDisplay = true
        return true
    }

    // MARK: Context menu (chuột phải) — cùng EditorCommand với toolbar / phím / menu bar

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let clickT = Double(max(0, p.x / pps))
        let m = NSMenu()

        // Clip lớp đè?
        if overlayLaneCount > 0, p.y >= overlayAreaTop - 4,
           let i = overlays.indices.reversed().first(where: {
               overlayRect($0).insetBy(dx: -3, dy: -3).contains(p)
           }) {
            let c = overlays[i]
            let id = c.id
            selOverlayID = id; onOverlaySelect?(id); needsDisplay = true
            m.addItem(ClosureMenuItem(L("Đổi tên…")) { [weak self] in
                guard let self else { return }
                let cur = self.overlays.first { $0.id == id }?.name ?? ""
                if let new = TextPrompt.run(title: L("Đổi tên clip"), defaultValue: cur, okTitle: L("Đổi")),
                   !new.isEmpty { self.onOverlayRename?(id, new) }
            })
            // Chuyển cảnh mờ với clip liền trước cùng làn (nếu có, đủ gần).
            if let prev = overlays.filter({ $0.lane == c.lane && $0.id != id && $0.start < c.start })
                .max(by: { $0.start < $1.start }), c.start - prev.end < 3 {
                m.addItem(ClosureMenuItem(L("Chuyển cảnh mờ với clip trước (0,5s)")) { [weak self] in
                    self?.onOverlayTransition?(id, 0.5)
                })
            }
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("Tách tại đây")) { [weak self] in self?.onOverlaySplit?(id, clickT) })
            m.addItem(ClosureMenuItem(L("Nhân đôi")) { [weak self] in self?.run?(.duplicateSelection) })
            m.addItem(ClosureMenuItem(L("Sao chép")) { [weak self] in self?.run?(.copySelection) })
            if canPasteClip {
                m.addItem(ClosureMenuItem(L("Dán thuộc tính vào clip này")) { [weak self] in self?.run?(.pasteClipStyle) })
            }
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("Xoá")) { [weak self] in self?.run?(.deleteSelection) })
            return m
        }

        // Vùng trống dải lớp đè — dán clip đã chép.
        if canPasteClip, overlayLaneCount > 0, p.y >= overlayAreaTop - 4 {
            m.addItem(ClosureMenuItem(L("Dán clip vào vạch đỏ")) { [weak self] in self?.run?(.pasteClip) })
            return m
        }

        // Khối dòng lời?
        for i in lines.indices where lines[i].start != nil {
            guard blockRect(i).insetBy(dx: -3, dy: -2).contains(p) else { continue }
            let id = lines[i].id
            selIDs = [id]; selWord = -1; selWords = []; onSelect?(i); needsDisplay = true
            m.addItem(ClosureMenuItem(L("Nhân đôi dòng")) { [weak self] in self?.onDuplicateLines?([id]) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem(L("Xoá dòng")) { [weak self] in self?.onDeleteLines?([id]) })
            return m
        }
        return nil
    }

    // MARK: Zoom / pan

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            let mx = convert(e.locationInWindow, from: nil).x
            let ox = enclosingScrollView?.contentView.bounds.origin.x ?? 0
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.deltaY
            guard dy != 0 else { return }
            pendingZoomAnchor = (time: max(0, mx / pps), screenX: mx - ox)
            onZoom?(dy > 0 ? 1.12 : (1 / 1.12))
            return
        }
        super.scrollWheel(with: e)
    }

    /// Trackpad: chụm/xoè 2 ngón để zoom timeline (không cần giữ ⌘).
    override func magnify(with e: NSEvent) {
        let m = e.magnification
        guard m != 0 else { return }
        let mx = convert(e.locationInWindow, from: nil).x
        let ox = enclosingScrollView?.contentView.bounds.origin.x ?? 0
        pendingZoomAnchor = (time: max(0, mx / pps), screenX: mx - ox)
        // giữ giá trị trong khoảng an toàn cho từng "nấc" pinch
        let f = max(0.5, min(2.0, 1 + m))
        onZoom?(CGFloat(f))
    }

    override func otherMouseDown(with e: NSEvent) {}
    override func otherMouseDragged(with e: NSEvent) {
        guard e.buttonNumber == 2, let sv = enclosingScrollView else { return }
        var o = sv.contentView.bounds.origin
        o.x = min(max(0, o.x + e.deltaX), max(0, frame.width - sv.contentView.bounds.width))
        sv.contentView.scroll(to: o); sv.reflectScrolledClipView(sv.contentView)
    }

    override func resetCursorRects() {
        for i in lines.indices {
            guard let s = lines[i].start.map({ CGFloat($0) }),
                  let en = lines[i].end.map({ CGFloat($0) }) else { continue }
            let w = max(10, (en - s) * pps)
            guard w >= minWidthForHandles else { continue }
            let split = i == activeLine && !lines[i].words.isEmpty
            let h = split ? lineBarH : (i == activeLine ? selBlockH : laneHeight)
            let y = laneY(laneOf[i] ?? 0)
            let sx = (s + lyricOff) * pps
            addCursorRect(CGRect(x: sx, y: y, width: handleW, height: h), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: sx + w - handleW, y: y, width: handleW, height: h), cursor: .resizeLeftRight)
        }
        if let a = activeLine {
            let y = laneY(laneOf[a] ?? 0) + wordBandTop
            let hh = max(6, selBlockH - wordBandTop)
            for word in lines[a].words {
                guard let ws = word.start, let we = word.end else { continue }
                let cx = (CGFloat(ws) + lyricOff) * pps, cw = max(4, CGFloat(we - ws) * pps)
                addCursorRect(CGRect(x: cx, y: y, width: wordHandleW, height: hh), cursor: .resizeLeftRight)
                addCursorRect(CGRect(x: cx + cw - wordHandleW, y: y, width: wordHandleW, height: hh), cursor: .resizeLeftRight)
            }
        }
    }
}
