import SwiftUI
import AppKit

/// Màn "Đang xuất" trong bảng Xuất (kiểu CapCut, chủ dự án 2026-09-30): ảnh xem trước dự án + thông tin video +
/// tiến độ bằng % (KHÔNG hiện "123/6754 khung"). Bấm "Xuất video…" → chọn chỗ lưu → bảng chuyển sang màn này.
extension ContentView {

    /// Thông số của lần xuất đang chạy — chốt lúc bấm xuất (đổi cài đặt sau đó không làm sai bảng).
    struct ExportJobInfo: Equatable {
        var url: URL
        var width: Int
        var height: Int
        var fps: Int
        var duration: TimeInterval
        var proRes: Bool
        var backgroundLabel: String
        var audioLabel: String
        var hasAudio: Bool
        /// false = xuất riêng sóng nhạc → không vẽ ảnh dự án (sẽ sai), hiện icon.
        var hasPreview = true
        var startedAt = Date()

        var name: String { url.deletingPathExtension().lastPathComponent }
        var format: String { url.pathExtension.lowercased() }
        var codec: String { proRes ? "ProRes 4444" : "H.264" }

        var resolutionText: String {
            let preset = VideoResolution.Aspect.allCases.lazy
                .flatMap { $0.sizes }.first { $0.width == width && $0.height == height }?.name
            let base = "\(width) × \(height)"
            return preset.map { $0.contains("×") ? base : "\(base) (\($0))" } ?? base
        }

        /// Ước tính theo đúng thông số bộ ghi dùng (`VideoFrameWriter`): H.264 = bitrate trung bình
        /// min(80, max(3, W·H·fps·0,2)) Mbps; ProRes 4444 ≈ 330 Mbps ở 1080p30 (tỉ lệ theo số điểm ảnh/giây).
        /// + âm thanh ~256 kbps. Trong lúc xuất, bảng thay bằng số ngoại suy từ file đang ghi (chính xác hơn).
        var estimatedBytes: Double {
            let pixelsPerSec = Double(width * height * fps)
            let videoBps = proRes
                ? 330_000_000 * pixelsPerSec / (1920 * 1080 * 30)
                : Double(min(80_000_000, max(3_000_000, Int(pixelsPerSec * 0.20))))
            let audioBps = hasAudio ? 256_000.0 : 0
            return (videoBps + audioBps) * duration / 8
        }
    }

    /// Bắt đầu màn "Đang xuất" + vẽ ảnh xem trước (luồng nền, đúng tỉ lệ khung).
    func beginExportJob(_ job: ExportJobInfo, useMedia: Bool) {
        exportJob = job
        exportPreviewImage = nil
        guard job.hasPreview else { return }
        let project = store.project
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = ThumbnailRenderer.exportPreview(for: project, useMedia: useMedia)
            DispatchQueue.main.async {
                guard exportJob?.url == job.url, let cg else { return }
                exportPreviewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    /// Rời màn "Đang xuất" (xong / lỗi / huỷ) → về lại cài đặt xuất.
    func endExportJobView() {
        exportJob = nil
        exportPreviewImage = nil
    }

    private enum ExportOutcome { case running, done, failed, cancelled }

    private var exportOutcome: ExportOutcome {
        if videoExporter.isExporting { return .running }
        if videoExporter.lastError != nil { return .failed }
        if videoExporter.lastOutputURL != nil { return .done }
        return .cancelled
    }

    func exportProgressPanel(_ job: ExportJobInfo) -> some View {
        let outcome = exportOutcome
        let pct = outcome == .done ? 1 : videoExporter.progress
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                exportPreviewThumb(job)
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    Text(exportTitle(outcome)).font(Theme.Typo.sheetTitle).foregroundStyle(Theme.ink)
                    Grid(alignment: .leading, horizontalSpacing: Theme.Space.l, verticalSpacing: Theme.Space.s) {
                        infoRow(L("Tên video"), job.name)
                        infoRow(L("Thời lượng"), durationText(job.duration))
                        GridRow {
                            Text(L("Dung lượng")).foregroundStyle(Theme.inkDim)
                            // 1 Hz, chỉ ô này vẽ lại (đọc cỡ file đang ghi để ngoại suy).
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(sizeText(job, outcome: outcome)).foregroundStyle(Theme.ink)
                            }
                        }
                        infoRow(L("Độ phân giải"), job.resolutionText)
                        infoRow("Codec", job.codec)
                        infoRow(L("Định dạng"), job.format)
                        infoRow(L("Tốc độ khung"), "\(job.fps) fps")
                        infoRow(L("Nền"), job.backgroundLabel)
                        infoRow(L("Âm thanh"), job.audioLabel)
                    }
                    .font(Theme.Typo.label)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Space.xl)

            Spacer(minLength: 0)
            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    Text(String(format: "%.1f%%", pct * 100))
                        .font(Theme.Typo.mono).foregroundStyle(Theme.ink)
                        .frame(width: 52, alignment: .leading)
                    KMProgressBar(value: pct,
                                  tint: outcome == .done ? Theme.success : (outcome == .failed ? Theme.error : Theme.accent))
                }
                HStack(spacing: Theme.Space.m) {
                    exportStatusLine(job, outcome: outcome)
                    Spacer(minLength: Theme.Space.s)
                    switch outcome {
                    case .running:
                        Button(L("Huỷ")) { videoExporter.cancel() }.buttonStyle(.kmSecondary)
                    case .done:
                        Button(L("Mở thư mục")) {
                            if let out = videoExporter.lastOutputURL { NSWorkspace.shared.activateFileViewerSelecting([out]) }
                        }
                        .buttonStyle(.kmSecondary)
                        Button(L("Xong")) { endExportJobView(); showExportSheet = false }
                            .buttonStyle(.kmPrimary)
                    case .failed, .cancelled:
                        Button(L("Quay lại")) { endExportJobView() }.buttonStyle(.kmSecondary)
                    }
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundStyle(Theme.inkDim)
            Text(value).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func exportPreviewThumb(_ job: ExportJobInfo) -> some View {
        let ratio = CGFloat(job.width) / CGFloat(max(1, job.height))
        let box: CGFloat = 200
        let w = ratio >= 1 ? box : box * ratio
        let h = ratio >= 1 ? box / ratio : box
        ZStack {
            Rectangle().fill(Color.black)
            if let img = exportPreviewImage {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else if !job.hasPreview {
                Image(systemName: "waveform").font(.system(size: 28)).foregroundStyle(Theme.inkFaint)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: w, height: h)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.stroke))
    }

    private func exportTitle(_ o: ExportOutcome) -> String {
        switch o {
        case .running: return L("Đang xuất")
        case .done: return L("Xuất xong")
        case .failed: return L("Xuất lỗi")
        case .cancelled: return L("Đã huỷ xuất")
        }
    }

    /// Dòng trạng thái dưới thanh %: chặng · đã chạy · còn lại (ước tính theo tốc độ thật).
    @ViewBuilder
    private func exportStatusLine(_ job: ExportJobInfo, outcome: ExportOutcome) -> some View {
        switch outcome {
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(runningStatus(job, now: ctx.date))
                    .font(Theme.Typo.helper).foregroundStyle(Theme.inkDim)
            }
        case .done:
            Label(String(format: L("Đã lưu: %@"), videoExporter.lastOutputURL?.lastPathComponent ?? job.name),
                  systemImage: "checkmark.circle.fill")
                .font(Theme.Typo.helper).foregroundStyle(Theme.success).lineLimit(1).truncationMode(.middle)
        case .failed:
            Label(videoExporter.lastError ?? L("Xuất lỗi"), systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typo.helper).foregroundStyle(Theme.error).lineLimit(2)
        case .cancelled:
            Text(L("Đã huỷ — file dở đã được xoá.")).font(Theme.Typo.helper).foregroundStyle(Theme.inkDim)
        }
    }

    private func runningStatus(_ job: ExportJobInfo, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(job.startedAt))
        let p = videoExporter.progress
        var parts = [phaseText, String(format: L("đã chạy %@"), mmss(elapsed))]
        if videoExporter.phase == .frames, p > 0.03 {
            parts.append(String(format: L("còn khoảng %@"), mmss(elapsed / p * (1 - p))))
        }
        return parts.joined(separator: " · ")
    }

    private var phaseText: String {
        switch videoExporter.phase {
        case .preparing: return L("Đang chuẩn bị…")
        case .frames: return L("Đang xuất video…")
        case .finishing: return L("Đang hoàn tất file…")
        case .audio: return L("Đang ghép âm thanh…")
        }
    }

    /// Xong → cỡ file THẬT. Đang ghi → ngoại suy từ file tạm (video chưa ghép tiếng) theo % đã xong; ghi xong hình
    /// (đang hoàn tất / ghép tiếng) → cỡ file hình + tiếng ước tính. Chưa có số liệu → "tối đa ~" (công thức theo bitrate
    /// là TRẦN: nền tĩnh / đen nén nhỏ hơn nhiều — đo thật: 10 s 1080p nền đen 650 KB so với trần 15,9 MB).
    private func sizeText(_ job: ExportJobInfo, outcome: ExportOutcome) -> String {
        if outcome == .done, let out = videoExporter.lastOutputURL, let b = fileBytes(out) {
            return byteText(b)
        }
        if outcome == .running {
            let p = videoExporter.progress
            let noAudio = job.url.deletingPathExtension().appendingPathExtension("noaudio." + job.url.pathExtension)
            let audio = job.hasAudio ? 256_000.0 * job.duration / 8 : 0
            if let b = fileBytes(noAudio) ?? fileBytes(job.url), b > 0 {
                switch videoExporter.phase {
                case .frames where p > 0.05:
                    return "~" + byteText(b / p + audio) + " " + L("(ước tính)")
                case .finishing, .audio:
                    return "~" + byteText(b + audio) + " " + L("(ước tính)")
                default: break
                }
            }
        }
        return String(format: L("tối đa ~%@"), byteText(job.estimatedBytes))
    }

    private func fileBytes(_ url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue
    }

    private func byteText(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    private func durationText(_ d: TimeInterval) -> String {
        let s = Int(d.rounded())
        return s >= 60 ? String(format: L("%d phút %d giây"), s / 60, s % 60) : String(format: L("%d giây"), s)
    }

    private func mmss(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
