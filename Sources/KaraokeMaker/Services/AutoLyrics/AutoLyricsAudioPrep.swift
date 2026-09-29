import Foundation
import AVFoundation

/// Chuẩn bị âm thanh cho helper: WAV 16 kHz mono float32 (bộ đọc RIÊNG của tính năng này — KHÔNG đụng bộ đọc của aligner).
/// Bản nhận dạng dùng FULL MIX; bản tách giọng hát chỉ để dò "đoạn nào có giọng hát" (không đưa vào ASR).
enum AutoLyricsAudioPrep {

    static let targetRate: Double = 16_000

    static func write16kMonoWAV(from source: URL, to dest: URL) throws {
        let samples = try read16kMonoAveraged(source)
        guard samples.count >= 8_000 else { throw AutoLyricsError.audioPrepFailed(source.lastPathComponent + " (< 0.5 s)") }
        try wavData(samples: samples, sampleRate: Int(targetRate)).write(to: dest, options: .atomic)
    }

    /// File bất kỳ (WAV/MP3/M4A…) → 16 kHz mono float32.
    ///
    /// SỬA (2026-09-24, do đo thật): `AVAudioConverter` đổi stereo→mono CHỈ LẤY KÊNH TRÁI (hệ số đo được L=0,9997 / R=0,0001;
    /// `afconvert` cũng y hệt) — mất hẳn kênh phải, phổ lệch so với chuẩn (SNR còn 13,6 dB) → nhận dạng kém hơn. Ở đây TỰ trộn
    /// mono = trung bình các kênh (đúng như ffmpeg `-ac 1`) rồi mới đổi tần số (mono→mono, không còn bước trộn kênh của Core Audio),
    /// và kéo bộ đổi cho tới HẾT (`.endOfStream`) để không cụt ~14 ms cuối bài (bản cũ mất 218 mẫu).
    static func read16kMonoAveraged(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { throw AutoLyricsError.audioPrepFailed(url.lastPathComponent) }
        let inFmt = file.processingFormat
        let inRate = inFmt.sampleRate
        let nch = Int(inFmt.channelCount)
        guard inRate > 0, nch >= 1,
              let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: 1, interleaved: false),
              let monoOut = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)
        else { throw AutoLyricsError.audioPrepFailed(url.lastPathComponent) }

        let chunk: AVAudioFrameCount = 65_536
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunk),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: chunk) else { throw AutoLyricsError.audioPrepFailed(url.lastPathComponent) }

        /// Đọc 1 khúc, trộn kênh → mono. Trả nil khi hết file.
        func nextMonoChunk() -> AVAudioPCMBuffer? {
            srcBuf.frameLength = 0
            guard (try? file.read(into: srcBuf, frameCount: chunk)) != nil, srcBuf.frameLength > 0,
                  let ch = srcBuf.floatChannelData, let dst = monoBuf.floatChannelData?[0] else { return nil }
            let n = Int(srcBuf.frameLength)
            monoBuf.frameLength = srcBuf.frameLength
            if nch == 1 { dst.update(from: ch[0], count: n) }
            else {
                dst.update(from: ch[0], count: n)
                for c in 1..<nch { for i in 0..<n { dst[i] += ch[c][i] } }
                let inv = 1 / Float(nch)
                for i in 0..<n { dst[i] *= inv }
            }
            return monoBuf
        }

        var out = [Float]()
        out.reserveCapacity(Int(Double(file.length) * targetRate / inRate) + 16_000)

        if abs(inRate - targetRate) < 0.5 {                       // đã 16 kHz: chỉ trộn kênh
            while let b = nextMonoChunk(), let p = b.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: p, count: Int(b.frameLength))) }
            return out
        }

        guard let conv = AVAudioConverter(from: monoIn, to: monoOut) else { throw AutoLyricsError.audioPrepFailed(url.lastPathComponent) }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let outCap = AVAudioFrameCount(Double(chunk) * targetRate / inRate) + 4_096
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: outCap) else { throw AutoLyricsError.audioPrepFailed(url.lastPathComponent) }

        var eof = false
        var guardIter = 0
        while guardIter < 1_000_000 {
            guardIter += 1
            outBuf.frameLength = 0
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
                if eof { inStatus.pointee = .endOfStream; return nil }
                guard let b = nextMonoChunk() else { eof = true; inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return b
            }
            if status == .error || err != nil { throw AutoLyricsError.audioPrepFailed(url.lastPathComponent) }
            let m = Int(outBuf.frameLength)
            if m > 0, let p = outBuf.floatChannelData?[0] { out.append(contentsOf: UnsafeBufferPointer(start: p, count: m)) }
            if status == .endOfStream || (m == 0 && eof) { break }
        }
        return out
    }

    /// WAV IEEE-float 32-bit mono (fmt 18 byte + chunk `fact`) — đọc được bằng libsndfile/soundfile.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(4 + (8 + 18) + (8 + 4) + (8 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(18)
        u16(3)                         // WAVE_FORMAT_IEEE_FLOAT
        u16(1)                         // mono
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(32); u16(0)
        d.append(contentsOf: Array("fact".utf8)); u32(4); u32(UInt32(samples.count))
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        samples.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: samples.count * 4)) }
        return d
    }
}
