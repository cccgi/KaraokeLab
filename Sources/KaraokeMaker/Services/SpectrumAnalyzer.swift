import Foundation
import AVFoundation
import Accelerate

/// Phổ tần số theo thời gian của AUDIO GỐC — để vẽ "sóng nhạc".
/// Phân tích 1 lần (FFT ngoại tuyến), lưu cache theo đường dẫn file.
struct SpectrumData {
    let fps: Double
    let bandCount: Int            // số dải nội bộ (64)
    let frames: [[Float]]         // [khung][dải] trong 0…1
    /// Năng lượng TỔNG (bass-weighted, đã chuẩn hoá 0…1) mỗi khung — dùng cho hiệu ứng
    /// "thở theo nhịp" (nền tự zoom theo nhạc). Cùng nguồn với "pump" của thanh cột.
    let energy: [Float]

    /// Lấy `want` dải tại thời điểm `time` (nội suy khung + gộp dải).
    func bands(at time: Double, want: Int) -> [Float] {
        let want = max(1, want)
        guard !frames.isEmpty else { return [Float](repeating: 0, count: want) }
        let fi = min(frames.count - 1, max(0, Int((time * fps).rounded())))
        let src = frames[fi]
        if want == src.count { return src }
        var out = [Float](repeating: 0, count: want)
        for i in 0..<want {
            let a = Int(Double(i) * Double(src.count) / Double(want))
            let b = max(a + 1, Int(Double(i + 1) * Double(src.count) / Double(want)))
            var s: Float = 0; var n = 0
            for k in a..<min(b, src.count) { s += src[k]; n += 1 }
            out[i] = n > 0 ? s / Float(n) : 0
        }
        return out
    }

    /// Năng lượng tại `time`, NỘI SUY TUYẾN TÍNH giữa 2 khung sát nhau — mượt cho hiệu ứng
    /// zoom nền (không giật như bám khung gần nhất).
    func energy(at time: Double) -> Float {
        guard !energy.isEmpty else { return 0 }
        let pos = max(0, time * fps)
        let i0 = min(energy.count - 1, Int(pos))
        let i1 = min(energy.count - 1, i0 + 1)
        let frac = Float(pos - Double(i0))
        return energy[i0] + (energy[i1] - energy[i0]) * frac
    }
}

enum SpectrumStore {

    static let fps: Double = 60
    private static let internalBands = 64
    private static let lock = NSLock()
    private static var cache: [String: SpectrumData] = [:]
    private static var inflight: Set<String> = []

    /// `NSLock.lock()/unlock()` are `noasync` (Swift 6 flags calling them directly inside an
    /// `async` closure, e.g. `Task.detached { ... }`, even when never held across a suspension
    /// point). Routing through a plain, non-`async` function keeps the lock/unlock calls in a
    /// synchronous context regardless of what calls this — same effect, no warning.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Bắn khi phân tích xong (để Preview vẽ lại). `userInfo["path"]`.
    static let readyNote = Notification.Name("SpectrumStore.ready")

    static func data(for url: URL) -> SpectrumData? {
        withLock { cache[url.path] }
    }

    /// Bắt đầu phân tích nếu chưa có / chưa chạy. Gọi nhiều lần vẫn an toàn.
    static func ensure(for url: URL) {
        let path = url.path
        let alreadyHandled = withLock { () -> Bool in
            if cache[path] != nil || inflight.contains(path) { return true }
            inflight.insert(path)
            return false
        }
        if alreadyHandled { return }
        Task.detached(priority: .utility) {
            let d = analyze(url: url, bands: internalBands, fps: fps)
            withLock {
                if let d {
                    if cache.count > 4 { cache.removeAll(keepingCapacity: true) }
                    cache[path] = d
                }
                inflight.remove(path)
            }
            if d != nil {
                await MainActor.run {
                    NotificationCenter.default.post(name: readyNote, object: nil, userInfo: ["path": path])
                }
            }
        }
    }

    /// Dải sóng tại `time`. `nil` nếu chưa phân tích xong (sẽ tự kích hoạt).
    static func bands(for url: URL?, at time: Double, count: Int) -> [Float]? {
        guard let url else { return nil }
        if let d = data(for: url) { return d.bands(at: time, want: count) }
        ensure(for: url)
        return nil
    }

    /// Năng lượng "thở theo nhịp" tại `time` (0…1) — dùng cho hiệu ứng nền tự zoom theo
    /// nhạc. `0` nếu chưa có audio / chưa phân tích xong (sẽ tự kích hoạt, KHÔNG chặn).
    static func energy(for url: URL?, at time: Double) -> Float {
        guard let url else { return 0 }
        if let d = data(for: url) { return d.energy(at: time) }
        ensure(for: url)
        return 0
    }

    /// Phân tích NGAY (chặn luồng gọi) — dùng cho xuất video (đã ở luồng nền).
    static func dataBlocking(for url: URL) -> SpectrumData? {
        if let d = data(for: url) { return d }
        let d = analyze(url: url, bands: internalBands, fps: fps)
        if let d {
            withLock {
                if cache.count > 4 { cache.removeAll(keepingCapacity: true) }
                cache[url.path] = d
            }
        }
        return d
    }

    // MARK: - FFT ngoại tuyến

    private static func analyze(url: URL, bands: Int, fps: Double) -> SpectrumData? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let total = Int(file.length)
        guard total > 0, sr > 0, fmt.channelCount > 0 else { return nil }

        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total)) else { return nil }
        do { try file.read(into: buf) } catch { return nil }
        let n = Int(buf.frameLength)
        guard n > 4096, let ch = buf.floatChannelData else { return nil }

        var mono = [Float](repeating: 0, count: n)
        let chc = Int(fmt.channelCount)
        if chc == 1 {
            mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: ch[0], count: n) }
        } else {
            for c in 0..<chc { vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(n)) }
            var div = Float(chc)
            vDSP_vsdiv(mono, 1, &div, &mono, 1, vDSP_Length(n))
        }

        let fftSize = 4096
        let half = fftSize / 2
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let hop = max(1, Int(sr / fps))
        let nFrames = max(1, (n - fftSize) / hop + 1)

        // dải log: 40 Hz … min(16 kHz, Nyquist)
        let fMin = 40.0, fMax = min(16000.0, sr / 2 - 100)
        let binHz = sr / Double(fftSize)
        var bandBins: [(lo: Int, hi: Int)] = []
        for b in 0..<bands {
            let f0 = fMin * pow(fMax / fMin, Double(b) / Double(bands))
            let f1 = fMin * pow(fMax / fMin, Double(b + 1) / Double(bands))
            let lo = max(1, Int(f0 / binHz))
            let hi = max(lo + 1, min(half, Int(f1 / binHz) + 1))
            bandBins.append((lo, hi))
        }

        var frames = [[Float]](repeating: [Float](repeating: 0, count: bands), count: nFrames)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: fftSize)
        var mags = [Float](repeating: 0, count: half)
        var smooth = [Float](repeating: 0, count: bands)
        let aUp: Float = 0.55, aDown: Float = 0.09

        mono.withUnsafeBufferPointer { mp in
            for fi in 0..<nFrames {
                let start = fi * hop
                vDSP_vmul(mp.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        windowed.withUnsafeBytes { raw in
                            vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                                      &split, 1, vDSP_Length(half))
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                var cnt = Int32(half)
                vvsqrtf(&mags, mags, &cnt)
                mags.withUnsafeBufferPointer { magp in
                    for b in 0..<bands {
                        let (lo, hi) = bandBins[b]
                        var s: Float = 0
                        vDSP_meanv(magp.baseAddress! + lo, 1, &s, vDSP_Length(hi - lo))
                        // biên độ tuyến tính (log nhẹ để nén dải), làm mượt thời gian
                        let v = powf(max(s, 1e-7), 0.34)
                        let prev = smooth[b]
                        smooth[b] = v > prev ? prev + (v - prev) * aUp : prev + (v - prev) * aDown
                        frames[fi][b] = smooth[b]
                    }
                }
            }
        }

        // Chuẩn hoá THEO TỪNG DẢI (mỗi dải chia cho sàn + trần riêng của nó suốt bài)
        // → mất "dốc phổ" tĩnh, hiện đúng ĐỘ NHÚN NHẢY của từng dải. Kiểu spectrum chuyên nghiệp.
        for b in 0..<bands {
            var col = [Float](repeating: 0, count: nFrames)
            for fi in 0..<nFrames { col[fi] = frames[fi][b] }
            col.sort()
            let floor = col[Int(Double(nFrames) * 0.08)]
            let ceil  = max(floor + 1e-4, col[Int(Double(nFrames) * 0.88)])
            let span = ceil - floor
            for fi in 0..<nFrames {
                var x = (frames[fi][b] - floor) / span
                x = x <= 0 ? 0 : (x >= 1.15 ? 1.15 : x)
                frames[fi][b] = powf(min(1, x), 1.12)   // cong nhẹ: cột nhỏ thấp, đỉnh nổi
            }
        }
        // "Nhịp thở" cả dàn theo năng lượng tổng (kick/beat) — nhân nhẹ toàn dải.
        var energy = [Float](repeating: 0, count: nFrames)
        for fi in 0..<nFrames {
            var e: Float = 0
            for b in 0..<min(bands, 10) { e += frames[fi][b] }
            energy[fi] = e / 10
        }
        var eSorted = energy; eSorted.sort()
        let eLo = eSorted[Int(Double(nFrames) * 0.2)]
        let eHi = max(eLo + 1e-4, eSorted[Int(Double(nFrames) * 0.9)])
        var energyNorm = [Float](repeating: 0, count: nFrames)
        for fi in 0..<nFrames {
            let n = max(0, min(1, (energy[fi] - eLo) / (eHi - eLo)))
            energyNorm[fi] = n
            let pump = 0.88 + 0.20 * n
            for b in 0..<bands { frames[fi][b] = min(1, frames[fi][b] * pump) }
        }
        // Đường năng lượng RIÊNG cho hiệu ứng "nền tự zoom theo nhạc" — làm mượt THÊM
        // (chậm hơn pump của cột) vì zoom cả khung hình mà giật sẽ rất chói mắt.
        var zoomEnergy = [Float](repeating: 0, count: nFrames)
        let zUp: Float = 0.22, zDown: Float = 0.05
        var zPrev: Float = 0
        for fi in 0..<nFrames {
            let target = energyNorm[fi]
            zPrev = target > zPrev ? zPrev + (target - zPrev) * zUp : zPrev + (target - zPrev) * zDown
            zoomEnergy[fi] = zPrev
        }
        return SpectrumData(fps: fps, bandCount: bands, frames: frames, energy: zoomEnergy)
    }
}
