import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    var centerColumn: some View {
        VStack(spacing: Theme.Metric.gap) {
            KaraokePreview(background: previewBackground, backgroundImage: backgroundImage,
                           videoURL: bgVideoURL, previewQuality: previewQuality,
                           selectedOverlayID: selectedOverlayID,
                           selectedOverlayIDs: selectedOverlayIDs,
                           showSafeArea: showSafeArea,
                           onSelectOverlay: { selectedOverlayID = $0 },
                           onEditTextOverlay: { id in
                               selectedOverlayID = id
                               DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { textOverlayEditing = true }
                           })
                .frame(maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.radius))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                .overlay(alignment: .topTrailing) {
                    Toggle(L("Vạch an toàn"), isOn: $showSafeArea)
                        .toggleStyle(.button).controlSize(.small)
                        .padding(Theme.Metric.gap)
                }
                .overlay { if isFreshProject { onboardingCard } }
            transportBar
        }
        .padding(Theme.Metric.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }

    /// Project vừa tạo, chưa có gì → hiện hướng dẫn 3 bước.
    var isFreshProject: Bool {
        store.project.audio == nil
            && store.project.lines.isEmpty
            && store.project.overlays.isEmpty
            && store.project.backgroundMedia == nil
    }

    var onboardingCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.mic").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text(L("Bắt đầu làm karaoke")).font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                onboardStep("1", "Kéo file nhạc vào ô 'File của bạn' (cột trái) hoặc thả xuống timeline.")
                onboardStep("2", "Sang tab 'Tạo Karaoke' → dán lời bài hát.")
                onboardStep("3", "Bấm tạo karaoke, rồi tinh chỉnh trên timeline.")
            }
            .font(.callout)
            Text(L("Ảnh / video / logo: kéo xuống timeline để đè lên video."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(maxWidth: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    func onboardStep(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(n)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accent.opacity(0.25)))
                .overlay(Circle().stroke(Theme.accent.opacity(0.6)))
            Text(L(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Bọc 1 nhóm chức năng thành THẺ RIÊNG (nền mờ + viền mỏng) — cùng ngôn ngữ hình ảnh với
    /// `stepBlock` bên ngoài, tách bạch từng khối thay vì 1 cột chữ liền mạch.
    func subCard<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Metric.gap) {
            Text(L(title)).sectionHeaderStyle()
            content()
        }
        .padding(Theme.Metric.gap + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Metric.radiusSm).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radiusSm).stroke(Theme.stroke))
    }

    /// Bước 3 trong quy trình giờ chỉ CHỈ ĐƯỜNG — điều khiển thật đã dời sang tab
    /// "Kho media" riêng (đầy chiều cao) ở trên cùng panel trái, đỡ nhồi nhét 1 chỗ.
    @ViewBuilder
    var backgroundPanelBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Chọn nền ở tab **Nền video**, thêm chữ ở tab **Thêm text**, bật sóng nhạc ở tab **Sóng nhạc**. Thêm ảnh / video / nhạc đè ở tab **Media**."))
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { withAnimation { leftPanelTab = .background } } label: {
                    Label(L("Nền video"), systemImage: "photo")
                }
                Button { withAnimation { leftPanelTab = .files } } label: {
                    Label(L("Media"), systemImage: "folder")
                }
            }
            .controlSize(.small)
        }
    }

    /// (U6) Nội dung chọn nền — dùng chung giữa tab "Kho media" (chính) và bước 3 cũ (nếu cần).
    /// Gồm LUÔN bảng phóng/lệch/mờ + Ken Burns + chỉnh màu (`backgroundMediaBlock`) — không
    /// còn tách sang tab Xuất nữa.
    @ViewBuilder
    var backgroundSourceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Kiểu nền"), selection: $previewBackground) {
                ForEach(PreviewBackground.allCases) { Text(L($0.rawValue)).tag($0) }
            }

            // Hiệu ứng Bass nền — CHỈ hiện khi đã có nền (ảnh/video), đặt ngay dưới kiểu nền cho dễ thấy.
            if store.project.backgroundMedia != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(L("Hiệu ứng Bass nền"), isOn: beatZoomEnabledBinding)
                        .toggleStyle(.checkbox).font(.caption.weight(.semibold))
                    if beatZoomEnabledBinding.wrappedValue {
                        bgSlider("Mức bass", beatZoomAmountBinding.wrappedValue, 1.0...1.3) { v in
                            beatZoomAmountBinding.wrappedValue = v
                        }
                        Text(L("Nền phóng to nhẹ theo tiếng bass, tự mượt lại — không giật."))
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
            }

            if let media = store.project.backgroundMedia, media.kind == .video {
                Picker(L("Chất lượng xem"), selection: $previewQuality) {
                    ForEach(PreviewQuality.allCases) { Text(L($0.rawValue)).tag($0) }
                }
            }
            Divider().padding(.vertical, 2)
            backgroundMediaBlock
        }
    }

    /// (U6) Danh sách lớp đè — dùng chung giữa tab "Kho media" (chính) và bước 3 cũ.
    @ViewBuilder
    var overlayListContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(L("＋ Ảnh / logo…")) { addOverlay() }.controlSize(.small)
            }
            if store.project.overlays.isEmpty {
                Text(L("Chưa có. Thêm logo hoặc ảnh graded để đè lên video."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                ForEach(store.project.overlays) { clip in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Button { toggleOverlayLocked(clip.id) } label: {
                                Image(systemName: clip.isLocked ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(.borderless)
                            .help(clip.isLocked ? L("Đang khoá — bấm để mở, kéo/sửa được lại") : L("Khoá lại để không kéo/sửa nhầm"))
                            Button { toggleOverlayHidden(clip.id) } label: {
                                Image(systemName: clip.isHidden ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .help(clip.isHidden ? L("Đang ẩn") : L("Đang hiện"))
                            Text(clip.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(selectedOverlayID == clip.id ? L("Đóng") : L("Sửa")) {
                                selectedOverlayID = (selectedOverlayID == clip.id) ? nil : clip.id
                            }
                            .controlSize(.small)
                            .help(L("Mở bảng chỉnh ở cột bên phải"))
                            Button(role: .destructive) { removeOverlay(clip.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }

    /// (U5) Chia gọn theo tab thay vì cuộn dài 1 lượt — Biến hình / Màu sắc.
    @ViewBuilder
    func overlayInspectorInline(_ id: UUID) -> some View {
        if let b = overlayBinding(id) {
            let locked = store.project.overlays.first(where: { $0.id == id })?.isLocked ?? false
            switch b.wrappedValue.kind {
            case .audio: audioOverlayInspector(b, locked: locked)
            case .text:  textOverlayInspector(b, locked: locked)
            default:     overlayVisualInspector(id, b, locked: locked)
            }
        }
    }

    /// Danh sách font gợi ý cho lớp chữ (không quét toàn hệ thống cho nhẹ).
    static let textLayerFonts: [String] = {
        let want = ["Helvetica Neue", "Arial", "Avenir Next", "Futura", "Georgia",
                    "Times New Roman", "SF Pro", "SF Pro Display", "Be Vietnam Pro",
                    "Montserrat", "Roboto", "Noto Sans", "UTM Avo", "iCiel Cadena",
                    "Pattaya", "Lobster", "Bebas Neue", "Anton", "Oswald"]
        let all = Set(NSFontManager.shared.availableFontFamilies)
        return want.filter { all.contains($0) }
    }()

    /// Tab của bảng sửa LỚP CHỮ — chia nhỏ thay vì 1 cột dài kéo.
    enum TextInspTab: String, CaseIterable {
        case content, color, effect, transform
        var label: String {
            switch self {
            case .content: return "Nội dung"
            case .color: return "Màu"
            case .effect: return "Hiệu ứng"
            case .transform: return "Biến hình"
            }
        }
        var icon: String {
            switch self {
            case .content: return "textformat"
            case .color: return "paintpalette"
            case .effect: return "sparkles"
            case .transform: return "move.3d"
            }
        }
    }

    @ViewBuilder
    func textOverlayInspector(_ b: Binding<OverlayClip>, locked: Bool) -> some View {
        let halfDur = max(0.1, b.wrappedValue.duration / 2)
        var seen = Set<String>()
        let fonts = ([b.wrappedValue.textFontName] + Self.textLayerFonts).filter { seen.insert($0).inserted }
        VStack(alignment: .leading, spacing: 9) {
            if locked {
                Label(L("Đã khoá — mở khoá ở danh sách bên trái để sửa"), systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(L("Kéo–giãn–xoay trên màn hình xem trước · bấm đúp chữ để sửa nhanh."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Menu {
                    Button(L("Lưu kiểu hiện tại…")) {
                        if let name = TextPrompt.run(title: L("Lưu kiểu lớp chữ"),
                                                     defaultValue: "\(L("Kiểu")) \(textPresets.presets.count + 1)") {
                            textPresets.add(name: name, style: TextLayerStyle(b.wrappedValue))
                        }
                    }
                    if !textPresets.presets.isEmpty {
                        Divider()
                        ForEach(textPresets.presets) { pr in
                            Button(pr.name) {
                                store.perform(L("Kiểu lớp chữ: \(pr.name)")) {
                                    if let i = store.project.overlays.firstIndex(where: { $0.id == b.wrappedValue.id }) {
                                        pr.style.apply(to: &store.project.overlays[i])
                                    }
                                }
                            }
                        }
                        Divider()
                        Menu(L("Xoá kiểu")) {
                            ForEach(textPresets.presets) { pr in
                                Button(pr.name, role: .destructive) { textPresets.delete(pr.id) }
                            }
                        }
                    }
                } label: { Label(L("Kiểu"), systemImage: "textformat.alt") }
                    .menuStyle(.borderlessButton).fixedSize()
            }

            Picker("", selection: $textInspTab) {
                ForEach(TextInspTab.allCases, id: \.self) { t in
                    Label(L(t.label), systemImage: t.icon).tag(t)
                }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.vertical, 2)

            switch textInspTab {
            case .content:
                TextEditor(text: b.text)
                    .font(.body).frame(minHeight: 52, maxHeight: 96)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(textOverlayEditing ? Theme.accent : Theme.strokeStrong))
                    .focused($textOverlayEditing)
                HStack(spacing: 8) {
                    Menu {
                        ForEach(fonts, id: \.self) { f in
                            Button(f) { b.wrappedValue.textFontName = f }
                        }
                    } label: {
                        Text(b.wrappedValue.textFontName).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    Toggle("B", isOn: b.textBold).toggleStyle(.button).font(.system(size: 12, weight: .bold))
                    Toggle("I", isOn: b.textItalic).toggleStyle(.button).font(.system(size: 12).italic())
                }
                overlaySlider("Cỡ chữ", b.textFontSize, 12...320, "%.0f")
                overlaySlider("Giãn chữ", b.textCharSpacing, -10...40, "%.1f")
                overlaySlider("Cách dòng", b.textLineSpacing, 0...80, "%.0f")
                overlaySlider("Bề rộng ngắt dòng", b.textWrapFrac, 0.2...1.0, "%.2f")
                Picker(L("Căn lề"), selection: b.textAlign) {
                    Text(L("Trái")).tag(KaraokeTextAlignment.leading)
                    Text(L("Giữa")).tag(KaraokeTextAlignment.center)
                    Text(L("Phải")).tag(KaraokeTextAlignment.trailing)
                }
                .pickerStyle(.segmented).labelsHidden().tint(Theme.accent)

            case .color:
                AppFillField(fill: b.wrappedValue.textFill, label: "Màu chữ",
                             defaultValue: OverlayClip().textFill) {
                    b.wrappedValue.textFill = $0
                    b.wrappedValue.textColor = $0.color
                }
                AppFillField(fill: b.wrappedValue.textOutlineFill, label: "Màu viền",
                             defaultValue: OverlayClip().textOutlineFill) {
                    b.wrappedValue.textOutlineFill = $0
                    b.wrappedValue.textOutlineColor = $0.color
                }
                overlaySlider("Độ dày viền", b.textOutlineWidth, 0...30, "%.0f")
                AppFillField(fill: b.wrappedValue.textBackgroundFill, label: "Nền sau chữ (alpha 0 = tắt)",
                             defaultValue: OverlayClip().textBackgroundFill) {
                    b.wrappedValue.textBackgroundFill = $0
                    b.wrappedValue.textBackgroundColor = $0.color
                }
                Divider()
                AppFillField(fill: b.wrappedValue.textShadowFill, label: "Bóng đổ (alpha 0 = tắt)",
                             defaultValue: OverlayClip().textShadowFill) {
                    b.wrappedValue.textShadowFill = $0
                    b.wrappedValue.textShadowColor = $0.color
                }
                if b.wrappedValue.textShadowFill.maxAlpha > 0.001 {
                    overlaySlider("Nhoè bóng", b.textShadowRadius, 0...40, "%.0f")
                    overlaySlider("Bóng ngang", b.textShadowDX, -30...30, "%.0f")
                    overlaySlider("Bóng dọc", b.textShadowDY, -30...30, "%.0f")
                }
                AppFillField(fill: b.wrappedValue.textGlowFill, label: "Phát sáng / glow (alpha 0 = tắt)",
                             defaultValue: OverlayClip().textGlowFill) {
                    b.wrappedValue.textGlowFill = $0
                    b.wrappedValue.textGlowColor = $0.color
                }
                if b.wrappedValue.textGlowFill.maxAlpha > 0.001 {
                    overlaySlider("Độ toả glow", b.textGlowRadius, 0...50, "%.0f")
                }

            case .effect:
                HStack(spacing: 8) {
                    Picker(L("Chữ vào"), selection: b.textEntrance) {
                        ForEach(TextEffect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker(L("Chữ ra"), selection: b.textExit) {
                        ForEach(TextEffect.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                .controlSize(.small)
                if b.wrappedValue.textEntrance != .none || b.wrappedValue.textExit != .none {
                    overlaySlider("Thời lượng hiệu ứng", b.textEffectDur, 0.1...1.5, "%.2f")
                }
                Divider()
                overlaySlider("Độ mờ", opacityKFBinding(b), 0...1, "%.2f")
                fadeRow("Hiện dần", b.fadeIn, max: halfDur)
                fadeRow("Mờ dần", b.fadeOut, max: halfDur)

            case .transform:
                Toggle(L("Đè lên trên chữ karaoke"), isOn: b.aboveText).toggleStyle(.checkbox).font(.caption)
                HStack(spacing: 6) {
                    Button(L("Giữa khung")) {
                        b.wrappedValue.offsetX = 0; b.wrappedValue.offsetY = 0; b.wrappedValue.rotation = 0
                    }
                    Button(L("Cỡ gốc")) { b.wrappedValue.scale = 1 }
                }
                .controlSize(.small)
                Divider()
                keyframeControls(b)
            }
        }
        .disabled(locked)
    }

    /// Tua vạch đỏ tới mốc keyframe trước / sau vị trí hiện tại.
    func seekToKeyframe(_ clip: OverlayClip, dir: Int) {
        let lt = max(0, playback.currentTime - clip.start)
        let t: Double? = dir < 0
            ? clip.keyframes.map(\.t).filter { $0 < lt - 0.02 }.max()
            : clip.keyframes.map(\.t).filter { $0 > lt + 0.02 }.min()
        if let t { seekTo(clip.start + t) }
    }

    /// Binding "Độ mờ" nhận biết keyframe: có chuyển động → đọc/ghi mốc tại vạch đỏ; không → tĩnh.
    func opacityKFBinding(_ b: Binding<OverlayClip>) -> Binding<Double> {
        let clip = b.wrappedValue
        guard !clip.keyframes.isEmpty else { return b.opacity }
        let lt = max(0, playback.currentTime - clip.start)
        return Binding(
            get: { b.wrappedValue.transform(atLocal: lt).opacity },
            set: { v in
                store.edit(L("Độ mờ keyframe")) {
                    guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) else { return }
                    let p = store.project.overlays[i].transform(atLocal: lt)
                    store.project.overlays[i].upsertKeyframe(atLocal: lt, offX: p.offX, offY: p.offY,
                                                            scale: p.scale, rotation: p.rot, opacity: v)
                }
            })
    }

    /// Chuyển động (keyframe) cho lớp đè — cụm ◇ kiểu CapCut.
    @ViewBuilder
    func keyframeControls(_ b: Binding<OverlayClip>) -> some View {
        let clip = b.wrappedValue
        let localT = max(0, playback.currentTime - clip.start)
        let hasAny = !clip.keyframes.isEmpty
        let nearIdx = clip.keyframes.firstIndex { abs($0.t - localT) < 0.15 }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L("Chuyển động")).font(.caption.bold())
                if hasAny { Text(String(format: L("%d mốc"), clip.keyframes.count)).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                if hasAny {
                    Button { store.perform(L("Xoá chuyển động")) {
                        if let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) {
                            store.project.overlays[i].keyframes = [] }
                    } } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(L("Xoá hết chuyển động"))
                }
                KeyframeControl(
                    hasAny: hasAny, atKeyframe: nearIdx != nil,
                    canPrev: clip.keyframes.contains { $0.t < localT - 0.02 },
                    canNext: clip.keyframes.contains { $0.t > localT + 0.02 },
                    onPrev: { seekToKeyframe(clip, dir: -1) },
                    onToggle: {
                        store.perform("Keyframe") {
                            guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) else { return }
                            if let ni = nearIdx { store.project.overlays[i].keyframes.remove(at: ni) }
                            else {
                                let p = store.project.overlays[i].transform(atLocal: localT)
                                store.project.overlays[i].upsertKeyframe(atLocal: localT, offX: p.offX, offY: p.offY,
                                                                        scale: p.scale, rotation: p.rot, opacity: p.opacity)
                            }
                        }
                    },
                    onNext: { seekToKeyframe(clip, dir: 1) })
            }

            if let ki = nearIdx {
                HStack(spacing: 6) {
                    Text(L("Kiểu chạy")).font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { clip.keyframes[ki].ease },
                        set: { v in store.edit(L("Kiểu keyframe")) {
                            guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }),
                                  store.project.overlays[i].keyframes.indices.contains(ki) else { return }
                            store.project.overlays[i].keyframes[ki].ease = v
                        } })) {
                        ForEach(KFEase.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().controlSize(.mini)
                    Spacer()
                }
            }
            if hasAny || kfClip.frames != nil {
                HStack(spacing: 10) {
                    if hasAny {
                        Button { kfClip.frames = clip.keyframes } label: { Image(systemName: "doc.on.doc") }
                            .help(L("Sao chép chuyển động"))
                        Button {
                            store.perform(L("Đảo chuyển động")) {
                                guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }),
                                      let last = store.project.overlays[i].keyframes.last?.t else { return }
                                let first = store.project.overlays[i].keyframes.first?.t ?? 0
                                store.project.overlays[i].keyframes = store.project.overlays[i].keyframes
                                    .map { var k = $0; k.t = first + (last - $0.t); return k }.sorted { $0.t < $1.t }
                            }
                        } label: { Image(systemName: "arrow.left.arrow.right") }.help(L("Đảo chiều"))
                    }
                    if kfClip.frames != nil {
                        Button {
                            guard let src = kfClip.frames else { return }
                            store.perform(L("Dán chuyển động")) {
                                guard let i = store.project.overlays.firstIndex(where: { $0.id == clip.id }) else { return }
                                let dur = max(0.1, store.project.overlays[i].duration)
                                store.project.overlays[i].keyframes = src
                                    .map { var k = $0; k.t = max(0, min(dur, k.t)); return k }.sorted { $0.t < $1.t }
                            }
                        } label: { Image(systemName: "doc.on.clipboard") }.help(L("Dán chuyển động"))
                    }
                    Spacer()
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text(hasAny
                 ? L("Dời vạch đỏ tới chỗ khác, kéo–giãn–xoay lớp trên màn hình xem trước → tự ghi mốc.")
                 : L("Bấm ◇ để bắt đầu. Rồi dời vạch đỏ + chỉnh lớp → app tự tạo mốc."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Clip TIẾNG trên làn lớp đè — chỉ tiếng, không hình.
    func audioOverlayInspector(_ b: Binding<OverlayClip>, locked: Bool) -> some View {
        let halfDur = max(0.1, b.wrappedValue.duration / 2)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Clip tiếng — trộn kèm bài hát chính khi phát thử và khi xuất video."))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L("Tắt tiếng clip này"), isOn: b.audioMuted)
                .toggleStyle(.checkbox).font(.caption)
            HStack(spacing: 6) {
                Text(L("Nhạc vào từ")).font(.caption2).frame(width: 72, alignment: .leading)
                Stepper(value: b.trimStart,
                        in: 0...max(0, b.wrappedValue.sourceDuration - 0.2), step: 0.5) {
                    Text(String(format: "%.1fs", b.wrappedValue.trimStart)).font(.caption2.monospacedDigit())
                }
                Button(L("Về 0")) { b.wrappedValue.trimStart = 0 }.controlSize(.small)
            }
            fadeRow("To dần", b.fadeIn, max: halfDur)
            fadeRow("Nhỏ dần", b.fadeOut, max: halfDur)
            Text(L("Kéo trên timeline để dời / đổi làn · kéo mép để cắt độ dài."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .disabled(locked)
    }

    func overlayVisualInspector(_ id: UUID, _ b: Binding<OverlayClip>, locked: Bool) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                if locked {
                    Label(L("Đã khoá — mở khoá ở danh sách bên trái để sửa"), systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                Text(L("Kéo–giãn–xoay trực tiếp trên màn hình xem trước. Thời điểm hiện / mất chỉnh ở timeline."))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    overlaySlider("Độ mờ", opacityKFBinding(b), 0...1, "%.2f")
                    Picker(L("Hoà trộn"), selection: b.blend) {
                        ForEach(Compositor.Blend.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .controlSize(.small)
                    Toggle(L("Đè lên trên chữ"), isOn: b.aboveText)
                        .toggleStyle(.checkbox).font(.caption)
                        .help(L("Tắt = ảnh nằm DƯỚI chữ (dùng để tô màu / graded video)"))
                    HStack(spacing: 6) {
                        Button(L("Vừa khung")) {
                            b.wrappedValue.scale = 1
                            b.wrappedValue.offsetX = 0; b.wrappedValue.offsetY = 0; b.wrappedValue.rotation = 0
                        }
                        Button(L("Phủ kín")) {
                            b.wrappedValue.scale = overlayCoverScale(b.wrappedValue)
                            b.wrappedValue.offsetX = 0; b.wrappedValue.offsetY = 0
                        }
                        Button(L("Đổi ảnh…")) { replaceOverlayImage(id) }
                    }
                    .controlSize(.small)

                    if b.wrappedValue.kind == .video {
                        HStack(spacing: 6) {
                            Text(L("Video vào từ")).font(.caption2).frame(width: 66, alignment: .leading)
                            Stepper(value: b.trimStart,
                                    in: 0...max(0, b.wrappedValue.sourceDuration - b.wrappedValue.duration),
                                    step: 0.5) {
                                Text(String(format: "%.1fs", b.wrappedValue.trimStart))
                                    .font(.caption2.monospacedDigit())
                            }
                            Button(L("Về 0")) { b.wrappedValue.trimStart = 0 }.controlSize(.small)
                        }
                        Toggle(L("Bật tiếng của clip video"), isOn: b.videoAudioOn)
                            .toggleStyle(.checkbox).font(.caption)
                    }

                    let halfDur = max(0.1, b.wrappedValue.duration / 2)
                    fadeRow("Hiện dần", b.fadeIn, max: halfDur)
                    fadeRow("Mờ dần", b.fadeOut, max: halfDur)
                }

                Divider()
                keyframeControls(b)

                Divider()
                colorBasicPanel(b.colorAdjust, sample: {
                    let clip = b.wrappedValue
                    if clip.kind == .image { return OverlayImageStore.image(for: clip) }
                    guard let url = clip.resolveURL() else { return nil }
                    let vt = max(0, clip.trimStart + (playback.currentTime - clip.start))
                    guard let raw = OverlayVideoFrameStore.frame(path: clip.lastKnownPath, url: url, t: vt)
                    else { return nil }
                    return clip.colorAdjust.isIdentity ? raw : ImageFX.apply(raw, clip.colorAdjust)
                }, sampleKeySuffix: b.wrappedValue.kind == .video ? "|t\(Int(playback.currentTime))" : "")
            }
            .disabled(locked)
    }
}
