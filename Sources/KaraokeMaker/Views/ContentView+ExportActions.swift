import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    func exportSRT() {
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

    func exportASS() {
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

    func exportTransparentVideo() {
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
    func exportVisualizerOnly() {
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
