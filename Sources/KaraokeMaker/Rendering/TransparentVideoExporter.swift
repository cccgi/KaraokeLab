import AVFoundation
import CoreGraphics
import Foundation

/// Xuất video chỉ có chữ karaoke, nền trong suốt (ProRes 4444, alpha).
@MainActor
final class TransparentVideoExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var lastOutputURL: URL?
    /// Chặng hiện tại — màn "Đang xuất" hiện chữ theo chặng (không hiện "123/6754 khung").
    enum Phase { case preparing, frames, finishing, audio }
    @Published private(set) var phase: Phase = .preparing

    private var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
    }

    func export(project: KaraokeProject, to url: URL, duration: TimeInterval,
                solidBackground: CGColor? = nil,
                backgroundImage: CGImage? = nil, backgroundVideoURL: URL? = nil,
                audioURL: URL? = nil, preferProRes: Bool = false,
                visualizerOnly: Bool = false) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        phase = .preparing
        statusText = "Đang chuẩn bị…"
        lastError = nil
        lastOutputURL = nil

        let width = max(2, project.resolution.width)
        let height = max(2, project.resolution.height)
        let fps = max(1, Int(project.resolution.fps.rounded()))

        // M-D 1b — CẮT BÀI khi xuất: t=0 của video = giây `trimStart` của bài.
        let songLen = project.audio?.duration ?? duration
        let tStart = max(0, project.audioTrimStart)
        let tEnd = project.audioTrimEnd > 0.05 ? min(project.audioTrimEnd, songLen) : songLen
        let hasTrim = tStart > 0.05 || tEnd < songLen - 0.05
        let effDur = hasTrim ? max(0.1, tEnd - tStart) : duration
        let timeOffset = hasTrim ? tStart : 0
        let aGain = project.audioGain
        let aFadeIn = project.audioFadeIn
        let aFadeOut = project.audioFadeOut

        // Bước 2 — clip ★ KARAOKE dời sang phải `K` giây trên dòng thời gian XUẤT.
        // Tổng thời lượng = track kết thúc muộn nhất: karaoke (`K + effDur`) hoặc lớp đè.
        let K = max(0, project.karaokeClipStart)
        let overlayEndLocal = visualizerOnly ? 0
            : (project.overlays.filter { !$0.isHidden }.map { $0.end - timeOffset }.max() ?? 0)
        let outDur = max(0.1, max(max(0.1, effDur) + K, overlayEndLocal))
        let totalFrames = max(1, Int((outDur * Double(fps)).rounded()))

        let bgImage = backgroundImage
        let bgVideoURL = backgroundVideoURL
        let solidBG = solidBackground
        let sndURL = audioURL
        let wantProRes = preferProRes
        let vizOnly = visualizerOnly

        // TIẾNG các clip lớp đè: clip AUDIO, hoặc clip VIDEO đã bật tiếng (bỏ nếu ẩn / tắt loa).
        // Đặt lên dòng thời gian XUẤT (đã trừ `timeOffset` do cắt bài); cắt phần ló ra ngoài.
        let overlayAudio: [AudioMux.ExtraAudio] = vizOnly ? [] : project.overlays.compactMap { clip in
            guard clip.carriesAudio, let u = clip.resolveURL() else { return nil }
            let winLo = timeOffset, winHi = timeOffset + outDur
            let lo = max(clip.start, winLo), hi = min(clip.end, winHi)
            guard hi - lo > 0.05 else { return nil }
            let headCut = max(0, winLo - clip.start)              // phần clip nằm trước lúc video bắt đầu
            return AudioMux.ExtraAudio(
                url: u,
                at: max(0, clip.start - timeOffset),
                srcStart: clip.trimStart + headCut,
                dur: hi - lo,
                gain: 1,
                fadeIn: headCut < 0.05 ? clip.fadeIn : 0,
                fadeOut: clip.end <= winHi + 0.05 ? clip.fadeOut : 0)
        }

        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Tiết lưu: bộ ghi báo mỗi 5 khung → trước đây ContentView (giữ exporter bằng @StateObject) DỰNG LẠI
            // cả editor ~10–20 lần/giây suốt lúc xuất. Nay tối đa ~5 lần/giây (+ luôn báo mốc 100 %).
            let gate = ReportGate()
            let report: @Sendable (Double, String) -> Void = { value, text in
                guard gate.shouldPublish(value) else { return }
                Task { @MainActor in
                    self.progress = value
                    self.statusText = text
                    if self.phase != .audio { self.phase = value < 1 ? .frames : .finishing }
                }
            }

            // Nếu có tiếng: ghi video KHÔNG tiếng ra file tạm, xong ghép tiếng ở bước 2.
            let needsAudio = sndURL != nil || !overlayAudio.isEmpty
            let videoTarget = needsAudio
                ? url.deletingPathExtension()
                     .appendingPathExtension("noaudio." + url.pathExtension)
                : url

            do {
                try await VideoFrameWriter.write(
                    project: project, to: videoTarget,
                    width: width, height: height, fps: fps, totalFrames: totalFrames,
                    solidBackground: solidBG,
                    backgroundImage: bgImage,
                    backgroundVideoURL: bgVideoURL,
                    audioURL: nil,
                    preferProRes: wantProRes,
                    visualizerOnly: vizOnly,
                    timeOffset: timeOffset,
                    leadOffset: K,
                    report: report
                )

                let opaqueOut = (bgImage != nil || bgVideoURL != nil || solidBG != nil)
                if needsAudio {
                    await MainActor.run { self.phase = .audio }
                    report(1, "Đang ghép âm thanh…")
                    try await AudioMux.merge(video: videoTarget, audio: sndURL, to: url,
                                             fileType: (opaqueOut && !wantProRes) ? .mp4 : .mov,
                                             maxDuration: outDur,
                                             audioStart: timeOffset, gain: aGain,
                                             fadeIn: aFadeIn, fadeOut: aFadeOut,
                                             mainDelay: K,
                                             overlayAudio: overlayAudio)
                    try? FileManager.default.removeItem(at: videoTarget)
                }

                await MainActor.run {
                    self.isExporting = false
                    self.progress = 1
                    self.statusText = "Xong: \(url.lastPathComponent)"
                    self.lastOutputURL = url
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: videoTarget)
                await MainActor.run {
                    self.isExporting = false
                    self.statusText = "Đã huỷ."
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: videoTarget)
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Xuất video lỗi: \(error.localizedDescription)"
                    self.statusText = "Lỗi."
                }
            }
        }
    }
}

/// Cho qua tối đa ~5 lần báo tiến độ / giây (luôn cho qua mốc ≥ 100 %). Gọi từ luồng nền.
private final class ReportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last: CFAbsoluteTime = 0
    func shouldPublish(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        guard value >= 1 || now - last >= 0.2 else { return false }
        last = now
        return true
    }
}

// MARK: - Ghép tiếng vào video đã ghi xong (AVAssetExportSession — không tự bơm sample)

enum AudioMux {
    enum MuxError: LocalizedError {
        case noVideoTrack, cannotCreateSession, exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack:        return "File video vừa ghi không có hình."
            case .cannotCreateSession: return "Không tạo được phiên ghép âm thanh."
            case .exportFailed(let m): return "Ghép âm thanh lỗi: \(m)"
            }
        }
    }

    /// (M-E) TIẾNG của một clip VIDEO lớp đè, đặt lên dòng thời gian XUẤT.
    /// `at` = giây trên video xuất (đã trừ độ lệch cắt bài); `srcStart` = điểm vào trong file nguồn.
    struct ExtraAudio: Sendable {
        let url: URL
        let at: TimeInterval
        let srcStart: TimeInterval
        let dur: TimeInterval
        let gain: Double
        let fadeIn: TimeInterval
        let fadeOut: TimeInterval
    }

    /// Đưa file âm thanh về AAC .m4a, ĐỒNG THỜI cắt `[start, start+len]`, nhân `gain`,
    /// và fade in/out ở 2 đầu đoạn cắt (M-D 1b). `extras` = tiếng các clip video lớp đè
    /// (mỗi cái 1 track riêng + volume ramp) → preset AppleM4A trộn phẳng thành 1 track AAC.
    /// `source == nil` ⇒ CHỈ có tiếng lớp đè (không có bài hát chính). Bước ghép sau dùng passthrough.
    private static func encodeAAC(_ source: URL?,
                                 start: TimeInterval = 0, maxLen: TimeInterval = .greatestFiniteMagnitude,
                                 gain: Double = 1, fadeIn: TimeInterval = 0, fadeOut: TimeInterval = 0,
                                 sourceAt: TimeInterval = 0,          // Bước 2 — chèn bài hát chính TRỄ `sourceAt` giây (clip ★)
                                 extras: [ExtraAudio] = []) async throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kmk-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)

        let plain = extras.isEmpty && source != nil
            && start < 0.01 && maxLen == .greatestFiniteMagnitude && sourceAt < 0.01
            && gain > 0.999 && fadeIn < 0.01 && fadeOut < 0.01

        let exportAsset: AVAsset
        var mix: AVAudioMix?
        if plain, let source {
            exportAsset = AVURLAsset(url: source)
        } else {
            let comp = AVMutableComposition()
            var params: [AVMutableAudioMixInputParameters] = []
            let outCap = maxLen == .greatestFiniteMagnitude ? Double.greatestFiniteMagnitude : max(0.1, maxLen)

            // 1) Bài hát chính (nếu có).
            if let source {
                let asset = AVURLAsset(url: source)
                if let src = asset.tracks(withMediaType: .audio).first {
                    let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                    let s = max(0, min(start, max(0, asset.duration.seconds - 0.1)))
                    let delay = max(0, sourceAt)
                    let len = max(0.1, min(outCap - delay, asset.duration.seconds - s))
                    try dst.insertTimeRange(
                        CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                    duration: CMTime(seconds: len, preferredTimescale: 600)),
                        of: src, at: CMTime(seconds: delay, preferredTimescale: 600))
                    let p = AVMutableAudioMixInputParameters(track: dst)
                    let g = Float(max(0, min(1, gain)))
                    p.setVolume(g, at: .zero)
                    if fadeIn > 0.01 {
                        p.setVolumeRamp(fromStartVolume: 0, toEndVolume: g,
                            timeRange: CMTimeRange(start: CMTime(seconds: delay, preferredTimescale: 600),
                                                   duration: CMTime(seconds: min(fadeIn, len), preferredTimescale: 600)))
                    }
                    if fadeOut > 0.01 {
                        let fo = min(fadeOut, len)
                        p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0,
                            timeRange: CMTimeRange(start: CMTime(seconds: delay + len - fo, preferredTimescale: 600),
                                                   duration: CMTime(seconds: fo, preferredTimescale: 600)))
                    }
                    params.append(p)
                }
            }

            // 2) Tiếng từng clip video lớp đè.
            for ex in extras {
                let asset = AVURLAsset(url: ex.url)
                guard let src = asset.tracks(withMediaType: .audio).first else { continue }
                let srcDur = asset.duration.seconds
                guard srcDur > 0.05 else { continue }
                let s = max(0, min(ex.srcStart, max(0, srcDur - 0.05)))
                var len = max(0, min(ex.dur, srcDur - s))
                let at = max(0, ex.at)
                if outCap != .greatestFiniteMagnitude { len = min(len, max(0, outCap - at)) }
                guard len > 0.05 else { continue }
                guard let dst = comp.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try? dst.insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                duration: CMTime(seconds: len, preferredTimescale: 600)),
                    of: src, at: CMTime(seconds: at, preferredTimescale: 600))
                let p = AVMutableAudioMixInputParameters(track: dst)
                let g = Float(max(0, min(1, ex.gain)))
                p.setVolume(g, at: .zero)
                if ex.fadeIn > 0.01 {
                    let fi = min(ex.fadeIn, len)
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: g,
                        timeRange: CMTimeRange(start: CMTime(seconds: at, preferredTimescale: 600),
                                               duration: CMTime(seconds: fi, preferredTimescale: 600)))
                }
                if ex.fadeOut > 0.01 {
                    let fo = min(ex.fadeOut, len)
                    p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0,
                        timeRange: CMTimeRange(start: CMTime(seconds: at + len - fo, preferredTimescale: 600),
                                               duration: CMTime(seconds: fo, preferredTimescale: 600)))
                }
                params.append(p)
            }

            if params.isEmpty {
                // Không dựng được track nào (clip video không có tiếng, hoặc file bài hát hỏng).
                // Có bài hát chính → xuất thẳng bài hát; không có → coi như KHÔNG tiếng.
                guard let source else { throw MuxError.cannotCreateSession }
                exportAsset = AVURLAsset(url: source); mix = nil
            } else {
                let m = AVMutableAudioMix(); m.inputParameters = params
                exportAsset = comp; mix = m
            }
        }

        guard let s = AVAssetExportSession(asset: exportAsset, presetName: AVAssetExportPresetAppleM4A)
        else { throw MuxError.cannotCreateSession }
        s.outputURL = out
        s.outputFileType = .m4a
        s.audioMix = mix
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.exportAsynchronously { c.resume() } }
        guard s.status == .completed else {
            throw MuxError.exportFailed(s.error.map { String(describing: $0) }
                                       ?? "AAC status=\(s.status.rawValue)")
        }
        return out
    }

    /// Ghép track video của `video` + track audio (cắt bằng `maxDuration`) thành `out`.
    /// Video giữ nguyên (passthrough), audio đã trộn (bài hát chính + tiếng clip lớp đè) → AAC .m4a.
    /// `rawAudio == nil` ⇒ chỉ có `overlayAudio`.
    static func merge(video: URL, audio rawAudio: URL?, to out: URL,
                      fileType: AVFileType, maxDuration: TimeInterval,
                      audioStart: TimeInterval = 0, gain: Double = 1,
                      fadeIn: TimeInterval = 0, fadeOut: TimeInterval = 0,
                      mainDelay: TimeInterval = 0,
                      overlayAudio: [ExtraAudio] = []) async throws {
        try? FileManager.default.removeItem(at: out)

        let audio: URL
        do {
            audio = try await encodeAAC(rawAudio, start: audioStart, maxLen: max(0.1, maxDuration),
                                        gain: gain, fadeIn: fadeIn, fadeOut: fadeOut,
                                        sourceAt: mainDelay,
                                        extras: overlayAudio)
        } catch {
            // Chỉ có tiếng lớp đè mà dựng không được → xuất video KHÔNG tiếng, đừng để hỏng cả bản xuất.
            if rawAudio == nil {
                try FileManager.default.copyItem(at: video, to: out)
                return
            }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: audio) }

        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: video)
        let aAsset = AVURLAsset(url: audio)

        guard let vSrc = vAsset.tracks(withMediaType: .video).first,
              let vDst = comp.addMutableTrack(withMediaType: .video,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw MuxError.noVideoTrack }

        let vDur = vAsset.duration
        try vDst.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
        vDst.preferredTransform = vSrc.preferredTransform

        if let aSrc = aAsset.tracks(withMediaType: .audio).first,
           let aDst = comp.addMutableTrack(withMediaType: .audio,
                                           preferredTrackID: kCMPersistentTrackID_Invalid) {
            let want = CMTime(seconds: max(0.1, maxDuration), preferredTimescale: 600)
            let aLen = min(aAsset.duration, min(vDur, want))
            try? aDst.insertTimeRange(CMTimeRange(start: .zero, duration: aLen), of: aSrc, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: comp,
                                                 presetName: AVAssetExportPresetPassthrough)
        else { throw MuxError.cannotCreateSession }
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }

        if session.status != .completed {
            throw MuxError.exportFailed(session.error.map { String(describing: $0) }
                                       ?? "status=\(session.status.rawValue)")
        }
    }
}

// MARK: - Vòng lặp ghi từng khung

enum VideoFrameWriter {

    enum ExportError: LocalizedError {
        case cannotAddInput
        case cannotStartWriting
        case noPixelBufferPool
        case cannotCreatePixelBuffer
        case cannotCreateContext
        case appendFailed
        case finishFailed
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: return "Không thêm được luồng video vào file."
            case .cannotStartWriting: return "Không bắt đầu ghi được."
            case .noPixelBufferPool: return "Không tạo được vùng đệm ảnh."
            case .cannotCreatePixelBuffer: return "Không cấp phát được khung ảnh."
            case .cannotCreateContext: return "Không tạo được ngữ cảnh vẽ."
            case .appendFailed: return "Ghi khung hình thất bại."
            case .finishFailed: return "Kết thúc ghi file thất bại."
            case .writerFailed(let m): return "Bộ ghi video lỗi: \(m)"
            }
        }
    }

    /// "Nướng" nền ảnh tĩnh thành đúng cỡ khung 1 lần (solid + fit + scale + offset).
    private static func bakeBackground(_ image: CGImage, project: KaraokeProject,
                                       solid: CGColor?, width: Int, height: Int,
                                       colorSpace: CGColorSpace) -> CGImage? {
        let bmp = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bmp) else { return nil }
        Compositor.draw(
            Compositor.exportBackgroundLayers(project: project, solidBackground: solid, backdrop: image),
            in: ctx, canvasSize: CGSize(width: width, height: height), flipped: false)
        return ctx.makeImage()
    }

    /// Gói lỗi thật của AVAssetWriter (in ra Terminal + đưa lên UI).
    private static func writerError(_ writer: AVAssetWriter) -> ExportError {
        let msg = writer.error.map { String(describing: $0) } ?? "status=\(writer.status.rawValue)"
        FileHandle.standardError.write(Data("[export] \(msg)\n".utf8))
        return .writerFailed(msg)
    }

    static func write(
        project: KaraokeProject,
        to url: URL,
        width: Int,
        height: Int,
        fps: Int,
        totalFrames: Int,
        solidBackground: CGColor? = nil,
        backgroundImage: CGImage? = nil,
        backgroundVideoURL: URL? = nil,
        audioURL: URL? = nil,
        preferProRes: Bool = false,
        visualizerOnly: Bool = false,
        timeOffset: TimeInterval = 0,      // M-D 1b — karaoke vẽ tại (khung − lead + offset) = giây trong BÀI
        leadOffset: TimeInterval = 0,      // Bước 2 — clip ★ KARAOKE bắt đầu ở giây `leadOffset` của video xuất
        report: (Double, String) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)

        // "Sóng nhạc" + "Hiệu ứng Bass nền" (độc lập với nhau): phân tích phổ audio gốc TRƯỚC
        // vòng khung (chặn — đang ở luồng nền).
        let vizAudioURL: URL? = (visualizerOnly || project.visualizer?.enabled == true
                                  || project.backgroundMedia?.beatZoomEnabled == true)
            ? project.audio.flatMap { AudioLoader.resolveURL(from: $0) } : nil
        let vizData: SpectrumData? = vizAudioURL.flatMap { SpectrumStore.dataBlocking(for: $0) }

        // Nền video (Mode C2): đọc tuần tự từng khung theo thời gian.
        let bgVideo = backgroundVideoURL.flatMap { try? BackgroundVideoReader(url: $0) }
        let hasBackdrop = bgVideo != nil || backgroundImage != nil

        // Lớp đè VIDEO: 1 bộ đọc tuần tự / clip. Khung lấy theo (frameTime - clip.start).
        var overlayReaders: [UUID: BackgroundVideoReader] = [:]
        for clip in project.overlays where clip.kind == .video {
            if let url = clip.resolveURL(), let r = try? BackgroundVideoReader(url: url) {
                overlayReaders[clip.id] = r
            }
        }
        let overlayVideoFrame: (OverlayClip, TimeInterval) -> CGImage? = { clip, vt in
            overlayReaders[clip.id]?.image(at: vt)
        }

        // Nền màu / ảnh / video -> .mp4 H.264 (mã hoá phần cứng → NHANH).
        // `preferProRes`, hoặc KHÔNG nền (trong suốt) -> .mov ProRes 4444
        //   (mã hoá cực nhanh trên mọi máy; file lớn nhưng đúng ý ban đầu của app).
        let opaque = hasBackdrop || solidBackground != nil
        let transparent = !opaque
        let useProRes = preferProRes || transparent
        let container: AVFileType = (transparent || preferProRes) ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: container)
        var settings: [String: Any] = [
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        if opaque && !useProRes {
            let bitrate = min(80_000_000, max(3_000_000, Int(Double(width * height * fps) * 0.20)))
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: bitrate,
                // Main profile: máy Intel 2017 luôn mã hoá được bằng phần cứng.
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                // Tắt sắp xếp lại khung (B-frame) → bộ mã hoá xả đều, không ôm hàng chục
                // khung rồi kẹt `isReadyForMoreMediaData = false` mãi.
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2
            ]
        } else {
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // BẮT BUỘC cho bộ mã hoá H.264 phần cứng — thiếu key này pool tạo buffer
            // KHÔNG có IOSurface, encoder nuốt vài khung rồi hỏng ("Ghi khung hình thất bại").
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: bufferAttributes
        )
        let pixelBufferCreateAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true
        ]

        guard writer.canAdd(input) else { throw ExportError.cannotAddInput }
        writer.add(input)

        // Âm thanh KHÔNG ghép ở đây nữa (bơm 2 track cùng lúc dễ deadlock).
        // `write` chỉ tạo video; ghép tiếng làm bước sau bằng AVAssetExportSession.
        _ = audioURL

        guard writer.startWriting() else { throw writer.error ?? ExportError.cannotStartWriting }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Nền đục: BGRA bỏ alpha. Trong suốt: alpha premultiplied cho ProRes 4444 sạch.
        let bitmapInfo = (opaque ? CGImageAlphaInfo.noneSkipFirst.rawValue
                                 : CGImageAlphaInfo.premultipliedFirst.rawValue)
            | CGBitmapInfo.byteOrder32Little.rawValue

        report(0, "Đang xuất… 0/\(totalFrames) khung")

        let canvas = CGSize(width: width, height: height)

        // NỀN ẢNH TĨNH: "nướng" 1 lần thành đúng cỡ khung (đã áp solid + fit + scale + offset).
        // Nếu không, mỗi khung phải thu nhỏ lại ảnh gốc (ảnh điện thoại 12–24MP) → cực chậm,
        // trông như treo. Nền video thì vẫn vẽ từng khung như cũ.
        let songDur = Double(totalFrames) / Double(max(1, fps))
        // Ken Burns / zoom theo nhạc cần vẽ nền TỪNG KHUNG (vị trí/cỡ đổi liên tục) → không bake.
        let kenBurns = project.backgroundMedia?.kenBurns == true
        let beatZoomOn = project.backgroundMedia?.beatZoomEnabled == true
        let bakedBG: CGImage? = (bgVideo == nil && !kenBurns && !beatZoomOn) ? backgroundImage.flatMap {
            bakeBackground($0, project: project, solid: solidBackground,
                           width: width, height: height, colorSpace: colorSpace)
        } : nil

        // Kế hoạch vẽ chữ: bake ảnh tĩnh 1 lần/câu, mỗi khung chỉ dán + tô phần đang hát.
        let krPlan = KaraokeRenderer.PreviewPlan()

        // --- Đo hiệu năng: chỉ in khi đặt biến môi trường KMK_EXPORT_PROF=1 ---
        let profOn = ProcessInfo.processInfo.environment["KMK_EXPORT_PROF"] != nil
        let profStart = CFAbsoluteTimeGetCurrent()
        var pWait = 0.0, pAlloc = 0.0, pDraw = 0.0, pAppend = 0.0
        var pDrawMax = 0.0, pWaitMax = 0.0
        func profDump(_ done: Int) {
            guard profOn else { return }
            let wall = CFAbsoluteTimeGetCurrent() - profStart
            let fps_ = wall > 0 ? Double(done) / wall : 0
            let line = String(format:
                "[export-prof] %d khung / %.1fs  (%.1f fps)  vẽ=%.1fs(tb %.0fms, đỉnh %.0fms)  chờ-mã-hoá=%.1fs(đỉnh %.0fms)  cấp-phát=%.1fs  append=%.1fs\n",
                done, wall, fps_, pDraw, pDraw / Double(max(done,1)) * 1000, pDrawMax * 1000,
                pWait, pWaitMax * 1000, pAlloc, pAppend)
            FileHandle.standardError.write(Data(line.utf8))
        }

        var frameIndex = 0
        while frameIndex < totalFrames {
            try Task.checkCancellation()

            // Chờ bộ mã hoá tiêu hoá bớt. Nếu writer hỏng thì `isReadyForMoreMediaData`
            // kẹt `false` mãi mãi → phải bắt `writer.status` ở đây, đừng chờ vô tận.
            let tw0 = CFAbsoluteTimeGetCurrent()
            var waited = 0
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writerError(writer) }
                try await Task.sleep(nanoseconds: 5_000_000)
                try Task.checkCancellation()
                waited += 1
                if waited > 12_000 {   // ~60 giây không nhúc nhích ⇒ coi như treo
                    throw writerError(writer)
                }
            }
            let dw = CFAbsoluteTimeGetCurrent() - tw0
            pWait += dw; pWaitMax = max(pWaitMax, dw)

            let ta0 = CFAbsoluteTimeGetCurrent()
            // Tự cấp phát từng khung (KHÔNG qua pool của adaptor) — pool hay bị cạn khi
            // bộ mã hoá còn giữ buffer, rồi `...CreatePixelBuffer` chặn luồng vô tận.
            var pixelBufferOut: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      pixelBufferCreateAttrs as CFDictionary,
                                      &pixelBufferOut) == kCVReturnSuccess,
                  let pixelBuffer = pixelBufferOut else {
                throw ExportError.cannotCreatePixelBuffer
            }

            let frameTime = Double(frameIndex) / Double(fps)
            let srcTime = frameTime + timeOffset      // dòng thời gian XUẤT (cho LỚP ĐÈ) — cộng mốc cắt
            // Karaoke (nền + sóng + chữ) lùi theo clip ★: trước giây `leadOffset` là "chưa vào".
            let karTime = frameTime - leadOffset + timeOffset
            let karTimeClamped = max(0, karTime)
            let karInside = frameTime >= leadOffset - 0.5 / Double(fps)   // đã tới lượt karaoke chưa
            pAlloc += CFAbsoluteTimeGetCurrent() - ta0

            let td0 = CFAbsoluteTimeGetCurrent()
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            do {
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
                      let ctx = CGContext(
                        data: base,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                        space: colorSpace,
                        bitmapInfo: bitmapInfo
                      ) else {
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                    throw ExportError.cannotCreateContext
                }

                func drawViz(_ above: Bool) {
                    guard karInside,
                          let raw = project.visualizer, raw.enabled, raw.aboveText == above,
                          let vd = vizData else { return }
                    let spec = raw.resolved(atSong: karTimeClamped)
                    VisualizerRenderer.draw(in: ctx, canvasSize: canvas, spec: spec,
                                            bands: vd.bands(at: karTimeClamped, want: spec.bandCount), flipped: true)
                }

                if visualizerOnly {
                    // CHỈ sóng nhạc, nền trong suốt.
                    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
                    ctx.translateBy(x: 0, y: CGFloat(height))
                    ctx.scaleBy(x: 1, y: -1)
                    drawViz(false); drawViz(true)
                    ctx.flush()
                } else {
                // Nền đục phủ kín khung → khỏi clear (tiết kiệm 1 lần xoá cả khung).
                if !opaque {
                    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
                }

                // Nền (Mode C): vẽ TRƯỚC, hệ y-up gốc của context => nền đục.
                if let bakedBG {
                    ctx.draw(bakedBG, in: CGRect(x: 0, y: 0, width: width, height: height))
                } else {
                    let backdrop: CGImage? = bgVideo?.image(at: karTimeClamped) ?? backgroundImage
                    let beatEnergy: Float = (beatZoomOn && karInside) ? (vizData?.energy(at: karTimeClamped) ?? 0) : 0
                    Compositor.draw(
                        Compositor.exportBackgroundLayers(project: project,
                                                          solidBackground: solidBackground,
                                                          backdrop: backdrop,
                                                          time: karTimeClamped, duration: songDur,
                                                          beatEnergy: beatEnergy),
                        in: ctx, canvasSize: canvas, flipped: false)
                }

                // Gốc toạ độ lên trên-trái, y hướng xuống — khớp KaraokeRenderer.
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.scaleBy(x: 1, y: -1)

                // Lớp đè NẰM DƯỚI chữ.
                Compositor.draw(Compositor.overlayLayers(project: project, time: srcTime, zone: .belowText,
                                                        videoFrame: overlayVideoFrame),
                                in: ctx, canvasSize: canvas, flipped: true)

                drawViz(false)

                if karInside {
                    KaraokeRenderer.drawExport(in: ctx, canvasSize: canvas, project: project,
                                               time: karTime, plan: krPlan)
                }

                drawViz(true)

                // Lớp đè ĐÈ LÊN chữ (logo/ảnh) — context đang y-DOWN như chữ.
                Compositor.draw(Compositor.overlayLayers(project: project, time: srcTime, zone: .aboveText,
                                                        videoFrame: overlayVideoFrame),
                                in: ctx, canvasSize: canvas, flipped: true)
                ctx.flush()
                }
            }
            // Mở khoá TRƯỚC khi append — bộ mã hoá đọc buffer trên luồng riêng,
            // trao buffer còn khoá dễ làm nó nghẽn.
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let ddr = CFAbsoluteTimeGetCurrent() - td0
            pDraw += ddr; pDrawMax = max(pDrawMax, ddr)

            let tp0 = CFAbsoluteTimeGetCurrent()
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw writerError(writer)
            }
            pAppend += CFAbsoluteTimeGetCurrent() - tp0

            frameIndex += 1
            if frameIndex % 5 == 0 || frameIndex == totalFrames {
                report(Double(frameIndex) / Double(totalFrames), "Đang xuất… \(frameIndex)/\(totalFrames) khung")
            }
            if frameIndex % 120 == 0 { profDump(frameIndex) }
        }

        profDump(frameIndex)
        input.markAsFinished()

        report(Double(totalFrames) / Double(totalFrames), "Đang hoàn tất file…")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        if writer.status == .failed {
            throw writerError(writer)
        }
        report(1, "Hoàn tất")
    }
}

// MARK: - Đọc tuần tự khung video nền (Mode C2)

/// Đọc video nền theo thời gian tăng dần. `image(at:)` phải được gọi với `t`
/// KHÔNG giảm. Video hết -> giữ khung cuối. Video dài hơn -> chỉ đọc tới đâu cần.
final class BackgroundVideoReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    private var lastImage: CGImage?
    private var heldImage: CGImage?
    private var heldPTS: Double = -1
    private var finished = false

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw VideoFrameWriter.ExportError.cannotAddInput
        }
        reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoFrameWriter.ExportError.cannotAddInput }
        reader.add(output)
        reader.startReading()
    }

    func image(at t: Double) -> CGImage? {
        while true {
            if heldPTS >= 0, heldPTS <= t {
                lastImage = heldImage
                heldImage = nil
                heldPTS = -1
            }
            if heldPTS > t { break }        // khung kế còn ở tương lai -> lastImage đúng cho t
            if finished { break }
            guard let sample = output.copyNextSampleBuffer() else { finished = true; break }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let img = Self.cgImage(from: sample)
            if pts <= t {
                if let img { lastImage = img }
            } else {
                heldImage = img
                heldPTS = pts
            }
        }
        return lastImage
    }

    private static func cgImage(from sample: CMSampleBuffer) -> CGImage? {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }

        // Sao chép hẳn pixel ra Data để CGImage SỞ HỮU bộ nhớ — tránh crash khi
        // CVPixelBuffer bị reader tái sử dụng ở khung sau.
        let copy = Data(bytes: base, count: bpr * h)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bmp = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bpr, space: cs, bitmapInfo: bmp,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
