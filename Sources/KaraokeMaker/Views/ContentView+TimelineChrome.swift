import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    var projectAudioURL: URL? {
        store.project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
    }

    var transportBar: some View {
        TransportBar(
            onSeek: seekTo,
            karaokeOn: karaokeOn,
            karaokeAvailable: beatSepProxy.beatURL != nil && projectAudioURL != nil,
            onKaraoke: toggleKaraoke
        )
    }

    /// Bật/tắt karaoke: đổi nguồn phát giữa bài gốc và beat (giữ nguyên vị trí).
    func toggleKaraoke() {
        let want = !karaokeOn
        guard let target = want ? beatSepProxy.beatURL : projectAudioURL else { return }
        karaokeOn = want
        playback.swapSource(to: target)
    }

    // MARK: - Thanh thao tác dòng / chữ (dưới preview)

    var syncBar: some View {
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
    var duetBar: some View {
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

    func clearAllSingers() {
        store.perform(L("Bỏ đánh dấu người hát cả bài")) {
            for i in store.project.lines.indices { store.project.lines[i].singer = nil }
        }
    }

    func roleColor(_ role: SingerRole) -> Color {
        (store.project.singerColors[role.rawValue] ?? SingerRole.defaultColor(role)).color
    }

    func assignSingerTimeline(_ lineIndex: Int, _ role: SingerRole?) {
        guard store.project.lines.indices.contains(lineIndex) else { return }
        store.perform(role == nil ? L("Bỏ đánh dấu người hát") : L("Đánh dấu \(role!.label)")) {
            store.project.lines[lineIndex].singer = role
        }
    }

    /// Cho 1 dòng hiện sớm hơn `a` giây (tăng "giờ chờ"). KHÔNG đụng timing chữ của
    /// chính nó. Nếu đè vào câu trước thì THU câu trước lại (end + chữ cuối) chứ không chồng.
    func applyLeadWait(_ lines: inout [LyricLine], _ i: Int, _ a: Double) {
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

    func addLeadWait(toLine i: Int, by a: Double) {
        guard store.project.lines.indices.contains(i) else { return }
        store.perform(L("Thêm giờ chờ (dòng này)")) {
            applyLeadWait(&store.project.lines, i, a)
        }
    }

    func addLeadWaitAll(by a: Double) {
        guard !store.project.lines.isEmpty else { return }
        store.perform(L("Thêm giờ chờ (cả bài)")) {
            for i in store.project.lines.indices { applyLeadWait(&store.project.lines, i, a) }
        }
    }

    func lineHasWords(_ i: Int) -> Bool {
        store.project.lines.indices.contains(i) && !store.project.lines[i].words.isEmpty
    }

    // MARK: - Timeline (dưới)

    var timelineArea: some View {
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
}
