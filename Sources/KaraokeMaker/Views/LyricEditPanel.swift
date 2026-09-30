import SwiftUI

/// Tab "Sửa lời" — danh sách CỐ ĐỊNH các dòng lời của karaoke (đã sạch tag): chỉ sửa được CHỮ trong
/// từng dòng, không thêm / xoá / đổi thứ tự dòng. Số thứ tự đứng trước mỗi dòng chỉ là chỉ dẫn trên
/// giao diện, KHÔNG nằm trong karaoke.
///
/// Sửa xong (Enter, bấm ra ngoài, hoặc chuyển sang dòng khác) = tự cập nhật thẳng vào karaoke qua
/// `onCommit` (1 bước hoàn tác ⌘Z). Esc = bỏ thay đổi dòng đang sửa.
struct LyricEditPanel: View {
    @EnvironmentObject var store: ProjectStore

    /// Dòng đang chọn (đồng bộ 2 chiều với timeline / preview).
    let currentLineIndex: Int
    /// Bấm vào 1 dòng → chọn dòng đó + đưa vạch đỏ tới đầu dòng (để thấy kết quả ngay trên preview).
    let onFocusLine: (Int) -> Void
    /// Chốt chữ mới cho dòng `id` (ContentView lo phần giữ timing + hoàn tác).
    let onCommit: (UUID, String) -> Void
    /// Từ máy chưa chắc (karaoke tự động) — còn hiệu lực; bấm phương án = thay đúng từ đó (giữ mốc giờ), "Giữ nguyên" = bỏ đánh dấu.
    var uncertain: [AutoUncertainWord] = []
    var onApplyAlternative: (AutoUncertainWord, String) -> Void = { _, _ in }
    var onDismissUncertain: (AutoUncertainWord) -> Void = { _ in }

    @FocusState private var focusedID: UUID?
    /// Dòng ĐANG HÁT theo vạch đỏ (cập nhật bởi `LyricFollowTicker` — chỉ panel này dựng lại, KHÔNG kéo
    /// cả `ContentView` như cách cũ `PlaybackTicks.followCurrentLine` đã phải tắt vì lag Intel).
    @State private var playingIndex: Int?
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var original = ""

    var body: some View {
        let lines = store.project.lines
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(L("Sửa lời")).sectionHeaderStyle()
                Text(L("Sửa chữ trong từng dòng. Bấm Enter hoặc bấm ra ngoài để cập nhật vào karaoke."))
                    .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.m)

            Divider().overlay(Theme.stroke)

            if !uncertain.isEmpty { uncertainSection(lines) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            row(index: i, line: line)
                                .id(line.id)
                        }
                    }
                    .padding(Theme.Space.l)
                }
                .onAppear { scrollToCurrent(proxy, lines) }
                .onChange(of: currentLineIndex) { _ in
                    // Đang gõ thì KHÔNG cuộn (khỏi nhảy mất dòng đang sửa).
                    guard editingID == nil else { return }
                    scrollToCurrent(proxy, store.project.lines)
                }
                .onChange(of: playingIndex) { idx in
                    // Vạch đỏ sang dòng mới → cuộn cho dòng đang hát nằm GIỮA danh sách (đang gõ thì thôi).
                    guard editingID == nil, let idx, store.project.lines.indices.contains(idx) else { return }
                    let id = store.project.lines[idx].id
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LyricFollowTicker(lines: store.project.lines,
                                      clipStart: store.project.karaokeClipStart,
                                      playingIndex: $playingIndex))
        .onChange(of: focusedID) { newID in
            if let e = editingID, e != newID { finishEditing(e) }      // rời dòng cũ → cập nhật
            if let n = newID { beginEditing(n) }
        }
        .onDisappear {                                                  // đổi tab / đóng project khi đang gõ → vẫn lưu
            if let e = editingID { finishEditing(e) }
        }
    }

    /// "Từ máy chưa chắc": mỗi từ 1 hàng — dòng số mấy, từ đang dùng (cam), các phương án khác bấm được, "Giữ nguyên".
    @ViewBuilder private func uncertainSection(_ lines: [LyricLine]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.warning).font(.system(size: 11))
                Text(String(format: L("Từ máy chưa chắc (%d)"), uncertain.count)).font(Theme.Typo.labelStrong)
                Spacer()
            }
            Text(L("Karaoke đã canh giờ xong. Xem các từ dưới đây — chọn phương án đúng, hoặc bỏ qua nếu từ đang dùng đã đúng."))
                .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(uncertain) { u in
                        let idx = lines.firstIndex(where: { $0.id == u.lineID }) ?? 0
                        HStack(spacing: 6) {
                            Button { onFocusLine(idx) } label: { Text("\(idx + 1)").font(.system(size: 11).monospacedDigit()) }
                                .buttonStyle(.link).frame(width: 26, alignment: .trailing)
                            Text(u.original + "?").font(Theme.Typo.labelStrong).foregroundColor(Theme.warning).underline()
                            ForEach(u.alternatives, id: \.self) { alt in
                                Button(alt) { onApplyAlternative(u, alt) }.controlSize(.small)
                            }
                            Button(L("Giữ nguyên")) { onDismissUncertain(u) }.controlSize(.small)
                            if u.kind == .possibleMissing { Text(L("(có thể thiếu từ)")).font(.caption2).foregroundStyle(Theme.inkDim) }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        .background(Theme.warning.opacity(0.06))
        Divider().overlay(Theme.stroke)
    }

    private func row(index i: Int, line: LyricLine) -> some View {
        let isCurrent = i == currentLineIndex
        let isPlaying = i == playingIndex
        let editing = editingID == line.id
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("\(i + 1)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(isCurrent || isPlaying ? Theme.accent : Theme.inkFaint)
                .frame(width: 28, alignment: .trailing)
            if uncertain.contains(where: { $0.lineID == line.id }) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(Theme.warning).help(L("Dòng này có từ máy chưa chắc"))
            }
            TextField("", text: binding(for: line), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 13))
                .focused($focusedID, equals: line.id)
                .onSubmit { commitAndLeave(line.id) }
                .onExitCommand { cancelEditing(line.id) }
                .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
                // Dòng ĐANG HÁT (theo vạch đỏ) = sáng rõ; dòng đang CHỌN = viền nhấn.
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isPlaying ? Theme.accent.opacity(0.30) : (isCurrent ? Theme.accentSoft : Color.white.opacity(0.04))))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(editing ? Theme.accent : (isCurrent ? Theme.accent.opacity(0.45) : Theme.stroke),
                            lineWidth: editing ? 1.5 : 1))
        }
    }

    // MARK: - Trạng thái sửa

    /// Dòng đang sửa đọc/ghi bản NHÁP; các dòng khác luôn đọc thẳng từ karaoke.
    private func binding(for line: LyricLine) -> Binding<String> {
        Binding(
            get: { editingID == line.id ? draft : line.text },
            set: { newValue in
                guard editingID == line.id else { return }
                // Phím Enter có thể chèn xuống dòng thay vì gọi onSubmit → coi như "xong".
                if newValue.contains("\n") || newValue.contains("\r") {
                    draft = newValue.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    commitAndLeave(line.id)
                } else {
                    draft = newValue
                }
            }
        )
    }

    private func beginEditing(_ id: UUID) {
        guard let i = store.project.lines.firstIndex(where: { $0.id == id }) else { return }
        editingID = id
        draft = store.project.lines[i].text
        original = draft
        onFocusLine(i)
    }

    /// Chốt chữ đã sửa của dòng `id` (không đổi gì thì `onCommit` cũng bỏ qua) rồi thôi chế độ sửa.
    private func finishEditing(_ id: UUID) {
        let text = draft
        editingID = nil
        if text != original { onCommit(id, text) }
    }

    private func commitAndLeave(_ id: UUID) {
        guard editingID == id else { return }
        finishEditing(id)
        focusedID = nil
    }

    private func cancelEditing(_ id: UUID) {
        guard editingID == id else { return }
        draft = original
        editingID = nil
        focusedID = nil
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, _ lines: [LyricLine]) {
        guard lines.indices.contains(currentLineIndex) else { return }
        let id = lines[currentLineIndex].id
        DispatchQueue.main.async { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } }
    }
}


/// Theo dõi vạch đỏ cho bảng "Sửa lời": lúc ĐANG PHÁT đọc đồng hồ 4 lần/giây (đồng hồ không phát tín hiệu liên tục),
/// lúc dừng chỉ tính lại khi tua (`seekGeneration`). Chỉ ghi `playingIndex` khi SANG DÒNG KHÁC → panel dựng lại ~1 lần /
/// câu hát; `ContentView` không hề bị kéo theo.
private struct LyricFollowTicker: View {
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var clock: PlaybackClock
    let lines: [LyricLine]
    let clipStart: TimeInterval
    @Binding var playingIndex: Int?

    var body: some View {
        if playback.isPlaying {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in probe }
        } else {
            probe
        }
    }

    private var probe: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { update(clock.seconds) }
            .onChange(of: clock.seconds) { update($0) }
    }

    private func update(_ t: TimeInterval) {
        // t = giờ-timeline → giờ-bài (trừ điểm bắt đầu karaoke), giống `ContentView.playheadSongTime`.
        let idx = TimingEditor.activeIndex(lines, at: max(0, t - clipStart))
        if idx != playingIndex { playingIndex = idx }
    }
}
