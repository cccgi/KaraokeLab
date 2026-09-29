import Foundation
import Accelerate
import MDXOnnx

/// Tách giọng bằng MDX (ONNX) — trong app, offline. Ra vocal + nhạc nền (mix − vocal), stereo 44100 Hz.
///
/// Hai cấu hình:
/// - `.fast` = UVR-MDX-NET-Voc_FT (n_fft 7680, 1 kênh, bù 1.021) — nhẹ, nhanh.
/// - `.hq`   = MDX23C-8KFFT-InstVoc (n_fft 8192, 2 kênh, bù 1.0) — sạch hơn, chậm hơn nhiều.
enum MDXSeparator {

    struct Config {
        let resource: String
        let nFFT: Int
        let hop: Int
        let dimF: Int
        let dimT: Int
        let compensate: Float
        let stems: Int          // 1 (Voc_FT) hoặc 2 (MDX23C — lấy kênh 0 = Vocals)
        var nBins: Int { nFFT / 2 + 1 }
        var chunkSize: Int { hop * (dimT - 1) }
        var trim: Int { nFFT / 2 }
        var genSize: Int { chunkSize - 2 * trim }
        var modelURL: URL? { KMBundle.url(forResource: resource, withExtension: "onnx") }

        static let fast = Config(resource: "UVR-MDX-NET-Voc_FT", nFFT: 7680, hop: 1024,
                                 dimF: 3072, dimT: 256, compensate: 1.021, stems: 1)
        static let hq   = Config(resource: "mdx23c-vocinst", nFFT: 8192, hop: 1024,
                                 dimF: 4096, dimT: 256, compensate: 1.0, stems: 2)
    }

    /// Nặng — LUÔN gọi trong `Task.detached`. `progress` 0…1.
    static func separate(source: URL, vocalOut: URL, accompOut: URL, config cfg: Config = .fast,
                         progress: @escaping @Sendable (Double) -> Void) throws -> LocalSeparator.Output {
        guard let model = cfg.modelURL else { throw LocalSeparatorError.noModel }
        let nFFT = cfg.nFFT, hop = cfg.hop, dimF = cfg.dimF, dimT = cfg.dimT
        let nBins = cfg.nBins, chunkSize = cfg.chunkSize, trim = cfg.trim, genSize = cfg.genSize
        let compensate = cfg.compensate
        _ = chunkSize

        let (mixL, mixR) = try LocalSeparator.readStereo44k(source)
        let n = mixL.count
        guard n > 0 else { throw LocalSeparatorError.cannotOpen }

        guard let sess = mdx_open(model.path, 1) else { throw LocalSeparatorError.separateFailed(-1) }
        defer { mdx_close(sess) }

        let stft = STFT(nFFT: nFFT, hop: hop, frames: dimT)

        // Đệm: [trim 0] + mix + [pad 0] + [trim 0]
        var pad = genSize - (n % genSize)
        if pad <= 0 { pad += genSize }
        let plen = trim + n + pad + trim
        var pL = [Float](repeating: 0, count: plen)
        var pR = [Float](repeating: 0, count: plen)
        pL.withUnsafeMutableBufferPointer { d in mixL.withUnsafeBufferPointer { s in
            d.baseAddress!.advanced(by: trim).update(from: s.baseAddress!, count: n) } }
        pR.withUnsafeMutableBufferPointer { d in mixR.withUnsafeBufferPointer { s in
            d.baseAddress!.advanced(by: trim).update(from: s.baseAddress!, count: n) } }

        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)

        let inCap = 4 * dimF * dimT
        // MDX23C ra 2 kênh → out gấp đôi input; Voc_FT ra 1 kênh.
        var inBuf = [Float](repeating: 0, count: inCap)
        var runOut = [Float](repeating: 0, count: inCap * max(1, cfg.stems) + 4096)
        var outShape = [Int](repeating: 0, count: 8)
        var outLen = 0
        var outRank: Int32 = 0

        let nChunks = (n + pad) / genSize
        var written = 0

        for c in 0..<nChunks {
            let base = c * genSize
            // --- STFT 2 kênh, ghép input [1,4,dimF,dimT] (layout ((ch*dimF)+f)*dimT + t) ---
            let (reL, imL) = stft.forward(pL, from: base)
            let (reR, imR) = stft.forward(pR, from: base)
            for f in 0..<dimF {
                let of0 = (0 * dimF + f) * dimT
                let of1 = (1 * dimF + f) * dimT
                let of2 = (2 * dimF + f) * dimT
                let of3 = (3 * dimF + f) * dimT
                for t in 0..<dimT {
                    let src = t * nBins + f
                    inBuf[of0 + t] = reL[src]
                    inBuf[of1 + t] = imL[src]
                    inBuf[of2 + t] = reR[src]
                    inBuf[of3 + t] = imR[src]
                }
            }

            let shape: [Int] = [1, 4, dimF, dimT]
            let rc: Int32 = inBuf.withUnsafeBufferPointer { ib in
                shape.withUnsafeBufferPointer { sh in
                    runOut.withUnsafeMutableBufferPointer { ob in
                        outShape.withUnsafeMutableBufferPointer { os in
                            mdx_run(sess, ib.baseAddress, ib.count, sh.baseAddress, 4,
                                    ob.baseAddress, ob.count, &outLen, os.baseAddress, &outRank)
                        }
                    }
                }
            }
            guard rc == 0 else { throw LocalSeparatorError.separateFailed(rc) }

            // --- ISTFT: model out [4,dimF,dimT] → 2 wave [chunkSize] ---
            let waveL = stft.inverse(re: runOut, im: runOut, chOffset: 0, dimF: dimF, nBins: nBins)
            let waveR = stft.inverse(re: runOut, im: runOut, chOffset: 2, dimF: dimF, nBins: nBins)

            // lấy phần giữa [trim ..< trim+genSize] → ghép vào outL/outR
            let take = min(genSize, n - written)
            if take > 0 {
                for k in 0..<take {
                    outL[written + k] = waveL[trim + k] * compensate
                    outR[written + k] = waveR[trim + k] * compensate
                }
                written += take
            }
            progress(Double(c + 1) / Double(nChunks))
        }

        // nhạc nền = mix − vocal
        var accL = [Float](repeating: 0, count: n)
        var accR = [Float](repeating: 0, count: n)
        for k in 0..<n {
            accL[k] = mixL[k] - outL[k]
            accR[k] = mixR[k] - outR[k]
        }

        try LocalSeparator.writeStereo44k(left: outL, right: outR, to: vocalOut)
        try LocalSeparator.writeStereo44k(left: accL, right: accR, to: accompOut)
        return LocalSeparator.Output(vocalURL: vocalOut, accompURL: accompOut)
    }
}

// MARK: - STFT / ISTFT (center=True, Hann periodic), n_fft = 7680 (= 15·2⁹, vDSP DFT hỗ trợ)

private final class STFT {
    let nFFT: Int
    let hop: Int
    let frames: Int
    let nBins: Int
    private let win: [Float]
    private let dftF: vDSP.DFT<Float>
    private let dftI: vDSP.DFT<Float>
    /// Bao hình OLA của win² để chuẩn hoá ISTFT (dài chunkSize + nFFT).
    private let envelope: [Float]
    private let chunkSize: Int

    init(nFFT: Int, hop: Int, frames: Int) {
        self.nFFT = nFFT; self.hop = hop; self.frames = frames
        self.nBins = nFFT / 2 + 1
        self.chunkSize = hop * (frames - 1)

        var w = [Float](repeating: 0, count: nFFT)
        for k in 0..<nFFT { w[k] = 0.5 - 0.5 * cos(2 * Float.pi * Float(k) / Float(nFFT)) } // periodic
        self.win = w

        dftF = vDSP.DFT(count: nFFT, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
        dftI = vDSP.DFT(count: nFFT, direction: .inverse, transformType: .complexComplex, ofType: Float.self)!

        // envelope: OLA của win^2 tại hop trên [0 ..< chunkSize + nFFT]
        var env = [Float](repeating: 0, count: chunkSize + nFFT)
        for t in 0..<frames {
            let s = t * hop
            for k in 0..<nFFT { env[s + k] += w[k] * w[k] }
        }
        for i in 0..<env.count where env[i] < 1e-8 { env[i] = 1e-8 }
        self.envelope = env
    }

    /// Forward STFT của 1 kênh, lấy `chunkSize` mẫu bắt đầu tại `from` trong `sig` (đã đệm sẵn 2 đầu).
    /// Trả (re, im) phẳng, index = t*nBins + f, f ∈ [0, nBins).
    func forward(_ sig: [Float], from: Int) -> (re: [Float], im: [Float]) {
        // center=True: thêm nFFT/2 mẫu 0 phía trước (và phía sau — sig đã đủ dài).
        var re = [Float](repeating: 0, count: frames * nBins)
        var im = [Float](repeating: 0, count: frames * nBins)
        var frameR = [Float](repeating: 0, count: nFFT)
        var frameI = [Float](repeating: 0, count: nFFT)
        let half = nFFT / 2

        for t in 0..<frames {
            let start = from + t * hop - half     // vị trí trong `sig` (có thể âm ở frame đầu)
            for k in 0..<nFFT {
                let idx = start + k
                let s: Float = (idx >= 0 && idx < sig.count) ? sig[idx] : 0
                frameR[k] = s * win[k]
                frameI[k] = 0
            }
            let (or_, oi_) = dftF.transform(inputReal: frameR, inputImaginary: frameI)
            let rowOff = t * nBins
            for f in 0..<nBins { re[rowOff + f] = or_[f]; im[rowOff + f] = oi_[f] }
        }
        return (re, im)
    }

    /// ISTFT 1 kênh. `re`/`im` là buffer model-out phẳng cỡ [4, dimF, dimT]
    /// (layout ((ch*dimF)+f)*dimT + t); `chOffset` = 0 (L) hoặc 2 (R).
    /// Trả wave dài `chunkSize`.
    func inverse(re: [Float], im: [Float], chOffset: Int, dimF: Int, nBins: Int) -> [Float] {
        var acc = [Float](repeating: 0, count: chunkSize + nFFT)
        var specR = [Float](repeating: 0, count: nFFT)
        var specI = [Float](repeating: 0, count: nFFT)
        let half = nFFT / 2

        let reOff = (chOffset * dimF)
        let imOff = ((chOffset + 1) * dimF)

        for t in 0..<frames {
            // Dựng phổ đầy đủ nFFT từ nBins (bin cao [dimF..nBins) = 0), đối xứng Hermitian.
            for f in 0..<nFFT { specR[f] = 0; specI[f] = 0 }
            for f in 0..<dimF {
                let vR = re[(reOff + f) * frames + t]
                let vI = im[(imOff + f) * frames + t]
                specR[f] = vR; specI[f] = vI
                if f > 0 && f < half {
                    specR[nFFT - f] = vR
                    specI[nFFT - f] = -vI
                }
            }
            specI[0] = 0
            specI[half] = 0

            let (tr, _) = dftI.transform(inputReal: specR, inputImaginary: specI)
            // vDSP inverse DFT chưa chuẩn hoá → chia nFFT; nhân cửa sổ tổng hợp (Hann).
            let s = t * hop
            let inv = 1 / Float(nFFT)
            for k in 0..<nFFT {
                acc[s + k] += tr[k] * inv * win[k]
            }
        }

        // chia bao hình rồi cắt nFFT/2 mỗi đầu
        var out = [Float](repeating: 0, count: chunkSize)
        for i in 0..<chunkSize {
            out[i] = acc[half + i] / envelope[half + i]
        }
        return out
    }
}
