import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    var exportTabContent: some View {
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

    var backgroundMediaBlock: some View {
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

    func bgSlider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ onChange: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(L(title)).font(.caption).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
            Text(String(format: "%.2f", value)).font(.caption2).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
    }

    func pickBackground(_ kind: BackgroundMedia.Kind) {
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

    func removeBackgroundMedia() {
        store.perform(L("Bỏ nền hình")) { store.project.backgroundMedia = nil }
        backgroundImage = nil
        bgVideoURL = nil
        if previewBackground == .media { previewBackground = .dark }
    }

    func editBackgroundMedia(_ name: String, _ mutate: @escaping (inout BackgroundMedia) -> Void) {
        guard store.project.backgroundMedia != nil else { return }
        store.edit(L(name)) {
            if var m = store.project.backgroundMedia {
                mutate(&m)
                store.project.backgroundMedia = m
            }
        }
    }

    /// Binding màu cho nền (ảnh hoặc video) — C7.
    var bgColorBinding: Binding<ColorAdjust>? {
        guard store.project.backgroundMedia != nil else { return nil }
        return Binding(
            get: { store.project.backgroundMedia?.colorAdjust ?? ColorAdjust() },
            set: { v in store.edit(L("Chỉnh màu nền")) { store.project.backgroundMedia?.colorAdjust = v } })
    }

    /// Bật/tắt "Hiệu ứng Bass nền" — ĐỘC LẬP với sóng nhạc (bars) có bật hay không, dùng chung
    /// đường phân tích FFT nên phải tự `ensure` phổ khi bật (không còn ăn theo `setVisualizerEnabled`).
    var beatZoomEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.project.backgroundMedia?.beatZoomEnabled ?? false },
            set: { on in
                store.perform(L("Nền zoom theo nhạc")) { store.project.backgroundMedia?.beatZoomEnabled = on }
                if on, let ref = store.project.audio, let url = AudioLoader.resolveURL(from: ref) {
                    SpectrumStore.ensure(for: url)
                }
            })
    }
    var beatZoomAmountBinding: Binding<Double> {
        Binding(
            get: { store.project.backgroundMedia?.beatZoomAmount ?? 1.15 },
            set: { v in store.edit(L("Mức zoom theo nhạc")) { store.project.backgroundMedia?.beatZoomAmount = v } })
    }

    func reloadBackgroundImage() {
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
    static func decodeImage(at url: URL) -> CGImage? {
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
    enum ExportOutput {
        case transparentMOV
        case solidMP4(CGColor)
        case imageMP4
        case videoMP4
        var isTransparent: Bool { if case .transparentMOV = self { return true }; return false }
    }

    var exportOutput: ExportOutput {
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

    var transparentVideoBlock: some View {
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
    var audioForVideoBlock: some View {
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
    var beatSeparationInline: some View {
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

    func runBeatSeparation() {
        guard let src = resolvedAudioURL else { return }
        Task { _ = await beatSep.separateLocal(source: src) }
    }

    /// Độ dài phần KARAOKE (fallback khi chưa có audio) — `TransparentVideoExporter` tự
    /// tính lại cắt + `karaokeClipStart` + lớp đè bên trong.
    var videoExportDuration: TimeInterval {
        if playback.duration > 0 { return playback.duration }
        let lastEnd = store.project.lines.compactMap(\.end).max() ?? 0
        return lastEnd + 2
    }

    /// Độ dài FILE XUẤT thực tế — track kết thúc muộn nhất (clip ★ dời `karaokeClipStart`, lớp đè).
    var videoExportOutputDuration: TimeInterval {
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
}
