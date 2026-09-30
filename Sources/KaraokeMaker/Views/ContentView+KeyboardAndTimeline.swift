import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    func handleKeyDown(_ key: KeyDownMonitor.KeyPress) -> Bool {
        if key.hasCommand, key.character == "z" {
            if key.hasShift {
                store.undoManager.redo()
            } else {
                let name = store.undoManager.undoActionName
                let wasStageDrop = lastStageDrop != nil && (name == L("Thêm chữ") || name == L("Thêm dòng"))
                store.undoManager.undo()
                if wasStageDrop, let p = lastStageDrop {
                    restageItem = p; restageTick += 1; lastStageDrop = nil
                }
            }
            return true
        }

        let timelineFocused: Bool = {
            guard let v = NSApp.keyWindow?.firstResponder as? NSView else { return false }
            return v.identifier?.rawValue == "KMTimelineCanvas"
        }()

        // ⌘C / ⌘V cho CLIP lớp đè — chỉ khi KHÔNG ở trong timeline (timeline tự lo copy dòng lời).
        if key.hasCommand, !key.hasShift, !timelineFocused {
            if key.character == "c", case .overlay = editorSelection {
                return runCommand(.copySelection)
            }
            if key.character == "v", copiedOverlay != nil {
                return runCommand(.pasteClip)
            }
        }
        guard !key.hasCommandOptionControl else { return false }

        switch key.character {
        case " ": return runCommand(.playPause)
        // T / Y (canh giờ thủ công) đã bỏ — sẽ gán phím mới khi làm lại chế độ thủ công.
        case "[": return runCommand(.prevLine)
        case "]": return runCommand(.nextLine)
        case "\u{f702}":                             // ← : tua lùi
            if timelineFocused { return false }      // canvas tự lo nudge dòng lời khi focus
            return runCommand(.seekBy(key.hasShift ? -1.0 : -0.1))
        case "\u{f703}":                             // → : tua tới
            if timelineFocused { return false }
            return runCommand(.seekBy(key.hasShift ? 1.0 : 0.1))
        case ",", "<": return runCommand(.nudgeSelection(-0.1))   // dời mục đang chọn
        case ".", ">": return runCommand(.nudgeSelection(0.1))
        case "\u{7f}", "\u{8}", "\u{f728}":   // Delete / Backspace / Forward-delete
            if case .overlay = editorSelection {
                return runCommand(.deleteSelection)   // đang chọn ảnh/logo → xoá nó
            }
            if timelineFocused { return false }        // đang chọn 1 ô chữ → để timeline xoá chữ đó
            return runCommand(.deleteSelection)        // xoá timing dòng đang chọn
        case "r" where key.hasShift: clearAllTiming(); return true
        default: return false
        }
    }

    func endNameEditing() {
        isNameFieldFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func defocusTextEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: - Hành động timing

    func clampedIndex(_ index: Int) -> Int {
        min(max(index, 0), max(store.project.lines.count - 1, 0))
    }

    /// Bấm T — vào câu, sang dòng kế.
    func markTap() {
        guard !store.project.lines.isEmpty else { return }
        clearedTimingBackup = nil
        let tapped = clampedIndex(currentLineIndex)
        var newIndex = currentLineIndex
        store.perform(L("Vào câu")) {
            newIndex = TimingEditor.tap(
                lines: &store.project.lines,
                at: tapped,
                time: playheadSongTime,
                leadIn: store.project.tapLeadIn
            )
        }
        currentLineIndex = clampedIndex(newIndex)

        // Dòng vừa bấm T có bắt đầu nhưng chưa có kết thúc -> chờ T kế;
        // nếu quá lâu (tapTimeoutSeconds) mà không bấm T thì tự reset dòng đó.
        if store.project.lines.indices.contains(tapped),
           store.project.lines[tapped].start != nil,
           store.project.lines[tapped].end == nil {
            pendingTapLine = tapped
            pendingTapDeadline = playback.currentTime + tapTimeoutSeconds
        } else {
            clearPendingTap()
        }
    }

    /// Bấm Y — chốt (tạm) điểm kết thúc của câu đang ghi dở.
    func markEndOfLine() {
        let target = pendingTapLine
            ?? store.project.lines.firstIndex { $0.start != nil && $0.end == nil }
        guard let index = target, store.project.lines.indices.contains(index) else { return }
        store.perform(L("Kết thúc câu")) {
            TimingEditor.setEnd(lines: &store.project.lines, at: index, time: playheadSongTime)
        }
        clearPendingTap()
    }

    func moveCurrentLine(_ delta: Int) {
        currentLineIndex = clampedIndex(currentLineIndex + delta)
        clearPendingTap()
    }

    func jumpToFirstUntimed() {
        if let index = TimingEditor.firstUntimedIndex(store.project.lines) {
            currentLineIndex = index
        }
    }

    func listenFromCurrentLine() {
        let index = clampedIndex(currentLineIndex)
        guard store.project.lines.indices.contains(index) else { return }
        // `target` = giây TRONG BÀI; tua playback (giờ-timeline) = target + mốc clip ★.
        let target = store.project.lines[index].start ?? playheadSongTime
        playback.seek(to: max(0, target - 0.5) + store.project.karaokeClipStart)
        playback.play()
    }

    /// Tab "Sửa lời" — có dòng canh xong rồi thì KHÔNG quay lại "Tạo Karaoke" nữa
    /// (trừ lúc đang đứng ở đó: vừa tạo xong, chờ tự chuyển sang "Nền video").
    /// Tab "Tạo Karaoke" LUÔN hiện (chủ dự án 2026-09-29) — không còn biến mất sau khi canh xong.
    var showStepsTab: Bool { true }
    /// Được bấm tạo karaoke (nhanh / chất lượng / không cần lời)?
    var canCreateKaraoke: Bool { !aiLinesTimed || karaokeInputChanged }

    /// Bấm vào 1 dòng ở tab "Sửa lời": chọn dòng + đưa vạch đỏ tới đầu dòng (KHÔNG tự phát nhạc).
    func focusLyricLine(_ index: Int) {
        guard store.project.lines.indices.contains(index) else { return }
        currentLineIndex = index
        if let start = store.project.lines[index].start {
            playback.seek(to: start + store.project.karaokeClipStart)
        }
    }

    /// Chốt chữ mới của 1 dòng (tab "Sửa lời" + ô "Nội dung dòng"): dựng lại các ô chữ, GIỮ timing,
    /// 1 bước hoàn tác. Chữ rỗng / không đổi → bỏ qua (không bao giờ xoá dòng).
    func commitLyricEdit(_ id: UUID, _ raw: String) {
        guard let i = store.project.lines.firstIndex(where: { $0.id == id }),
              let updated = LyricLineEditor.apply(raw, to: store.project.lines[i]) else { return }
        store.perform(L("Sửa lời dòng")) { store.project.lines[i] = updated }
    }

    func seekToLineStart(_ index: Int) {
        guard store.project.lines.indices.contains(index),
              let start = store.project.lines[index].start else { return }
        playback.seek(to: start + store.project.karaokeClipStart)   // start = giây trong bài
        playback.play()
    }


    func nudgeStart(_ index: Int, _ delta: Double) {
        store.perform(L("Chỉnh điểm bắt đầu")) {
            TimingEditor.nudgeStart(lines: &store.project.lines, at: index, by: delta)
        }
    }

    func nudgeEnd(_ index: Int, _ delta: Double) {
        store.perform(L("Chỉnh điểm kết thúc")) {
            TimingEditor.nudgeEnd(lines: &store.project.lines, at: index, by: delta)
        }
    }

    func setStartToPlayhead(_ index: Int) {
        store.perform(L("Đặt điểm bắt đầu")) {
            TimingEditor.setStart(lines: &store.project.lines, at: index, to: playheadSongTime)
        }
    }

    func setEndToPlayhead(_ index: Int) {
        store.perform(L("Đặt điểm kết thúc")) {
            TimingEditor.setEndTo(lines: &store.project.lines, at: index, to: playheadSongTime)
        }
    }

    func setLineStartTime(_ index: Int, _ time: TimeInterval) {
        store.perform(L("Sửa điểm bắt đầu")) {
            TimingEditor.setStart(lines: &store.project.lines, at: index, to: time)
        }
    }

    func setLineEndTime(_ index: Int, _ time: TimeInterval) {
        store.perform(L("Sửa điểm kết thúc")) {
            TimingEditor.setEndTo(lines: &store.project.lines, at: index, to: time)
        }
    }

    func clearLine(_ index: Int) {
        store.perform(L("Xoá timing dòng")) {
            TimingEditor.clear(lines: &store.project.lines, at: index)
        }
        clearPendingTap()
    }

    func setLineText(_ index: Int, _ newText: String) {
        guard store.project.lines.indices.contains(index) else { return }
        store.edit(L("Sửa lời dòng")) { store.project.lines[index].text = newText }
    }

    func timelineApplyChanges(_ changes: [(Int, Double, Double)]) {
        store.perform(L("Kéo dòng trên timeline")) {
            for (index, newStart, newEnd) in changes {
                guard store.project.lines.indices.contains(index) else { continue }
                let oldS = store.project.lines[index].start ?? newStart
                let oldE = store.project.lines[index].end ?? newEnd
                let start = max(0, newStart)
                let end = max(start + 0.05, newEnd)
                let dS = start - oldS, dE = end - oldE

                // DỜI cả câu (2 mép nhích cùng lượng) → chữ đi theo.
                // KÉO 1 MÉP (chỉ 1 đầu đổi) → chữ ĐỨNG YÊN, chỉ phần chờ đầu / đuôi dài ra.
                if abs(dS - dE) < 0.001 {
                    for j in store.project.lines[index].words.indices {
                        if let ws = store.project.lines[index].words[j].start {
                            store.project.lines[index].words[j].start = max(0, ws + dS)
                        }
                        if let we = store.project.lines[index].words[j].end {
                            store.project.lines[index].words[j].end = max(0, we + dS)
                        }
                    }
                    store.project.lines[index].start = start
                    store.project.lines[index].end = end
                } else {
                    // Kéo 1 mép: KHÔNG để mép cắt vào chữ (chữ luôn nằm trong khối).
                    let fw = store.project.lines[index].words.first?.start
                    let lw = store.project.lines[index].words.last?.end
                    store.project.lines[index].start = min(start, fw ?? start)
                    store.project.lines[index].end = max(end, lw ?? end)
                }
            }
        }
    }

    // MARK: - Sửa CHỮ trực quan trên timeline (chỉ đổi words + text)

    /// Double-click phần DÒNG → rải lời mới vào các ô chữ ĐANG CÓ, giữ nguyên mốc timing.
    /// Đúng số chữ → thay 1-1. Dư chữ → gộp phần dư vào ô CUỐI. Thiếu → ô cuối để trống.
    func timelineLineTextRemap(_ i: Int, _ raw: String) {
        guard store.project.lines.indices.contains(i) else { return }
        let toks = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\u{a0}" })
            .map(String.init)
        store.perform(L("Sửa lời dòng")) {
            var l = store.project.lines[i]
            if l.words.isEmpty {
                l.text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let n = l.words.count
                for k in 0..<n {
                    if k < n - 1 {
                        l.words[k].text = k < toks.count ? toks[k] : ""
                    } else {                                   // ô CUỐI: nuốt hết phần dư
                        l.words[k].text = toks.count > k ? toks[k...].joined(separator: " ") : ""
                    }
                }
                l.text = l.words.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            }
            store.project.lines[i] = l
        }
    }

    func timelineWordsCommit(_ i: Int, _ words: [LyricWord], _ text: String) {
        guard store.project.lines.indices.contains(i) else { return }
        store.perform(L("Sửa chữ trên timeline")) {
            store.project.lines[i].words = words
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                store.project.lines[i].text = text
            }
            if let ws = words.first?.start, ws < (store.project.lines[i].start ?? ws) {
                store.project.lines[i].start = max(0, ws)
            }
            if let we = words.last?.end, we > (store.project.lines[i].end ?? we) {
                store.project.lines[i].end = we
            }
        }
    }

    func timelineRedistributeWords(_ i: Int) {
        guard store.project.lines.indices.contains(i), !store.project.lines[i].words.isEmpty else { return }
        store.perform(L("Chia đều chữ")) {
            var l = store.project.lines[i]
            var tmp = l
            tmp.start = l.words.first?.start ?? l.start
            tmp.end = l.words.last?.end ?? l.end
            l.words = WordTiming.distribute(tmp)
            store.project.lines[i] = l
        }
    }

    /// Thêm 1 chữ RỖNG ~1 giây tại vạch đỏ (playhead), CHÈN vào câu `i` (không tạo câu mới).
    /// Kéo ô chữ TẠM thả vào dòng `li` tại [s,e]. Chèn thành chữ mới, đẩy/thu hàng xóm.
    func timelineStageWordDrop(_ li: Int, _ s: Double, _ e: Double, _ text: String) {
        guard store.project.lines.indices.contains(li) else { return }
        store.perform(L("Thêm chữ")) {
            var l = store.project.lines[li]
            var ws = l.words
            let at = ws.firstIndex { ($0.start ?? .greatestFiniteMagnitude) > s } ?? ws.count
            var ns = max(0, s), ne = max(ns + 0.08, e)
            let m = 0.08
            if at > 0, let pe = ws[at - 1].end, ns < pe {                 // đè chữ trước → thu nó
                let pmin = (ws[at - 1].start ?? 0) + m
                ws[at - 1].end = max(pmin, ns)
                if ns < pmin { ns = pmin; ne = max(ne, ns + 0.08) }
            }
            if at < ws.count, let nsx = ws[at].start, ne > nsx {          // đè chữ sau → thu nó
                let nmax = (ws[at].end ?? nsx) - m
                ws[at].start = min(nmax, ne)
                if ne > nmax { ne = nmax; ns = min(ns, ne - 0.08) }
            }
            ws.insert(LyricWord(text: text.isEmpty ? "…" : text, start: ns, end: ne), at: at)
            l.words = ws
            l.start = min(l.start ?? ns, ws.first?.start ?? ns)
            l.end = max(l.end ?? ne, ws.last?.end ?? ne)
            l.text = ws.map(\.text).joined(separator: " ")
            store.project.lines[li] = l
        }
        lastStageDrop = .init(isLine: false, start: s, end: e,
                              text: text.isEmpty ? "…" : text, words: [])
    }

    /// Kéo DÒNG TẠM thả xuống track chính tại [s,e] với các chữ đã chia đều.
    func timelineStageLineDrop(_ s: Double, _ e: Double, _ words: [LyricWord], _ text: String) {
        store.perform(L("Thêm dòng")) {
            var line = LyricLine(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                 start: max(0, s), end: max(s + 0.2, e), source: .auto)
            line.words = words
            store.project.lines.append(line)
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        currentLineIndex = store.project.lines.firstIndex { abs(($0.start ?? -1) - s) < 0.01 } ?? currentLineIndex
        lastStageDrop = .init(isLine: true, start: s, end: e, text: text, words: words)
    }

    /// Thêm 1 ô chữ "…" vào dòng `i` ĐÚNG chỗ playhead (vạch đỏ). Rộng ~0.4s.
    /// KHÔNG chồng chữ khác, KHÔNG tràn ra ngoài dòng — kẹt vào khe giữa 2 chữ hàng xóm.
    func timelineAddWordAtPlayhead(_ i: Int) {
        guard store.project.lines.indices.contains(i) else { return }
        let T = playheadSongTime
        store.perform(L("Thêm chữ")) {
            var l = store.project.lines[i]
            var ws = l.words

            // Chèn TRƯỚC chữ đầu tiên bắt đầu sau playhead.
            let at = ws.firstIndex { ($0.start ?? .greatestFiniteMagnitude) > T } ?? ws.count
            let leftBound = at > 0
                ? (ws[at - 1].end ?? ws[at - 1].start ?? 0)
                : max(0, l.start ?? T)
            let rightBound = at < ws.count
                ? (ws[at].start ?? .greatestFiniteMagnitude)
                : max((l.end ?? T + 0.5), leftBound + 0.5)

            var s = min(max(T, leftBound), rightBound)
            var e = min(s + 0.4, rightBound)
            if e - s < 0.08 {                       // khe hẹp → lùi start để đủ 0.15s tối thiểu
                s = max(leftBound, rightBound - 0.15)
                e = max(rightBound, s + 0.08)
            }
            ws.insert(LyricWord(text: "…", start: s, end: e), at: at)

            l.words = ws
            l.start = min(l.start ?? s, ws.first?.start ?? s)
            l.end = max(l.end ?? e, ws.last?.end ?? e)
            l.text = ws.map { $0.text }.joined(separator: " ")
            store.project.lines[i] = l
        }
    }

    /// Thêm 1 câu MỚI 5 giây tại `t`. Chỉ nhích mép 2 block hàng xóm bị đè;
    /// KHÔNG chạy lại canh giờ, KHÔNG đụng chữ/nhịp câu khác.
    func timelineAddLine(_ t: Double) {
        let d = 5.0
        let T = max(0, t)
        let newLine = LyricLine(text: "", start: T, end: T + d, source: .auto)
        let newID = newLine.id
        store.perform(L("Thêm câu mới")) {
            var ls = store.project.lines
            for i in ls.indices {
                guard let s = ls[i].start, let e = ls[i].end else { continue }
                // Chỉ NHÍCH MÉP block hàng xóm, KHÔNG đụng words của chúng.
                if s <= T && e > T + 0.05 { ls[i].end = max(s + 0.1, T) }          // phủ T → cắt end
                if s >= T && s < T + d {
                    if e <= T + d {                                                // nằm gọn → dời hẳn
                        let sh = (T + d) - s
                        ls[i].start = s + sh; ls[i].end = e + sh
                        ls[i].words = shiftWords(ls[i].words, by: sh)
                    } else {
                        ls[i].start = T + d                                        // ló đuôi → đẩy start
                    }
                }
            }
            ls.append(newLine)
            ls.sort { ($0.start ?? 0) < ($1.start ?? 0) }
            store.project.lines = ls
        }
        if let idx = store.project.lines.firstIndex(where: { $0.id == newID }) {
            currentLineIndex = idx
            seekTo(T + store.project.karaokeClipStart)   // T = giây trong bài → giờ-timeline
        }
    }

    func shiftWords(_ words: [LyricWord], by d: Double) -> [LyricWord] {
        words.map { var w = $0; if let s = w.start { w.start = s + d }; if let e = w.end { w.end = e + d }; return w }
    }

    /// Dán lời (clipboard) cho câu `i` → chia đều mốc cho từng chữ (CHỈ câu này).
    func timelinePasteLine(_ i: Int) {
        guard store.project.lines.indices.contains(i),
              let s = store.project.lines[i].start, let e = store.project.lines[i].end else { return }
        let raw = NSPasteboard.general.string(forType: .string) ?? ""
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { store.lastError = L("Clipboard trống — hãy copy lời trước."); return }
        store.perform(L("Dán lời câu mới")) {
            var l = store.project.lines[i]
            l.text = clean
            var tmp = l; tmp.start = s; tmp.end = e
            l.words = WordTiming.distribute(tmp)
            store.project.lines[i] = l
        }
    }

    // MARK: - Timeline P1: chọn nhiều · dời · xoá · copy/paste · nhân bản · nudge

    /// Bản sao 1 câu, DỜI toàn bộ mốc theo `d` giây, cấp `id` mới.
    func shiftedCopy(_ src: LyricLine, by d: Double) -> LyricLine {
        var l = LyricLine(text: src.text,
                          start: src.start.map { max(0, $0 + d) },
                          end: src.end.map { max(0.05, $0 + d) },
                          source: src.source)
        l.words = src.words.map {
            var w = $0
            if let s = w.start { w.start = max(0, s + d) }
            if let e = w.end { w.end = max(0, e + d) }
            return w
        }
        return l
    }

    /// Dời nhiều block cùng lúc (kéo thân). Mỗi phần tử: (id, startMới, endMới).
    func timelineMoveLines(_ changes: [(UUID, Double, Double)]) {
        guard !changes.isEmpty else { return }
        store.perform(L("Dời câu trên timeline")) {
            for (id, ns, ne) in changes {
                guard let i = store.project.lines.firstIndex(where: { $0.id == id }) else { continue }
                let oldS = store.project.lines[i].start ?? ns
                let dS = max(0, ns) - oldS
                store.project.lines[i].start = max(0, ns)
                store.project.lines[i].end = max(max(0, ns) + 0.05, ne)
                store.project.lines[i].words = shiftWords(store.project.lines[i].words, by: dS)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        syncSelectionIndex()
    }

    func timelineDeleteLines(_ ids: [UUID]) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        store.perform(L("Xoá câu")) {
            store.project.lines.removeAll { set.contains($0.id) }
        }
        currentLineIndex = min(currentLineIndex, max(0, store.project.lines.count - 1))
    }

    func timelineCopyLines(_ ids: [UUID]) {
        let set = Set(ids)
        let picked = store.project.lines.filter { set.contains($0.id) }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        guard !picked.isEmpty else { return }
        timelineClipboard = picked
    }

    /// Dán clipboard tại vạch đỏ, GIỮ khoảng cách tương đối giữa các câu đã copy.
    func timelinePasteAtPlayhead() {
        guard !timelineClipboard.isEmpty else {
            store.lastError = L("Chưa copy câu nào (chọn câu rồi ⌘C)."); return
        }
        let base = timelineClipboard.first?.start ?? 0
        let shift = playheadSongTime - base
        var newIDs: [UUID] = []
        store.perform(L("Dán câu")) {
            for src in timelineClipboard {
                let l = shiftedCopy(src, by: shift)
                newIDs.append(l.id)
                store.project.lines.append(l)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        if let first = newIDs.first,
           let idx = store.project.lines.firstIndex(where: { $0.id == first }) {
            currentLineIndex = idx
        }
    }

    /// Nhân bản: đặt bản sao ngay SAU nhóm đang chọn.
    func timelineDuplicateLines(_ ids: [UUID]) {
        let set = Set(ids)
        let picked = store.project.lines.filter { set.contains($0.id) }
            .sorted { ($0.start ?? 0) < ($1.start ?? 0) }
        guard let firstS = picked.first?.start, let lastE = picked.last?.end else { return }
        let shift = (lastE - firstS) + 0.3
        var newIDs: [UUID] = []
        store.perform(L("Nhân bản câu")) {
            for src in picked {
                let l = shiftedCopy(src, by: shift)
                newIDs.append(l.id)
                store.project.lines.append(l)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        if let first = newIDs.first,
           let idx = store.project.lines.firstIndex(where: { $0.id == first }) {
            currentLineIndex = idx
        }
    }

    /// ← → : dời sớm/trễ các câu đang chọn (Shift = 0.5s, thường = 0.1s).
    func timelineNudgeLines(_ ids: [UUID], _ d: Double) {
        let set = Set(ids)
        guard !set.isEmpty else { return }
        store.perform(d < 0 ? L("Dời sớm") : L("Dời trễ")) {
            for i in store.project.lines.indices where set.contains(store.project.lines[i].id) {
                guard let s = store.project.lines[i].start else { continue }
                let dd = max(d, -s)
                store.project.lines[i].start = s + dd
                if let e = store.project.lines[i].end { store.project.lines[i].end = e + dd }
                store.project.lines[i].words = shiftWords(store.project.lines[i].words, by: dd)
            }
            store.project.lines.sort { ($0.start ?? 0) < ($1.start ?? 0) }
        }
        syncSelectionIndex()
    }

    func syncSelectionIndex() {
        guard store.project.lines.indices.contains(currentLineIndex) else {
            currentLineIndex = max(0, store.project.lines.count - 1); return
        }
    }

    /// P3: kéo mốc BẮT ĐẦU từng chữ của câu `i` về nhịp giọng hát dò được (onset).
    /// Dùng bản vocal đã tách nếu có, không thì bản gốc. End nối tiếp start chữ sau.
    func timelineSnapWordsToOnset(_ i: Int) {
        guard store.project.lines.indices.contains(i) else { return }
        let line = store.project.lines[i]
        guard !line.words.isEmpty, let s = line.start, let e = line.end, e > s else { return }
        guard let url = beatSepProxy.vocalURL ?? resolvedAudioURL else {
            store.lastError = L("Chưa có file audio/vocal để dò nhịp."); return
        }
        let n = line.words.count
        timelineSnapBusy = true
        Task.detached {
            let hits = AudioOnsetDetector.onsets(url: url, start: s - 0.35, end: e + 0.35,
                                                 maxCount: max(8, n * 3))
            await MainActor.run {
                timelineSnapBusy = false
                guard hits.count >= 2 else {
                    store.lastError = L("Không dò đủ nhịp trong đoạn câu này (nhạc to / giọng nhỏ).")
                    return
                }
                guard store.project.lines.indices.contains(i),
                      store.project.lines[i].words.count == n else { return }
                store.perform(L("Khớp chữ vào nhịp")) {
                    var w = store.project.lines[i].words
                    for k in w.indices {
                        guard let ws = w[k].start else { continue }
                        if let near = hits.min(by: { abs($0 - ws) < abs($1 - ws) }),
                           abs(near - ws) < 0.45 {
                            w[k].start = near
                        }
                    }
                    // ép tăng dần + end chữ = start chữ kế
                    for k in w.indices {
                        if k > 0, let ps = w[k - 1].start, let cs = w[k].start, cs <= ps + 0.03 {
                            w[k].start = ps + 0.06
                        }
                        if k > 0 { w[k - 1].end = w[k].start }
                    }
                    if let lastS = w.last?.start { w[w.count - 1].end = max(lastS + 0.06, e) }
                    if let f = w.first?.start, f < (store.project.lines[i].start ?? f) {
                        store.project.lines[i].start = max(0, f)
                    }
                    store.project.lines[i].words = w
                }
            }
        }
    }

    func clearAllTiming() {
        guard store.project.hasAnyTiming else { return }
        clearedTimingBackup = store.project.lines
        store.perform(L("Reset toàn bộ timing")) {
            TimingEditor.clearAll(lines: &store.project.lines)
        }
    }

    func restoreClearedTiming() {
        guard let backup = clearedTimingBackup else { return }
        store.perform(L("Hoàn tác xoá timing")) {
            store.project.lines = backup
        }
        clearedTimingBackup = nil
    }
}
