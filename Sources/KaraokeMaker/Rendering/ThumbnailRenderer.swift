import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// (U2) Render 1 khung xem trước cho 1 project → lưu PNG cho lưới ở Home.
/// Dùng lại ĐÚNG pipeline vẽ của Preview (`Compositor` + `KaraokeRenderer` +
/// `VisualizerRenderer`) để thumbnail GIỐNG hệt màn hình xem trước, dễ phân biệt project.
enum ThumbnailRenderer {
    static let size = CGSize(width: 640, height: 360)   // 16:9

    /// Vẽ + lưu thumbnail cho project vừa lưu ở `projectURL`. Lỗi → bỏ qua êm,
    /// không được phép làm hỏng việc LƯU PROJECT (đây chỉ là tiện ích phụ).
    /// - Parameter atTime: mốc vạch đỏ user đang xem; ≤0 → tự chọn mốc đại diện.
    static func generate(for project: KaraokeProject, projectURL: URL, atTime: TimeInterval = 0) {
        let canvas = size
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let cg = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        let dur = project.audio?.duration ?? 0
        let t = representativeTime(project, atTime: atTime, duration: dur)

        // Nền: ảnh → nạp ảnh; video → trích 1 khung tại `t`; không có → nền tối.
        let media = project.backgroundMedia
        var bgImage: CGImage?
        if media?.kind == .image {
            bgImage = loadImage(media?.resolveURL())
        } else if media?.kind == .video, let vurl = media?.resolveURL() {
            bgImage = videoFrame(vurl, at: t)
        }
        let bgKind: PreviewBackground = bgImage != nil ? .media : .dark

        // `cg` là CGBitmapContext THÔ (KHÔNG phải view isFlipped) → hệ toạ độ gốc là y-UP.
        // Vẽ nền TRƯỚC với flipped:false (như TransparentVideoExporter), rồi lật CTM thật
        // sang y-DOWN mới vẽ tiếp lớp đè + chữ karaoke với flipped:true. Thiếu bước lật này
        // là lý do ảnh xem trước ở Home bị NGƯỢC.
        Compositor.draw(
            Compositor.previewBackgroundLayers(
                project: project, background: bgKind,
                backgroundImage: bgImage, suppressMediaFill: false,
                time: t, duration: dur),
            in: cg, canvasSize: canvas, flipped: false)

        cg.translateBy(x: 0, y: canvas.height)
        cg.scaleBy(x: 1, y: -1)

        drawVisualizer(cg, project: project, t: t, canvas: canvas, above: false)

        Compositor.draw(Compositor.overlayLayers(project: project, time: t, zone: .belowText),
                        in: cg, canvasSize: canvas, flipped: true)

        // `drawExport` (không phải `drawPreview`) — thuần CGContext, an toàn khi CHẠY NỀN
        // (hàm này được gọi từ `DispatchQueue.global`, không có `NSGraphicsContext` hiện hành).
        let plan = KaraokeRenderer.PreviewPlan()
        KaraokeRenderer.drawExport(in: cg, canvasSize: canvas, project: project, time: t, plan: plan)

        Compositor.draw(Compositor.overlayLayers(project: project, time: t, zone: .aboveText),
                        in: cg, canvasSize: canvas, flipped: true)

        drawVisualizer(cg, project: project, t: t, canvas: canvas, above: true)

        guard let image = cg.makeImage() else { return }
        savePNG(image, to: ProjectLibrary.thumbnailURL(for: projectURL))
    }

    /// Mốc thời gian cho thumbnail: ưu tiên vạch đỏ user để lại; nếu không thì
    /// giữa câu hát ĐẦU TIÊN CÓ CHỮ (để lộ lời bài — mỗi project nhìn khác nhau);
    /// cuối cùng là 1/4 bài.
    private static func representativeTime(_ p: KaraokeProject, atTime: TimeInterval,
                                          duration: TimeInterval) -> TimeInterval {
        if atTime.isFinite, atTime > 0.05 { return atTime }
        if let l = p.lines.first(where: {
            $0.start != nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), let s = l.start {
            let e = l.end ?? (s + 2)
            return s + (e - s) * 0.55
        }
        return duration > 1 ? duration * 0.25 : 0
    }

    private static func drawVisualizer(_ cg: CGContext, project: KaraokeProject,
                                       t: TimeInterval, canvas: CGSize, above: Bool) {
        guard let raw = project.visualizer, raw.enabled, raw.aboveText == above else { return }
        let spec = raw.resolved(atSong: t)
        let url = project.audio.flatMap { AudioLoader.resolveURL(from: $0) }
        let want = max(4, spec.bandCount)
        let bands = SpectrumStore.bands(for: url, at: t, count: want)
            ?? [Float](repeating: 0.16, count: want)
        VisualizerRenderer.draw(in: cg, canvasSize: canvas, spec: spec, bands: bands, flipped: true)
    }

    private static func videoFrame(_ url: URL, at t: TimeInterval) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.6, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.6, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        let cmt = CMTime(seconds: max(0, t), preferredTimescale: 600)
        return try? gen.copyCGImage(at: cmt, actualTime: nil)
    }

    private static func loadImage(_ url: URL?) -> CGImage? {
        guard let url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func savePNG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
