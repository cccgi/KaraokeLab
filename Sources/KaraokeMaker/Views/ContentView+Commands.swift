import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

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
}
