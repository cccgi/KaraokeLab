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
    func overlayInspectorColumn(_ id: UUID) -> some View {
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


    var resolvedAudioURL: URL? {
        playback.loadedURL ?? store.project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
    }


    func timeFieldRow(_ title: String, value: TimeInterval?, isStart: Bool) -> some View {
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
}
