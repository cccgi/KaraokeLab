import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    var inspectorColumn: some View {
        VStack(spacing: 0) {
            if case .overlay(let id) = editorSelection {
                overlayInspectorColumn(id)
            } else if musicInspectorOpen {
                musicInspectorColumn
            } else {
                // Không chọn lớp đè / nhạc → 2 tab: Kiểu chữ (như cũ) | Dự án (khung hình, FPS, nhạc).
                PanelHeader(title: inspectorProjectTab ? L("Dự án") : L("Kiểu chữ karaoke"),
                            icon: inspectorProjectTab ? "film" : "textformat") {
                    Picker("", selection: $inspectorProjectTab) {
                        Image(systemName: "textformat").help(L("Kiểu chữ karaoke")).tag(false)
                        Image(systemName: "film").help(L("Dự án")).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if inspectorProjectTab {
                    projectInspectorBody
                } else {
                    StylePanel(currentLineIndex: currentLineIndex, onCommitLineText: commitLyricEdit) {
                        EmptyView()
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    // MARK: - Inspector Nhạc (cách A — nút "Nhạc" ở đầu làn). Dữ liệu có sẵn từ M-D (PlaybackController + xuất
    // video đều đã dùng) — trước đây KHÔNG có chỗ chỉnh. Kéo = `store.edit` (gộp 1 undo), đổi xong
    // `.onChange` ở ContentView tự gọi `syncAudioSettings()` → nghe ngay khi phát.

    /// Độ dài bài (giây) — 0 khi chưa nạp nhạc.
    var songLength: Double { max(0, playback.duration) }

    var musicInspectorColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: L("Nhạc"), icon: "waveform", iconTint: Theme.accent) {
                Button(L("Xong")) { select(.none) }.buttonStyle(.kmSecondarySmall)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if store.project.audio == nil || songLength <= 0.1 {
                        Text(L("Chưa có nhạc. Nhập file nhạc ở tab \"Tạo Karaoke\"."))
                            .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
                    } else {
                        musicInspectorBody
                    }
                }
                .padding(Theme.Space.l)
            }
        }
    }

    @ViewBuilder
    private var musicInspectorBody: some View {
        let p = store.project
        let len = songLength
        let start = min(max(0, p.audioTrimStart), len)
        let end = p.audioTrimEnd > 0.05 ? min(p.audioTrimEnd, len) : len
        let songT = min(len, max(0, playback.currentTime - p.karaokeClipStart))
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "music.note").foregroundStyle(Theme.inkDim)
            Text(p.audio?.fileName ?? "").font(Theme.Typo.label).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(TimeFormatting.clock(len)).font(Theme.Typo.mono).foregroundStyle(Theme.inkFaint)
        }

        KMSliderRow(label: L("Âm lượng"), value: p.audioGain * 100, range: 0...100, defaultValue: 100,
                    format: { "\(Int($0.rounded()))%" }) { v in
            store.edit(L("Âm lượng nhạc")) { store.project.audioGain = v / 100 }
        }
        .disabled(p.audioMuted)
        Button {
            store.perform(p.audioMuted ? L("Bật tiếng nhạc") : L("Tắt tiếng nhạc")) { store.project.audioMuted.toggle() }
        } label: {
            Label(p.audioMuted ? L("Đang tắt tiếng") : L("Tắt tiếng"),
                  systemImage: p.audioMuted ? "speaker.slash.fill" : "speaker.wave.2")
        }
        .buttonStyle(.kmToggle(p.audioMuted))

        Divider().overlay(Theme.stroke)
        Text(L("Cắt bài")).sectionHeaderStyle()
        KMSliderRow(label: L("Bắt đầu"), value: start, range: 0...len, defaultValue: 0, valueWidth: 56,
                    format: { TimeFormatting.clock($0) }) { v in
            store.edit(L("Cắt đầu bài")) { store.project.audioTrimStart = min(max(0, v), max(0, end - 1)) }
        }
        KMSliderRow(label: L("Kết thúc"), value: end, range: 0...len, defaultValue: len, valueWidth: 56,
                    format: { TimeFormatting.clock($0) }) { v in
            store.edit(L("Cắt cuối bài")) {
                let e = max(v, start + 1)
                store.project.audioTrimEnd = e >= len - 0.05 ? 0 : e      // 0 = tới hết bài (như model quy ước)
            }
        }
        HStack(spacing: Theme.Space.s) {
            Button(L("Đầu = vạch đỏ")) {
                store.perform(L("Cắt đầu bài")) { store.project.audioTrimStart = min(songT, max(0, end - 1)) }
            }
            .help(L("Bắt đầu phát / xuất từ vị trí vạch đỏ"))
            Button(L("Cuối = vạch đỏ")) {
                store.perform(L("Cắt cuối bài")) {
                    let e = max(songT, start + 1)
                    store.project.audioTrimEnd = e >= len - 0.05 ? 0 : e
                }
            }
            .help(L("Dừng phát / xuất ở vị trí vạch đỏ"))
            Spacer(minLength: 0)
            if start > 0.05 || end < len - 0.05 {
                Button { store.perform(L("Bỏ cắt bài")) { store.project.audioTrimStart = 0; store.project.audioTrimEnd = 0 } }
                    label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.kmIcon).help(L("Bỏ cắt — phát cả bài"))
            }
        }
        .buttonStyle(.kmSecondarySmall)
        Text(String(format: L("Phát / xuất %@ → %@ (dài %@). Lời giữ nguyên vị trí."),
                    TimeFormatting.clock(start), TimeFormatting.clock(end), TimeFormatting.clock(max(0, end - start))))
            .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)

        Divider().overlay(Theme.stroke)
        Text(L("Fade")).sectionHeaderStyle()
        let maxFade = max(0.1, min(10, (end - start) / 2))
        KMSliderRow(label: L("Fade vào"), value: min(p.audioFadeIn, maxFade), range: 0...maxFade, defaultValue: 0,
                    format: { String(format: "%.1fs", $0) }) { v in
            store.edit(L("Fade vào nhạc")) { store.project.audioFadeIn = v }
        }
        KMSliderRow(label: L("Fade ra"), value: min(p.audioFadeOut, maxFade), range: 0...maxFade, defaultValue: 0,
                    format: { String(format: "%.1fs", $0) }) { v in
            store.edit(L("Fade ra nhạc")) { store.project.audioFadeOut = v }
        }
        Text(L("Fade nghe được trong video xuất (lúc xem thử trong app chưa có)."))
            .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Inspector "Dự án" (tab khi không chọn lớp đè / nhạc)

    var projectInspectorBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(L("Khung video")).sectionHeaderStyle()
                frameSettingsControls
                Text(L("Dùng chung với bảng Xuất."))
                    .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)

                Divider().overlay(Theme.stroke)
                Text(L("Nhạc")).sectionHeaderStyle()
                if store.project.audio != nil, songLength > 0.1 {
                    let p = store.project
                    let end = p.audioTrimEnd > 0.05 ? min(p.audioTrimEnd, songLength) : songLength
                    Text(String(format: L("%@ · âm lượng %d%%%@"), TimeFormatting.clock(max(0, end - p.audioTrimStart)),
                                Int((p.audioGain * 100).rounded()), p.audioMuted ? " · " + L("tắt tiếng") : ""))
                        .font(Theme.Typo.label).foregroundStyle(Theme.inkDim)
                    Button { select(.music) } label: { Label(L("Chỉnh nhạc…"), systemImage: "slider.horizontal.3") }
                        .buttonStyle(.kmSecondarySmall)
                } else {
                    Text(L("Chưa có nhạc.")).font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
                }

                Divider().overlay(Theme.stroke)
                Text(L("Lời")).sectionHeaderStyle()
                let timed = store.project.lines.filter(\.isTimed).count
                Text(String(format: L("%d dòng · %d dòng đã canh giờ"), store.project.lines.count, timed))
                    .font(Theme.Typo.label).foregroundStyle(Theme.inkDim)
            }
            .padding(Theme.Space.l)
        }
    }

    @ViewBuilder
    func overlayInspectorColumn(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: store.project.overlays.first(where: { $0.id == id })?.name ?? L("Lớp đè"),
                        icon: "square.2.layers.3d.top.filled", iconTint: Theme.accent) {
                Button {
                    let cur = store.project.overlays.first(where: { $0.id == id })?.name ?? ""
                    if let new = TextPrompt.run(title: L("Đổi tên clip"), defaultValue: cur, okTitle: L("Đổi")) {
                        timelineOverlayRename(id, new)
                    }
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.kmIcon).help(L("Đổi tên clip"))
                Button(L("Xong")) { selectedOverlayID = nil }.buttonStyle(.kmSecondarySmall)
            }
            if selectedOverlayIDs.count > 1 {
                let asGroup = store.project.overlayGroups.first { Set($0.memberIDs) == selectedOverlayIDs }
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L("%d lớp đang chọn"), selectedOverlayIDs.count))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(L("Kéo bất kỳ clip nào để dời cả nhóm · ⌫ để xoá cả nhóm · ⌘/Shift+bấm để thêm/bớt."))
                        .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if let g = asGroup {
                            Text(String(format: L("Nhóm: %@"), g.name)).font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            Button(L("Đổi tên")) { renameGroup(g.id) }.controlSize(.small)
                            Button(L("Bỏ nhóm")) { ungroup(g.id) }.controlSize(.small)
                        } else {
                            Button { makeGroupFromSelection() } label: { Label(L("Gom thành nhóm"), systemImage: "square.stack.3d.up") }
                                .buttonStyle(.kmPrimary)
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
                                Text(String(format: L("(%d lớp)"), g.memberIDs.count)).font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
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
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Color.white.opacity(0.04)))
                        Divider()
                    }
                    overlayInspectorInline(id)

                    Divider()
                    Button(role: .destructive) { removeOverlay(id) } label: {
                        Label(L("Xoá lớp này"), systemImage: "trash")
                    }
                }
                .padding(Theme.Space.l)
            }
            }
        }
    }


    var resolvedAudioURL: URL? {
        playback.loadedURL ?? store.project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
    }


    func timeFieldRow(_ title: String, value: TimeInterval?, isStart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.Typo.label)
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
}
