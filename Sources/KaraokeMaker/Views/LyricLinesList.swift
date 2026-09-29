import SwiftUI

/// Danh sách dòng lời. Bấm 1 dòng để chọn — dòng đang chọn bung ra ô sửa
/// LỜI (text) và THỜI GIAN (bắt đầu / kết thúc) ngay tại đây.
/// Cuộn dòng đang chọn lên gần đỉnh khi bật "theo".
struct LyricLinesList: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var playback: PlaybackController

    let currentLineIndex: Int

    let onSelect: (Int) -> Void
    let onSeekToLineStart: (Int) -> Void
    let onClearLine: (Int) -> Void
    let onClearAll: () -> Void
    let canUndoClearAll: Bool
    let onUndoClearAll: () -> Void

    // Sửa trực tiếp trong danh sách (dòng đang chọn).
    var onSetText: (Int, String) -> Void = { _, _ in }
    var onSetStart: (Int, TimeInterval) -> Void = { _, _ in }
    var onSetEnd: (Int, TimeInterval) -> Void = { _, _ in }
    var onNudgeStart: (Int, Double) -> Void = { _, _ in }
    var onNudgeEnd: (Int, Double) -> Void = { _, _ in }
    var onStartToPlayhead: (Int) -> Void = { _ in }
    var onEndToPlayhead: (Int) -> Void = { _ in }

    @State private var followScroll = true

    var body: some View {
        let lines = store.project.lines

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L("Dòng lời")).font(.headline)
                Text("\(lines.count)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                Spacer()
                Toggle(isOn: $followScroll) { Image(systemName: "arrow.down.circle") }
                    .toggleStyle(.button).buttonStyle(.borderless)
                    .help(L("Cuộn theo dòng đang chọn"))
                if canUndoClearAll {
                    Button { onUndoClearAll() } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help(L("Hoàn tác reset timing"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Button(role: .destructive) { onClearAll() } label: {
                Label(L("Reset toàn bộ timing"), systemImage: "trash").frame(maxWidth: .infinity)
            }
            .disabled(!store.project.hasAnyTiming)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Divider()

            if lines.isEmpty {
                Text(L("Chưa có dòng lời. Nhập lời ở trên rồi bấm \"Tách thành dòng\"."))
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(14)
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                                row(index: index, line: line).id(line.id)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: currentLineIndex) { i in scroll(proxy, to: i) }
                    .onAppear { scroll(proxy, to: currentLineIndex) }
                }
            }
        }
    }

    private func row(index: Int, line: LyricLine) -> some View {
        let isSelected = currentLineIndex == index

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text.replacingOccurrences(of: "\n", with: "  /  "))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text(timeLabel(line))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.isTimed ? .secondary : Color.orange)
                        if line.isTimed {
                            Button(L("reset timing")) { onClearLine(index) }
                                .buttonStyle(.borderless).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                Spacer(minLength: 4)

                Button { onSeekToLineStart(index) } label: { Image(systemName: "play.fill").font(.caption) }
                    .buttonStyle(.borderless)
                    .disabled(line.start == nil || !playback.isLoaded)
                    .opacity(line.start == nil ? 0.2 : 1)
            }

            if isSelected { editor(index: index, line: line) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Theme.accent.opacity(0.14) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }

    /// Ô sửa lời + thời gian cho dòng đang chọn.
    @ViewBuilder
    private func editor(index: Int, line: LyricLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            Text(L("Lời dòng")).font(.caption2).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { line.text },
                set: { onSetText(index, $0) }
            ))
            .font(.callout)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46, maxHeight: 110)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.strokeStrong))

            timeRow(L("Bắt đầu"), seconds: line.start,
                    set: { onSetStart(index, $0) },
                    nudge: { onNudgeStart(index, $0) },
                    toPlayhead: { onStartToPlayhead(index) })

            timeRow(L("Kết thúc"), seconds: line.end,
                    set: { onSetEnd(index, $0) },
                    nudge: { onNudgeEnd(index, $0) },
                    toPlayhead: { onEndToPlayhead(index) })
        }
        .padding(.top, 2)
    }

    private func timeRow(_ title: String, seconds: TimeInterval?,
                        set: @escaping (TimeInterval) -> Void,
                        nudge: @escaping (Double) -> Void,
                        toPlayhead: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            TimeField(seconds: seconds, onCommit: set)
            Button("−0.05") { nudge(-0.05) }
            Button("+0.05") { nudge(0.05) }
            Button { toPlayhead() } label: { Image(systemName: "smallcircle.filled.circle") }
                .help(L("Lấy mốc = chỗ đang phát"))
                .disabled(!playback.isLoaded)
            Spacer()
        }
        .controlSize(.small)
        .font(.caption2)
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        guard followScroll, store.project.lines.indices.contains(index) else { return }
        let id = store.project.lines[index].id
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0.14))
            }
        }
    }

    private func timeLabel(_ line: LyricLine) -> String {
        guard let start = line.start, let end = line.end else {
            if let start = line.start { return "\(TimeFormatting.precise(start)) → ?" }
            return L("chưa gán timing")
        }
        return "\(TimeFormatting.precise(start)) → \(TimeFormatting.precise(end))"
    }
}
