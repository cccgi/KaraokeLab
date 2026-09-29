import Foundation
import AVFoundation
import Accelerate

/// Đọc file audio và rút "đường bao biên độ" để vẽ sóng âm.
/// Dùng vDSP (vector) để trích đỉnh — nhanh hơn vòng lặp Swift 20–50×.
enum WaveformLoader {

    /// Cache theo đường dẫn file: mở lại project cùng bài -> có ngay, không phân tích lại.
    private static let cacheLock = NSLock()
    private static var cache: [String: [Float]] = [:]

    static func load(url: URL, buckets: Int = 4000) async -> [Float] {
        let path = url.path
        if let hit = cachedPeaks(path) { return hit }

        let peaks = await Task.detached(priority: .userInitiated) { () -> [Float] in
            analyze(url: url, buckets: buckets)
        }.value

        if !peaks.isEmpty { storePeaks(path, peaks) }
        return peaks
    }

    private static func cachedPeaks(_ path: String) -> [Float]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[path]
    }

    private static func storePeaks(_ path: String, _ peaks: [Float]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache.count > 8 { cache.removeAll(keepingCapacity: true) }
        cache[path] = peaks
    }

    private static func analyze(url: URL, buckets: Int) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, format.channelCount > 0 else { return [] }

        let channels = Int(format.channelCount)
        let framesPerBucket = max(1, Int(totalFrames) / buckets)
        var peaks = [Float](repeating: 0, count: buckets)

        let chunkCapacity: AVAudioFrameCount = 1 << 20
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return [] }

        // Vùng đệm mono tạm để cộng các kênh vào.
        var mono = [Float](repeating: 0, count: Int(chunkCapacity))
        var processed = 0

        while file.framePosition < totalFrames {
            do { try file.read(into: buffer) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let chans = buffer.floatChannelData else { break }

            // mono = |ch0| (rồi max với |chK|) — dùng vDSP.
            vDSP_vabs(chans[0], 1, &mono, 1, vDSP_Length(n))
            if channels > 1 {
                var tmp = [Float](repeating: 0, count: n)
                for c in 1..<channels {
                    vDSP_vabs(chans[c], 1, &tmp, 1, vDSP_Length(n))
                    vDSP_vmax(mono, 1, tmp, 1, &mono, 1, vDSP_Length(n))
                }
            }

            // Trích đỉnh theo từng bucket bằng vDSP_maxv.
            var offset = 0
            while offset < n {
                let globalFrame = processed + offset
                let bucket = min(buckets - 1, globalFrame / framesPerBucket)
                let bucketEndFrame = (bucket + 1) * framesPerBucket
                let take = min(n - offset, max(1, bucketEndFrame - globalFrame))
                var localMax: Float = 0
                mono.withUnsafeBufferPointer { p in
                    vDSP_maxv(p.baseAddress! + offset, 1, &localMax, vDSP_Length(take))
                }
                if localMax > peaks[bucket] { peaks[bucket] = localMax }
                offset += take
            }
            processed += n
        }

        // Chuẩn hoá đỉnh cao nhất = 1.
        var maxPeak: Float = 0
        vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(buckets))
        if maxPeak > 0 {
            var inv = 1 / maxPeak
            vDSP_vsmul(peaks, 1, &inv, &peaks, 1, vDSP_Length(buckets))
        }
        return peaks
    }
}
