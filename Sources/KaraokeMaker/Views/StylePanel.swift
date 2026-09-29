import SwiftUI
import AppKit

/// Danh sách font cho `StylePanel` — tách RA NGOÀI struct generic (Swift không cho `static let`
/// trong generic type) và để mức FILE (tính 1 LẦN, lười, cho cả vòng đời app — global `let` Swift
/// vốn đã có bảo đảm khởi tạo đúng 1 lần, an toàn luồng).
///
/// `StylePanel<AfterContent>` là 1 SwiftUI View struct, dựng lại MỖI LẦN cha nó vẽ lại (nhiều
/// lần/giây lúc phát) — trước đây khoản này là 1 property `let` THƯỜNG trong struct đó, nghĩa là
/// `NSFontManager.availableFontFamilies` + `sorted()` (liệt kê/sắp TOÀN BỘ font hệ thống, khá
/// chậm) bị GỌI LẠI mỗi lần dựng. Trên máy Intel cũ việc này lặp lại liên tục trong lúc phát góp
/// phần đáng kể vào cảm giác giật/lag (đo được qua `sample` lúc user báo "lag nặng" 2026-09-13).
private let stylePanelFontFamilies: [String] = {
    let recommended = ["Be Vietnam Pro", "Montserrat", "Roboto", "Noto Sans",
                       "SVN-Gilroy", "UTM Avo", "iCiel", "Helvetica Neue", "Arial", "SF Pro"]
    let all = NSFontManager.shared.availableFontFamilies.sorted()
    let present = recommended.filter { all.contains($0) }
    return present + (present.isEmpty ? [] : ["—"]) + all
}()

/// Bảng Style (Inspector › "Chữ").
/// - "Kiểu chữ": 1 khối gộp (font, màu, viền, bóng, glow, nền) cho CÂU CHÍNH.
/// - "Nhắc câu tiếp theo": bật/tắt + khoảng cách + một khối "Kiểu chữ" RIÊNG cho
///   câu nhắc, độc lập hoàn toàn với câu chính (`project.nextLineStyle`).
struct StylePanel<AfterContent: View>: View {
    @EnvironmentObject var store: ProjectStore
    @EnvironmentObject var stylePresets: StylePresetStore
    @EnvironmentObject var playback: PlaybackController
    @ObservedObject private var kfClip = KeyframeClipboard.shared
    @State private var lineDraft = ""
    @State private var lineDraftID: UUID?
    @FocusState private var lineFieldFocused: Bool

    let currentLineIndex: Int
    /// Chốt chữ mới của 1 dòng (giữ timing + hoàn tác) — CÙNG đường với tab "Sửa lời".
    var onCommitLineText: (UUID, String) -> Void = { _, _ in }
    /// View chèn ngay dưới ô "Nội dung dòng" (ContentView truyền "Chỉnh lại thời gian").
    @ViewBuilder var afterContent: () -> AfterContent

    enum Target { case main, next }

    /// Tab của bảng "Chữ" karaoke — chia nhỏ thay vì 1 cột dài kéo.
    private enum MainTab: String, CaseIterable {
        case style, layout
        var label: String { self == .style ? "Kiểu chữ" : "Bố cục" }
        var icon: String { self == .style ? "paintbrush" : "square.grid.2x2" }
    }
    @State private var mainTab: MainTab = .style
    @State private var showFontPicker = false
    @State private var fontSearch = ""

    private func styleValue(_ t: Target) -> KaraokeStyle {
        t == .main ? store.project.style : store.project.nextLineStyle
    }

    private var fontFamilies: [String] { stylePanelFontFamilies }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                contentSection
                afterContent()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Picker("", selection: $mainTab) {
                ForEach(MainTab.allCases, id: \.self) { t in
                    Label(L(t.label), systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 14).padding(.bottom, 8)

            Divider().overlay(Theme.stroke)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch mainTab {
                    case .style:
                        presetRow
                        Divider()
                        lookGroup(.main)
                    case .layout:
                        layoutControls(.main)
                    }
                }
                .padding(14)
            }
        }
    }

    // MARK: - Nội dung dòng

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Nội dung dòng")).font(.headline)
                Spacer()
                if store.project.lines.indices.contains(currentLineIndex) {
                    Text(String(format: L("Dòng %d/%d"), currentLineIndex + 1, store.project.lines.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.project.lines.indices.contains(currentLineIndex) {
                // (2026-09-24) Sửa NHÁP, chốt khi rời ô (bấm ra ngoài) qua `onCommitLineText` — TRƯỚC đây
                // ghi thẳng `text` từng phím: dòng đã canh từng chữ thì karaoke (vẽ theo `words`) KHÔNG đổi.
                TextEditor(text: Binding(
                    get: {
                        guard store.project.lines.indices.contains(currentLineIndex) else { return "" }
                        return lineFieldFocused ? lineDraft : store.project.lines[currentLineIndex].text
                    },
                    set: { newValue in if lineFieldFocused { lineDraft = newValue } }
                ))
                .focused($lineFieldFocused)
                .font(.body)
                .frame(minHeight: 56, maxHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineFieldFocused ? Theme.accent : Theme.strokeStrong))
                .onChange(of: lineFieldFocused) { focused in
                    if focused {
                        guard store.project.lines.indices.contains(currentLineIndex) else { return }
                        lineDraftID = store.project.lines[currentLineIndex].id
                        lineDraft = store.project.lines[currentLineIndex].text
                    } else if let id = lineDraftID {
                        lineDraftID = nil
                        onCommitLineText(id, lineDraft)
                    }
                }
                .onDisappear {
                    if lineFieldFocused, let id = lineDraftID { lineDraftID = nil; onCommitLineText(id, lineDraft) }
                }
            } else {
                Text(L("Chọn một dòng ở danh sách hoặc trên timeline."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }


    // MARK: - Khối "Kiểu chữ" gộp (dùng cho cả câu chính lẫn câu nhắc)

    @ViewBuilder
    private func lookGroup(_ t: Target) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            subgroup("Font") { fontControls(t) }
            Divider()
            subgroup("Màu chữ") { colorControls(t) }
            Divider()
            subgroup("Viền chữ") { outlineControls(t) }
            Divider()
            subgroup("Đổ bóng") { shadowControls(t) }
            Divider()
            subgroup("Phát sáng (glow)") { glowControls(t) }
            Divider()
            subgroup("Khung nền sau chữ") { bgControls(t) }
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(stylePresets.builtins) { preset in
                        presetChip(text: preset.previewText.color, bg: preset.previewBackground.color,
                                   name: preset.name, tag: nil)
                            .onTapGesture { applyPreset(preset) }
                            .contextMenu {
                                Button(L("Ẩn preset này")) { stylePresets.hideBuiltin(preset.name) }
                            }
                    }
                    ForEach(stylePresets.user) { up in
                        presetChip(text: up.main.textColor.color,
                                   bg: Color(red: 0.10, green: 0.11, blue: 0.14),
                                   name: up.name, tag: L("của tôi"))
                            .onTapGesture { applyUserPreset(up) }
                            .contextMenu {
                                Button(L("Áp dụng")) { applyUserPreset(up) }
                                Button(L("Đổi tên…")) { renameUserPreset(up) }
                                Divider()
                                Button(L("Xoá"), role: .destructive) { stylePresets.deleteUser(up.id) }
                            }
                    }
                    Button { saveCurrentAsPreset() } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "plus")
                            Text(L("Lưu kiểu")).font(.system(size: 8))
                        }
                        .frame(width: 54, height: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .foregroundStyle(.white.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .help(L("Lưu toàn bộ kiểu chữ hiện tại thành preset dùng lại"))
                }
                .padding(.vertical, 2)
            }
            if stylePresets.canRestoreDefaults {
                Button {
                    stylePresets.restoreDefaults()
                } label: {
                    Label(L("Khôi phục preset mặc định"), systemImage: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help(L("Hiện lại tất cả preset dựng sẵn đã ẩn"))
            }
        }
    }

    private func presetChip(text: Color, bg: Color, name: String, tag: String?) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
            if let tag {
                Text(tag).font(.system(size: 7, weight: .semibold)).foregroundStyle(text.opacity(0.75))
            }
        }
        .frame(width: 96, height: 44)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(bg))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .help(name)
    }

    private func fontControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            // Nút mở danh sách font — danh sách CHỈ dựng khi bấm mở (popover),
            // nên không nạp 300 font mỗi lần giao diện dựng lại.
            Button {
                fontSearch = ""
                showFontPicker = true
            } label: {
                HStack {
                    Text(style.fontName).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelAlt))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFontPicker, arrowEdge: .bottom) {
                fontPickerPopover(t)
            }

            slider("Cỡ chữ", style.fontSize, 12...260, suffix: "px") { v in edit("Cỡ chữ", t) { $0.fontSize = v } }

            HStack(spacing: 6) {
                styleToggle("B", on: style.fontBold, font: .system(size: 13, weight: .heavy)) { v in perform("Đậm", t) { $0.fontBold = v } }
                styleToggle("I", on: style.fontItalic, font: .system(size: 13).italic()) { v in perform("Nghiêng", t) { $0.fontItalic = v } }
                styleToggle("U", on: style.fontUnderline, font: .system(size: 13), underline: true) { v in perform("Gạch chân", t) { $0.fontUnderline = v } }
                Spacer()
                Picker("", selection: Binding(
                    get: { style.textCase },
                    set: { v in perform("Kiểu hoa/thường", t) { $0.textCase = v } }
                )) {
                    Text(L("Giữ")).tag(TextCase.none)
                    Text(L("HOA")).tag(TextCase.upper)
                    Text(L("thường")).tag(TextCase.lower)
                    Text(L("Hoa đầu")).tag(TextCase.title)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                .tint(Theme.accent)
            }

            slider("Giãn ký tự", style.characterSpacing, -5...30, suffix: "") { v in edit("Giãn ký tự", t) { $0.characterSpacing = v } }
        }
    }

    @ViewBuilder
    private func fontPickerPopover(_ t: Target) -> some View {
        let items = fontFamilies.filter { $0 != "—" &&
            (fontSearch.isEmpty || $0.localizedCaseInsensitiveContains(fontSearch)) }
        VStack(spacing: 6) {
            TextField(L("Tìm font…"), text: $fontSearch)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .top], 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.self) { family in
                        Button {
                            perform("Đổi font", t) { $0.fontName = family }
                            showFontPicker = false
                        } label: {
                            Text(family).font(.custom(family, size: 14))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4).padding(.horizontal, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 280, height: 340)
    }

    private func colorControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            AppFillField(fill: style.textFill, label: L("Chưa hát"),
                         defaultValue: KaraokeStyle.default.textFill) { f in
                edit("Màu chữ chưa hát", t) { $0.textFill = f; $0.textColor = f.color }
            }
            AppFillField(fill: style.highlightFill, label: L("Đang hát"),
                         defaultValue: KaraokeStyle.default.highlightFill) { f in
                edit("Màu chữ đang hát", t) { $0.highlightFill = f; $0.highlightColor = f.color }
            }
        }
    }

    private func outlineControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            check("Bật viền", style.outlineEnabled) { v in perform("Bật/tắt viền", t) { $0.outlineEnabled = v } }
            if style.outlineEnabled {
                AppFillField(fill: style.outlineFill, label: L("Viền chưa hát"),
                             defaultValue: KaraokeStyle.default.outlineFill) { f in
                    edit("Màu viền chưa hát", t) { $0.outlineFill = f; $0.outlineColor = f.color }
                }
                colorRow("Viền đang hát", style.outlineColorSung, default: KaraokeStyle.default.outlineColorSung) { c in edit("Màu viền đang hát", t) { $0.outlineColorSung = c } }
                slider("Độ dày", style.outlineWidth, 0...20, suffix: "px") { v in edit("Độ dày viền", t) { $0.outlineWidth = v } }
            }
        }
    }

    private func shadowControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            check("Bật bóng", style.shadowEnabled) { v in perform("Bật/tắt bóng", t) { $0.shadowEnabled = v } }
            if style.shadowEnabled {
                AppFillField(fill: style.shadowFill, label: L("Màu bóng"),
                             defaultValue: KaraokeStyle.default.shadowFill) { f in
                    edit("Màu bóng", t) { $0.shadowFill = f; $0.shadowColor = f.color }
                }
                slider("Độ nhoè", style.shadowRadius, 0...40, suffix: "px") { v in edit("Độ nhoè bóng", t) { $0.shadowRadius = v } }
                slider("Lệch ngang", style.shadowOffsetX, -30...30, suffix: "px") { v in edit("Lệch bóng ngang", t) { $0.shadowOffsetX = v } }
                slider("Lệch dọc", style.shadowOffsetY, -30...30, suffix: "px") { v in edit("Lệch bóng dọc", t) { $0.shadowOffsetY = v } }
                Text(L("Bóng vẽ cùng hình dạng & độ bo với viền.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func glowControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            check("Bật glow", style.glowEnabled) { v in perform("Bật/tắt glow", t) { $0.glowEnabled = v } }
            if style.glowEnabled {
                AppFillField(fill: style.glowFill, label: L("Màu glow"),
                             defaultValue: KaraokeStyle.default.glowFill) { f in
                    edit("Màu glow", t) { $0.glowFill = f; $0.glowColor = f.color }
                }
                slider("Độ toả", style.glowRadius, 0...50, suffix: "px") { v in edit("Độ toả glow", t) { $0.glowRadius = v } }
            }
        }
    }

    private func bgControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            check("Bật nền", style.backgroundEnabled) { v in perform("Bật/tắt nền chữ", t) { $0.backgroundEnabled = v } }
            if style.backgroundEnabled {
                AppFillField(fill: style.backgroundFill, label: L("Màu nền"),
                             defaultValue: KaraokeStyle.default.backgroundFill) { f in
                    edit("Màu nền chữ", t) { $0.backgroundFill = f; $0.backgroundColor = f.color }
                }
                slider("Đệm", style.backgroundPadding, 0...60, suffix: "px") { v in edit("Đệm nền", t) { $0.backgroundPadding = v } }
                slider("Bo góc", style.backgroundCornerRadius, 0...40, suffix: "px") { v in edit("Bo góc nền", t) { $0.backgroundCornerRadius = v } }
            }
        }
    }

    private func layoutControls(_ t: Target) -> some View {
        let style = styleValue(t)
        return VStack(alignment: .leading, spacing: 8) {
            Picker(L("Căn lề"), selection: Binding(
                get: { style.alignment },
                set: { v in perform("Căn lề", t) { $0.alignment = v } }
            )) {
                Text(L("Trái")).tag(KaraokeTextAlignment.leading)
                Text(L("Giữa")).tag(KaraokeTextAlignment.center)
                Text(L("Phải")).tag(KaraokeTextAlignment.trailing)
            }
            .pickerStyle(.segmented).labelsHidden()
            .tint(Theme.accent)

            if t == .main {
                percentSlider("Vị trí dọc", style.verticalAnchor, 0.05...0.95) { v in edit("Vị trí dọc", t) { $0.verticalAnchor = v } }
            }
            percentSlider("Lề trái/phải", style.horizontalMarginRatio, 0...0.3) { v in edit("Lề trái/phải", t) { $0.horizontalMarginRatio = v } }
            slider("Khoảng cách dòng", style.lineSpacing, 0...40, suffix: "px") { v in edit("Khoảng cách dòng", t) { $0.lineSpacing = v } }

            if t == .main {
                Divider()
                textBlockKeyframeControls
            }
        }
    }

    private func textKFScaleAt(_ songT: TimeInterval) -> Double {
        store.project.textBlockTransform(atSong: songT,
            baseAnchor: store.project.style.verticalAnchor,
            baseHOffset: store.project.style.horizontalOffset).fontScale
    }

    /// Chuyển động CẢ KHỐI chữ karaoke — cụm ◇ kiểu CapCut.
    @ViewBuilder
    private var textBlockKeyframeControls: some View {
        let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
        let kfs = store.project.textKeyframes
        let nearIdx = kfs.firstIndex { abs($0.t - songT) < 0.15 }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Chuyển động khối chữ")).font(.caption.bold())
                if !kfs.isEmpty { Text(String(format: L("%d mốc"), kfs.count)).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if !kfs.isEmpty {
                    Button { store.perform(L("Xoá chuyển động chữ")) { store.project.textKeyframes = [] } }
                        label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Xoá hết"))
                }
                KeyframeControl(
                    hasAny: !kfs.isEmpty, atKeyframe: nearIdx != nil,
                    canPrev: kfs.contains { $0.t < songT - 0.02 },
                    canNext: kfs.contains { $0.t > songT + 0.02 },
                    onPrev: { if let t = kfs.map(\.t).filter({ $0 < songT - 0.02 }).max() {
                        playback.seek(to: t + store.project.karaokeClipStart) } },
                    onToggle: {
                        store.perform(L("Keyframe chữ")) {
                            if let ni = nearIdx { store.project.textKeyframes.remove(at: ni) }
                            else {
                                let cur = store.project.textBlockTransform(atSong: songT,
                                    baseAnchor: store.project.style.verticalAnchor,
                                    baseHOffset: store.project.style.horizontalOffset)
                                store.project.upsertTextKeyframe(atSong: songT, anchor: cur.anchor,
                                    hOffset: cur.hOffset, fontScale: cur.fontScale)
                            }
                        }
                    },
                    onNext: { if let t = kfs.map(\.t).filter({ $0 > songT + 0.02 }).min() {
                        playback.seek(to: t + store.project.karaokeClipStart) } })
            }
            if !kfs.isEmpty {
                percentSlider("Cỡ chữ tại mốc", textKFScaleAt(songT), 0.25...3.0) { v in
                    let cur = store.project.textBlockTransform(atSong: songT,
                        baseAnchor: store.project.style.verticalAnchor, baseHOffset: store.project.style.horizontalOffset)
                    store.edit(L("Cỡ chữ keyframe")) {
                        store.project.upsertTextKeyframe(atSong: songT, anchor: cur.anchor, hOffset: cur.hOffset, fontScale: v)
                    }
                }
                HStack(spacing: 10) {
                    Button { kfClip.textFrames = kfs } label: { Image(systemName: "doc.on.doc") }.help(L("Sao chép"))
                    if kfClip.textFrames != nil {
                        Button {
                            if let src = kfClip.textFrames {
                                store.perform(L("Dán chuyển động chữ")) { store.project.textKeyframes = src }
                            }
                        } label: { Image(systemName: "doc.on.clipboard") }.help(L("Dán"))
                    }
                    if kfs.count >= 2 {
                        Button {
                            store.perform(L("Đảo chuyển động chữ")) {
                                guard let last = store.project.textKeyframes.last?.t else { return }
                                let first = store.project.textKeyframes.first?.t ?? 0
                                store.project.textKeyframes = store.project.textKeyframes
                                    .map { var k = $0; k.t = first + (last - $0.t); return k }.sorted { $0.t < $1.t }
                            }
                        } label: { Image(systemName: "arrow.left.arrow.right") }.help(L("Đảo chiều"))
                    }
                    Spacer()
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(kfs.isEmpty
                 ? L("Bấm ◇ để bắt đầu. Rồi dời vạch đỏ + kéo chữ trên màn hình xem trước → tự tạo mốc.")
                 : L("Dời vạch đỏ tới lúc khác, kéo chữ trên màn hình xem trước → tự ghi mốc."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var effectControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chữ vào", selection: Binding(
                get: { store.project.style.entranceEffect },
                set: { v in store.perform("Hiệu ứng chữ vào") { store.project.style.entranceEffect = v } })) {
                ForEach(TextEffect.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Chữ ra", selection: Binding(
                get: { store.project.style.exitEffect },
                set: { v in store.perform("Hiệu ứng chữ ra") { store.project.style.exitEffect = v } })) {
                ForEach(TextEffect.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if store.project.style.entranceEffect != .none || store.project.style.exitEffect != .none {
                percentSlider("Thời lượng (×1s)", store.project.style.effectDuration, 0.1...1.0) { v in
                    store.edit("Thời lượng hiệu ứng") { store.project.style.effectDuration = v }
                }
            }
            Divider()
            Toggle("Mép vệt hát loang mềm", isOn: Binding(
                get: { store.project.style.softWipe },
                set: { v in store.perform("Mép hát mềm") { store.project.style.softWipe = v } }
            )).toggleStyle(.checkbox)
            Toggle("Vệt sáng chạy theo mép hát", isOn: Binding(
                get: { store.project.style.wipeGlow },
                set: { v in store.perform("Vệt sáng mép hát") { store.project.style.wipeGlow = v } }
            )).toggleStyle(.checkbox)
        }
    }

    private var timingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            percentSlider("Tốc độ quét chữ", store.project.wipeCompletion, 0.4...1.0) { v in
                store.edit("Tốc độ quét chữ") { store.project.wipeCompletion = v }
            }
            HStack {
                Text("Bù trước khi bấm T").font(.callout)
                Spacer()
                Text(String(format: "%.2f s", store.project.tapLeadIn))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("−0.05") { setLeadIn(store.project.tapLeadIn - 0.05) }
                Button("+0.05") { setLeadIn(store.project.tapLeadIn + 0.05) }
                Button("0.5") { setLeadIn(0.5) }
                Spacer()
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func subgroup<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title).uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func check(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(L(title), isOn: Binding(get: { on }, set: { set($0) })).toggleStyle(.checkbox)
    }

    private func styleToggle(_ label: String, on: Bool, font: Font, underline: Bool = false, _ set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            Text(label).font(font).underline(underline)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.accent : Theme.panelAlt))
                .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func colorRow(_ title: String, _ color: RGBAColor, default def: RGBAColor? = nil,
                          _ set: @escaping (RGBAColor) -> Void) -> some View {
        AppColorField(color: color, label: L(title), defaultValue: def, onChange: set)
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, suffix: String, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L(title)).font(.callout)
                Spacer()
                Text("\(Int(value.rounded()))\(suffix)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            DragSlider(value: value, range: range, onChange: onChange)
        }
    }

    private func percentSlider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L(title)).font(.callout)
                Spacer()
                Text("\(Int((value * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            DragSlider(value: value, range: range, onChange: onChange)
        }
    }

    /// Slider có TIẾT LƯU: lúc kéo chỉ ghi store ~11Hz (đỡ dựng lại ContentView 30-60Hz),
    /// thả tay ghi giá trị cuối. Nút vẫn chạy mượt theo `live`.
    private struct DragSlider: View {
        let value: Double
        let range: ClosedRange<Double>
        let onChange: (Double) -> Void
        @State private var live: Double?
        @State private var lastPush = Date.distantPast
        var body: some View {
            Slider(value: Binding(
                get: { live ?? value },
                set: { v in
                    live = v
                    let now = Date()
                    if now.timeIntervalSince(lastPush) > 0.09 { lastPush = now; onChange(v) }
                }),
                in: range,
                onEditingChanged: { editing in
                    if !editing { if let v = live { onChange(v) }; live = nil }
                })
        }
    }

    /// Áp thay đổi vào style câu chính HOẶC câu nhắc, tuỳ `t`.
    private func perform(_ name: String, _ t: Target, _ mutate: @escaping (inout KaraokeStyle) -> Void) {
        store.perform(L(name)) {
            if t == .main { mutate(&store.project.style) } else { mutate(&store.project.nextLineStyle) }
        }
    }

    private func edit(_ name: String, _ t: Target, _ mutate: @escaping (inout KaraokeStyle) -> Void) {
        store.edit(L(name)) {
            if t == .main { mutate(&store.project.style) } else { mutate(&store.project.nextLineStyle) }
        }
    }

    private func applyPreset(_ preset: StylePreset) {
        store.perform("Preset: \(preset.name)") {
            preset.apply(&store.project.style)
            preset.applyNext?(&store.project.nextLineStyle)
        }
    }

    private func applyUserPreset(_ up: UserStylePreset) {
        store.perform("Preset: \(up.name)") {
            store.project.style = up.main
            store.project.nextLineStyle = up.next
        }
    }

    private func saveCurrentAsPreset() {
        let base = "\(L("Kiểu của tôi")) \(stylePresets.user.count + 1)"
        guard let name = TextPrompt.run(
            title: L("Lưu kiểu chữ hiện tại"),
            message: L("Lưu cả kiểu câu chính và câu nhắc để dùng lại ở bài khác."),
            defaultValue: base) else { return }
        stylePresets.addCurrent(name: name,
                                main: store.project.style,
                                next: store.project.nextLineStyle)
    }

    private func renameUserPreset(_ up: UserStylePreset) {
        guard let name = TextPrompt.run(title: L("Đổi tên preset"),
                                        defaultValue: up.name, okTitle: L("Đổi")) else { return }
        stylePresets.rename(up.id, to: name)
    }

    private func setLeadIn(_ value: Double) {
        store.perform(L("Bù trước khi bấm T")) { store.project.tapLeadIn = min(2, max(0, value)) }
    }
}
