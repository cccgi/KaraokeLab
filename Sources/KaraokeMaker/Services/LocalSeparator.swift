import Foundation
import AVFoundation

enum LocalSeparatorError: LocalizedError {
    case noModel
    case cannotOpen
    case convertFailed(String)
    case separateFailed(Int32)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModel:            return "Không tìm thấy model tách nhạc trong app."
        case .cannotOpen:         return "Không mở được file nhạc."
        case .convertFailed(let m): return "Đổi âm thanh thất bại: \(m)"
        case .separateFailed(let c): return "Tách nhạc thất bại (mã \(c))."
        case .writeFailed(let m):  return "Không ghi được file kết quả: \(m)"
        }
    }
}

/// Tiện ích đọc/ghi âm thanh dùng chung cho phần tách nhạc trong máy (MDX-Net).
enum LocalSeparator {

    struct Output { let vocalURL: URL; let accompURL: URL }

    // MARK: - Đọc file → 44100 Hz, stereo, Float32

    static func readStereo44k(_ url: URL) throws -> ([Float], [Float]) {
        guard let inFile = try? AVAudioFile(forReading: url) else { throw LocalSeparatorError.cannotOpen }
        let inFmt = inFile.processingFormat
        guard inFmt.sampleRate > 0, inFmt.channelCount > 0 else { throw LocalSeparatorError.cannotOpen }

        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                         channels: 2, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            throw LocalSeparatorError.convertFailed("không tạo được bộ chuyển đổi")
        }

        let inChunk: AVAudioFrameCount = 65_536
        let outCap = AVAudioFrameCount((Double(inChunk) * 44_100 / inFmt.sampleRate).rounded(.up)) + 8_192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inChunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else {
            throw LocalSeparatorError.convertFailed("không cấp phát được vùng đệm")
        }

        var L = [Float](); var R = [Float]()
        let guess = Int(Double(inFile.length) * 44_100 / inFmt.sampleRate) + 44_100
        L.reserveCapacity(guess); R.reserveCapacity(guess)

        while true {
            inBuf.frameLength = 0
            do { try inFile.read(into: inBuf, frameCount: inChunk) }
            catch { throw LocalSeparatorError.convertFailed(error.localizedDescription) }
            let got = inBuf.frameLength
            if got == 0 { break }

            outBuf.frameLength = 0
            var fed = false
            var err: NSError?
            let st = conv.convert(to: outBuf, error: &err) { _, s in
                if fed { s.pointee = .noDataNow; return nil }
                fed = true; s.pointee = .haveData; return inBuf
            }
            if let err { throw LocalSeparatorError.convertFailed(err.localizedDescription) }
            if st == .error { throw LocalSeparatorError.convertFailed("trạng thái .error") }

            let m = Int(outBuf.frameLength)
            if m > 0, let ch = outBuf.floatChannelData {
                L.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: m))
                R.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: m))
            }
            if got < inChunk { break }
        }
        return (L, R)
    }

    // MARK: - Ghi WAV 44100 Hz stereo 16-bit

    static func writeStereo44k(left: [Float], right: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let f: AVAudioFile
        do { f = try AVAudioFile(forWriting: url, settings: settings) }
        catch { throw LocalSeparatorError.writeFailed(error.localizedDescription) }

        let wf = f.processingFormat          // Float32 (AVAudioFile tự đổi sang 16-bit khi ghi)
        let n = min(left.count, right.count)
        let chunk = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: wf, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw LocalSeparatorError.writeFailed("không cấp phát được vùng đệm")
        }
        var i = 0
        while i < n {
            let c = min(chunk, n - i)
            buf.frameLength = AVAudioFrameCount(c)
            if let ch = buf.floatChannelData {
                for k in 0..<c { ch[0][k] = left[i + k]; ch[1][k] = right[i + k] }
            }
            do { try f.write(from: buf) }
            catch { throw LocalSeparatorError.writeFailed(error.localizedDescription) }
            i += c
        }
    }
}
