import Foundation
import AVFoundation

/// Dò các thời điểm "bật âm" (onset) trong một đoạn audio — dựa vào biến thiên
/// năng lượng ngắn hạn (không FFT, chạy nhanh, offline). Dùng cho auto word-timing.
enum AudioOnsetDetector {

    /// Đọc mẫu mono trong khoảng [start, end] giây.
    private static func monoSamples(url: URL, start: Double, end: Double) -> (samples: [Float], sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        guard sr > 0, fmt.channelCount > 0, file.length > 0 else { return nil }

        let startFrame = AVAudioFramePosition(max(0, start) * sr)
        let endFrame = min(file.length, AVAudioFramePosition(max(start, end) * sr))
        guard endFrame > startFrame else { return nil }
        file.framePosition = startFrame

        let chunk: AVAudioFrameCount = 1 << 18
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return nil }
        let ch = Int(fmt.channelCount)
        var out = [Float]()
        out.reserveCapacity(Int(endFrame - startFrame))
        var remaining = Int(endFrame - startFrame)

        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(remaining, Int(chunk)))
            buf.frameLength = 0
            do { try file.read(into: buf, frameCount: toRead) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let cd = buf.floatChannelData else { break }
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<ch { s += cd[c][i] }
                out.append(s / Float(ch))
            }
            remaining -= n
        }
        return out.isEmpty ? nil : (out, sr)
    }

    /// Tìm các ĐOẠN CÓ GIỌNG trong [start, end] của file (nên dùng file vocal đã tách —
    /// lúc nhạc dạo nó gần như im). Dùng để phát hiện câu Whisper bỏ sót.
    /// Trả về [(bắt đầu, kết thúc)] giây.
    static func voicedRegions(url: URL, start: Double, end: Double,
                              minVoiced: Double = 0.8, minSilence: Double = 0.45) -> [(Double, Double)] {
        guard end - start > 0.4,
              let (raw, sr) = monoSamples(url: url, start: start, end: end), raw.count > 256 else { return [] }

        let hop = max(1, Int(sr * 0.02))          // 20 ms
        let win = max(hop, Int(sr * 0.04))        // 40 ms
        guard raw.count > win + hop else { return [] }
        let frames = (raw.count - win) / hop
        guard frames > 6 else { return [] }

        var rms = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let p = f * hop
            var acc: Float = 0
            for k in 0..<win { let v = raw[p + k]; acc += v * v }
            rms[f] = (acc / Float(win)).squareRoot()
        }

        let sorted = rms.sorted()
        let floorLevel = sorted[max(0, sorted.count / 5)]      // ~phân vị 20%
        let peak = sorted[sorted.count - 1]
        guard peak > max(2e-4, floorLevel * 3) else { return [] }   // không có giọng đáng kể
        let thr = max(floorLevel * 2.5, peak * 0.16)

        let frameDur = Double(hop) / sr
        let minVoicedF = max(1, Int(minVoiced / frameDur))
        let minSilenceF = max(1, Int(minSilence / frameDur))

        var regions: [(Int, Int)] = []
        var inReg = false, regStart = 0, silRun = 0
        for f in 0..<frames {
            if rms[f] >= thr {
                if !inReg { inReg = true; regStart = f }
                silRun = 0
            } else if inReg {
                silRun += 1
                if silRun >= minSilenceF {
                    regions.append((regStart, f - silRun))
                    inReg = false
                }
            }
        }
        if inReg { regions.append((regStart, frames - 1)) }

        return regions
            .filter { $0.1 - $0.0 >= minVoicedF }
            .map { (start + Double($0.0) * frameDur, start + Double($0.1 + minSilenceF) * frameDur) }
    }

    /// Trả về tối đa `maxCount` thời điểm onset (giây, tăng dần) trong [start, end].
    static func onsets(url: URL, start: Double, end: Double, maxCount: Int) -> [Double] {
        guard maxCount > 0, let (raw, sr) = monoSamples(url: url, start: start, end: end), raw.count > 128 else {
            return []
        }

        // Hạ tần số lấy mẫu xuống ~11 kHz cho nhẹ.
        let ds = max(1, Int((sr / 11025).rounded()))
        let esr = sr / Double(ds)
        let x: [Float]
        if ds == 1 {
            x = raw
        } else {
            var t = [Float](); t.reserveCapacity(raw.count / ds)
            var i = 0
            while i < raw.count { t.append(raw[i]); i += ds }
            x = t
        }

        let hop = max(1, Int(esr * 0.010))          // 10 ms
        let win = max(hop, Int(esr * 0.025))        // 25 ms
        guard x.count > win + hop * 4 else { return [] }
        let frames = (x.count - win) / hop
        guard frames > 4 else { return [] }

        var logE = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            let p = f * hop
            var acc: Float = 0
            for k in 0..<win { let v = x[p + k]; acc += v * v }
            logE[f] = log(acc / Float(win) + 1e-9)
        }

        // Novelty = phần tăng của log-năng-lượng, làm mượt 3 điểm.
        var flux = [Float](repeating: 0, count: frames)
        for f in 1..<frames { flux[f] = max(0, logE[f] - logE[f - 1]) }
        if frames > 2 {
            var sm = flux
            for f in 1..<(frames - 1) { sm[f] = (flux[f - 1] + flux[f] + flux[f + 1]) / 3 }
            flux = sm
        }

        let mean = flux.reduce(0, +) / Float(frames)
        let varc = flux.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(frames)
        let thr = mean + 0.5 * sqrt(varc)

        let minGap = 0.09
        var picks: [(t: Double, s: Float)] = []
        for f in 1..<(frames - 1) {
            let v = flux[f]
            guard v > thr, v >= flux[f - 1], v > flux[f + 1] else { continue }
            let t = start + Double(f * hop) / esr
            if let last = picks.last, t - last.t < minGap {
                if v > last.s { picks[picks.count - 1] = (t, v) }
            } else {
                picks.append((t, v))
            }
        }

        if picks.count > maxCount {
            picks.sort { $0.s > $1.s }
            picks = Array(picks.prefix(maxCount))
        }
        return picks.map(\.t).sorted()
    }
}
