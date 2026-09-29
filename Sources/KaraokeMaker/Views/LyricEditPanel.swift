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
    @State private var editingID: UUID?
    @State private var draft = ""
    @State private var original = ""

    var body: some View {
        let lines = store.project.lines
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Sửa lời")).font(.headline)
                Text(L("Sửa chữ trong từng dòng. Bấm Enter hoặc bấm ra ngoài để cập nhật vào karaoke."))
                    .font(.caption).foregroundStyle(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Metric.pad)
            .padding(.top, Theme.Metric.pad)
            .padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            if !uncertain.isEmpty { uncertainSection(lines) }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                            row(index: i, line: line)
                                .id(line.id)
                        }
                    }
                    .padding(Theme.Metric.pad)
                }
                .onAppear { scrollToCurrent(proxy, lines) }
                .onChange(of: currentLineIndex) { _ in
                    // Đang gõ thì KHÔNG cuộn (khỏi nhảy mất dòng đang sửa).
                    guard editingID == nil else { return }
                    scrollToCurrent(proxy, store.project.lines)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
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
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.system(size: 11))
                Text(String(format: L("Từ máy chưa chắc (%d)"), uncertain.count)).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(L("Karaoke đã canh giờ xong. Xem các từ dưới đây — chọn phương án đúng, hoặc bỏ qua nếu từ đang dùng đã đúng."))
                .font(.caption2).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(uncertain) { u in
                        let idx = lines.firstIndex(where: { $0.id == u.lineID }) ?? 0
                        HStack(spacing: 6) {
                            Button { onFocusLine(idx) } label: { Text("\(idx + 1)").font(.system(size: 11).monospacedDigit()) }
                                .buttonStyle(.link).frame(width: 26, alignment: .trailing)
                            Text(u.original + "?").font(.system(size: 12, weight: .semibold)).foregroundColor(.orange).underline()
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
        .padding(.horizontal, Theme.Metric.pad).padding(.vertical, 8)
        .background(Color.orange.opacity(0.06))
        Divider().overlay(Theme.stroke)
    }

    private func row(index i: Int, line: LyricLine) -> some View {
        let isCurrent = i == currentLineIndex
        let editing = editingID == line.id
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(i + 1)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.accent : Theme.inkDim)
                .frame(width: 28, alignment: .trailing)
            if uncertain.contains(where: { $0.lineID == line.id }) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.orange).help(L("Dòng này có từ máy chưa chắc"))
            }
            TextField("", text: binding(for: line), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 13))
                .focused($focusedID, equals: line.id)
                .onSubmit { commitAndLeave(line.id) }
                .onExitCommand { cancelEditing(line.id) }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(isCurrent ? Theme.accentSoft : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 7)
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
