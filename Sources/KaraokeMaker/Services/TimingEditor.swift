import Foundation

/// Các thao tác gán / chỉnh timing theo dòng. Tách riêng để cả SyncPanel
/// và danh sách dòng đều dùng chung, và để ContentView gọn.
enum TimingEditor {

    /// Bấm **T** — vào câu. Đặt điểm bắt đầu dòng hiện tại = `time - leadIn`,
    /// chốt điểm kết thúc cho dòng liền trước (điểm kết thúc dòng trước = điểm
    /// bắt đầu dòng này), rồi sang dòng kế. Trả về chỉ số dòng hiện tại MỚI.
    ///
    /// Dòng cuối: lần bấm đầu đặt điểm bắt đầu, lần bấm sau đặt điểm kết thúc.
    static func tap(lines: inout [LyricLine], at index: Int, time rawTime: TimeInterval, leadIn: TimeInterval) -> Int {
        guard lines.indices.contains(index) else { return index }
        let inTime = max(0, rawTime - leadIn)
        let isLast = index == lines.count - 1

        if isLast {
            if lines[index].start == nil {
                lines[index].start = inTime
                lines[index].source = .manual
                closePrevious(&lines, before: index, at: inTime)
            } else {
                lines[index].end = max(rawTime, lines[index].start ?? rawTime)
            }
            return index
        }

        lines[index].start = inTime
        lines[index].source = .manual
        if let end = lines[index].end, end <= inTime { lines[index].end = nil }
        closePrevious(&lines, before: index, at: inTime)
        return index + 1
    }

    private static func closePrevious(_ lines: inout [LyricLine], before index: Int, at time: TimeInterval) {
        let previous = index - 1
        guard lines.indices.contains(previous),
              let previousStart = lines[previous].start,
              lines[previous].end == nil else { return }   // đã chốt bằng Y thì tôn trọng
        lines[previous].end = max(time, previousStart)
    }

    /// Đặt điểm kết thúc của dòng `index` = `time` (không nhảy dòng).
    static func setEnd(lines: inout [LyricLine], at index: Int, time: TimeInterval) {
        guard lines.indices.contains(index) else { return }
        let lower = lines[index].start ?? 0
        lines[index].end = max(time, lower)
        refreshWords(&lines, at: index)
    }

    static func clear(lines: inout [LyricLine], at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].start = nil
        lines[index].end = nil
        lines[index].words = []
    }

    static func clearAll(lines: inout [LyricLine]) {
        for i in lines.indices {
            lines[i].start = nil
            lines[i].end = nil
            lines[i].words = []
        }
    }

    // MARK: - Timing theo chữ (Phase 9.1)

    /// Chia đều khoảng thời gian của dòng `index` cho từng chữ.
    static func distributeWords(lines: inout [LyricLine], at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].words = WordTiming.distribute(lines[index])
    }

    /// Chia đều theo chữ cho MỌI dòng đã gán đủ timing.
    static func distributeWordsAll(lines: inout [LyricLine]) {
        for i in lines.indices where lines[i].isTimed {
            lines[i].words = WordTiming.distribute(lines[i])
        }
    }

    static func clearWords(lines: inout [LyricLine], at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].words = []
    }

    /// Nếu dòng đang có timing theo chữ thì chia lại theo start/end mới.
    private static func refreshWords(_ lines: inout [LyricLine], at index: Int) {
        guard lines.indices.contains(index), !lines[index].words.isEmpty else { return }
        lines[index].words = WordTiming.distribute(lines[index])
    }

    /// Dọn chồng lấn: các dòng đã timing, sắp theo điểm bắt đầu, ép điểm kết thúc
    /// dòng trước không vượt quá điểm bắt đầu dòng sau (giữ nguyên các điểm bắt đầu).
    /// Làm các dòng **LIỀN NHAU trên timeline** (không hở) và tách bạch:
    ///  - `start`/`end` của dòng = mốc HIỂN THỊ (block). Dòng hiện lên `earlyShow`
    ///    giây trước khi dòng trước kết thúc thật, và kéo dài tới đúng lúc dòng sau
    ///    hiện ⇒ luôn có 1 dòng trên màn hình, các block khít nhau.
    ///  - `words` giữ khoảng HÁT THẬT `[startThật, endThật − trailingTrim]` ⇒ vệt
    ///    quét ĐỨNG YÊN tới khi vocal vang lên rồi mới chạy, xong đúng lúc block hết.
    ///  - Nghỉ dài (> `bigGap` giây, nhạc dạo): dòng chỉ hiện `preroll` giây trước,
    ///    có khoảng hở thật (renderer lo phần đếm ngược 3-2-1).
    static func makeContiguous(lines: inout [LyricLine],
                               earlyShow: TimeInterval = 0.5,
                               trailingTrim: TimeInterval = 0.5,
                               bigGap: TimeInterval = 8,
                               preroll: TimeInterval = 3) {
        let idx = lines.indices
            .filter { lines[$0].start != nil && lines[$0].end != nil }
            .sorted { (lines[$0].start ?? 0) < (lines[$1].start ?? 0) }
        guard !idx.isEmpty else { return }

        let realS = idx.map { lines[$0].start! }
        let realE = idx.map { lines[$0].end! }
        let last = idx.count - 1

        for k in idx.indices {
            let i = idx[k]
            let s = realS[k], e = realE[k]

            // Khoảng HÁT thật (đã cắt 0.5s đuôi) — dùng cho vệt quét.
            let wS = s
            let wE = max(s + 0.3, e - trailingTrim)

            if lines[i].words.isEmpty {
                if WordTiming.tokens(lines[i].text).isEmpty {
                    lines[i].words = [LyricWord(text: "", start: wS, end: wE)]    // dòng Whisper sót
                } else {
                    var tmp = lines[i]; tmp.start = wS; tmp.end = wE
                    lines[i].words = WordTiming.distribute(tmp)                   // SRT: không có mốc chữ
                }
            } else {
                // GIỮ mốc chữ Whisper (NHỊP thật) — chỉ kẹp vào [wS, wE] & ép tăng dần.
                var prev = wS
                for j in lines[i].words.indices {
                    let ws = min(max(lines[i].words[j].start ?? prev, prev), wE)
                    let we = min(max(lines[i].words[j].end ?? ws, ws + 0.03), wE)
                    lines[i].words[j].start = ws
                    lines[i].words[j].end = max(ws, we)
                    prev = max(ws, we)
                }
                lines[i].words[lines[i].words.count - 1].end = wE   // chữ cuối chạm đúng cuối block
            }

            // Mốc HIỂN THỊ (block) — khít với dòng trước / sau.
            let blockStart: TimeInterval
            if k == 0 {
                blockStart = s > preroll ? (s - preroll) : max(0, s - earlyShow)
            } else if s - realE[k - 1] > bigGap {
                blockStart = max(realE[k - 1], s - preroll)
            } else {
                blockStart = max(realS[k - 1], realE[k - 1] - earlyShow)
            }
            let blockEnd: TimeInterval = (k == last) ? e : max(blockStart + 0.3, e - trailingTrim)

            lines[i].start = blockStart
            lines[i].end = max(blockStart + 0.3, blockEnd)
        }
    }

    static func removeOverlaps(lines: inout [LyricLine]) {
        let order = lines.indices
            .filter { lines[$0].isTimed }
            .sorted { (lines[$0].start ?? 0) < (lines[$1].start ?? 0) }
        guard order.count > 1 else { return }
        for k in 1..<order.count {
            let prev = order[k - 1]
            let cur = order[k]
            guard let curStart = lines[cur].start, let prevEnd = lines[prev].end else { continue }
            if prevEnd > curStart {
                lines[prev].end = max(lines[prev].start ?? curStart, curStart)
            }
        }
    }

    // MARK: - Chỉnh tay

    static func nudgeStart(lines: inout [LyricLine], at index: Int, by delta: TimeInterval) {
        guard lines.indices.contains(index) else { return }
        var value = max(0, (lines[index].start ?? 0) + delta)
        if let end = lines[index].end { value = min(value, end) }
        lines[index].start = value
        refreshWords(&lines, at: index)
    }

    static func nudgeEnd(lines: inout [LyricLine], at index: Int, by delta: TimeInterval) {
        guard lines.indices.contains(index) else { return }
        var value = max(0, (lines[index].end ?? lines[index].start ?? 0) + delta)
        if let start = lines[index].start { value = max(value, start) }
        lines[index].end = value
        refreshWords(&lines, at: index)
    }

    static func setStart(lines: inout [LyricLine], at index: Int, to time: TimeInterval) {
        guard lines.indices.contains(index) else { return }
        var value = max(0, time)
        if let end = lines[index].end { value = min(value, end) }
        lines[index].start = value
        refreshWords(&lines, at: index)
    }

    static func setEndTo(lines: inout [LyricLine], at index: Int, to time: TimeInterval) {
        guard lines.indices.contains(index) else { return }
        var value = max(0, time)
        if let start = lines[index].start { value = max(value, start) }
        lines[index].end = value
        refreshWords(&lines, at: index)
    }

    // MARK: - Truy vấn

    /// Dòng đầu tiên chưa gán đủ timing.
    static func firstUntimedIndex(_ lines: [LyricLine]) -> Int? {
        lines.firstIndex { !$0.isTimed }
    }

    /// Dòng đang được hát tại thời điểm `time` (theo timing hiện có).
    static func activeIndex(_ lines: [LyricLine], at time: TimeInterval) -> Int? {
        lines.firstIndex { line in
            guard let start = line.start, let end = line.end else { return false }
            return time >= start && time < end
        }
    }

}
