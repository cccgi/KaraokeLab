import Foundation

/// Sinh nội dung file phụ đề `.srt` từ các dòng lời đã có timing.
enum SrtExporter {

    struct Cue {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// Toàn bộ nội dung file .srt (dùng CRLF cho tương thích rộng).
    static func makeSRT(from project: KaraokeProject) -> String {
        let cues = timedCues(from: project)
        var output = ""
        for (index, cue) in cues.enumerated() {
            output += "\(index + 1)\r\n"
            output += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\r\n"
            output += cue.text + "\r\n\r\n"
        }
        return output
    }

    /// Các dòng có timing, đã sắp theo thời gian bắt đầu.
    static func timedCues(from project: KaraokeProject) -> [Cue] {
        var cues: [Cue] = []
        for line in project.lines {
            guard let bounds = lineBounds(line) else { continue }
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = max(0, bounds.start)
            let end = max(start + 0.001, bounds.end)
            cues.append(Cue(start: start, end: end, text: text))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// [start, end] của một dòng: ưu tiên start/end của dòng; nếu thiếu thì
    /// suy từ timing các từ (khi sau này có word-level).
    private static func lineBounds(_ line: LyricLine) -> (start: TimeInterval, end: TimeInterval)? {
        if let start = line.start, let end = line.end {
            return (start, end)
        }
        let wordStarts = line.words.compactMap(\.start)
        let wordEnds = line.words.compactMap(\.end)
        if let start = wordStarts.min(), let end = wordEnds.max() {
            return (start, end)
        }
        return nil
    }

    /// Giây -> "HH:MM:SS,mmm".
    static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMillis = Int((max(0, seconds) * 1000).rounded())
        let millis = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let secs = totalSeconds % 60
        let mins = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, millis)
    }
}
