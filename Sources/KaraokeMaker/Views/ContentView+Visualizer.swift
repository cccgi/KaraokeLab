import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    // MARK: - Sóng nhạc (music visualizer)

    var visualizerBinding: Binding<MusicVisualizer> {
        Binding(
            get: { store.project.visualizer ?? .default },
            set: { newVal in
                store.edit(L("Chỉnh sóng nhạc")) { store.project.visualizer = newVal }
            })
    }

    func setVisualizerEnabled(_ on: Bool) {
        store.perform(on ? L("Bật sóng nhạc") : L("Tắt sóng nhạc")) {
            if on {
                var v = store.project.visualizer ?? MusicVisualizer.freshDefault()
                v.enabled = true
                store.project.visualizer = v
            } else {
                store.project.visualizer?.enabled = false
            }
        }
        if on, let ref = store.project.audio, let url = AudioLoader.resolveURL(from: ref) {
            SpectrumStore.ensure(for: url)
        }
    }

    /// Đang ở kiểu "Cột mảnh cổ điển"? (so các thông số KIỂU; vị trí / cỡ người dùng kéo sau vẫn tính là cổ điển)
    func isClassicVisualizer(_ v: MusicVisualizer?) -> Bool {
        guard let v else { return false }
        let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
        return v.style == .barsUp && v.bandCount == 140 && v.color1 == white && v.color2 == white
            && abs(v.barGapFrac - 0.22) < 0.001 && abs(v.cornerRadiusFrac - 0.1) < 0.001 && abs(v.glow - 0.08) < 0.001
    }

    /// Nút bật / tắt "Cột mảnh cổ điển" (chủ dự án 2026-09-29): bấm lần 1 → cổ điển; bấm lần 2 → về kiểu trước đó
    /// (không nhớ được kiểu trước, vd. mở lại dự án → về kiểu mặc định).
    func toggleClassicVisualizer() {
        let cur = store.project.visualizer
        guard cur != nil else { return }
        if isClassicVisualizer(cur) {
            let back = classicVizBackup.flatMap { isClassicVisualizer($0) ? nil : $0 } ?? MusicVisualizer()
            classicVizBackup = nil
            store.perform(L("Đổi kiểu sóng nhạc")) {
                guard var v = store.project.visualizer else { return }
                v.style = back.style; v.bandCount = back.bandCount
                v.barGapFrac = back.barGapFrac; v.cornerRadiusFrac = back.cornerRadiusFrac
                v.heightFrac = back.heightFrac; v.baselineY = back.baselineY; v.mirror = back.mirror
                v.color1 = back.color1; v.color2 = back.color2; v.gradientDir = back.gradientDir
                v.glowAuto = back.glowAuto; v.glow = back.glow; v.tipColor = back.tipColor
                v.opacity = back.opacity; v.sensitivity = back.sensitivity; v.smoothing = back.smoothing
                store.project.visualizer = v
            }
        } else {
            classicVizBackup = cur
            applyClassicVisualizerPreset()
        }
    }

    /// Preset nhanh: cột trắng mảnh, dày, gọn — kiểu spectrum cổ điển hay thấy trong video nhạc
    /// (khác hẳn kiểu gradient neon dày cộp mặc định). Giữ nguyên vị trí / kích thước đang đặt.
    func applyClassicVisualizerPreset() {
        store.perform(L("Đổi kiểu sóng nhạc")) {
            guard var v = store.project.visualizer else { return }
            v.style = .barsUp
            v.bandCount = 140
            v.barGapFrac = 0.22
            v.cornerRadiusFrac = 0.1
            v.heightFrac = 0.14
            v.baselineY = 0.05
            v.mirror = false
            v.color1 = RGBAColor(r: 1, g: 1, b: 1, a: 1)
            v.color2 = RGBAColor(r: 1, g: 1, b: 1, a: 1)
            v.gradientDir = .up
            v.glowAuto = true
            v.glow = 0.08
            v.tipColor = RGBAColor(r: 1, g: 1, b: 1, a: 0)
            v.opacity = 0.9
            v.sensitivity = 1.2
            v.smoothing = 0.5
            store.project.visualizer = v
        }
    }

    /// M-D — cắt đầu / đuôi bài + âm lượng. KHÔNG dời timeline-time (lời giữ nguyên);
    /// chỉ giới hạn vùng PHÁT (và sau này vùng XUẤT).
    func syncAudioSettings() {
        playback.applyAudioSettings(
            trimStart: store.project.audioTrimStart,
            trimEnd: store.project.audioTrimEnd,
            gain: store.project.audioGain,
            muted: store.project.audioMuted)
        // Bước 2c — clip ★ KARAOKE: cả bản karaoke phát trễ đúng mốc này trên timeline.
        playback.setLeadOffset(store.project.karaokeClipStart)
    }

    /// Slider vị trí sóng nhạc — nhận biết keyframe (có mốc → đọc/ghi mốc tại vạch đỏ).
    func vizKFBinding(_ kp: WritableKeyPath<MusicVisualizer, Double>, base: Binding<Double>) -> Binding<Double> {
        guard store.project.visualizer?.keyframes.isEmpty == false else { return base }
        let songT = max(0, playback.currentTime - store.project.karaokeClipStart)
        return Binding(
            get: { store.project.visualizer?.resolved(atSong: songT)[keyPath: kp] ?? base.wrappedValue },
            set: { newVal in
                store.edit(L("Sóng nhạc keyframe")) {
                    guard var v = store.project.visualizer else { return }
                    var res = v.resolved(atSong: songT)
                    res[keyPath: kp] = newVal
                    v.widthFrac = res.widthFrac; v.heightFrac = res.heightFrac
                    v.offsetX = res.offsetX; v.baselineY = res.baselineY
                    v.rotation = res.rotation; v.opacity = res.opacity
                    v.upsertKeyframe(atSong: songT)
                    store.project.visualizer = v
                }
            })
    }

    @ViewBuilder
    var visualizerPanel: some View {
        let v = visualizerBinding
        let on = store.project.visualizer?.enabled ?? false
        let vizSongT = max(0, playback.currentTime - store.project.karaokeClipStart)
        let vizKF = store.project.visualizer?.keyframes ?? []
        let vizNearIdx = vizKF.firstIndex { abs($0.t - vizSongT) < 0.15 }
        HStack(spacing: 8) {
            Image(systemName: on ? "waveform" : "waveform.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.inkDim)
            Text(on ? L("Sóng nhạc: BẬT") : L("Sóng nhạc: TẮT"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? Theme.ink : Theme.inkDim)
            Spacer()
            Toggle("", isOn: Binding(get: { on }, set: { setVisualizerEnabled($0) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
        // Sổ ra sẵn — các control luôn HIỆN, chỉ mờ + khoá khi chưa bật.
        Group {
            Text(L("Vẽ theo nhạc GỐC bạn bỏ vào. Mặc định full bề ngang — chỉnh cỡ / vị trí bên dưới."))
                .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            Picker(L("Kiểu"), selection: v.style) {
                ForEach(MusicVisualizer.Style.allCases) { Text($0.label).tag($0) }
            }.controlSize(.small)
            let classicOn = isClassicVisualizer(store.project.visualizer)
            Button { toggleClassicVisualizer() } label: {
                Label(L("Cột mảnh cổ điển"), systemImage: classicOn ? "checkmark" : "wand.and.stars")
            }
            .buttonStyle(.kmToggle(classicOn))
            .help(classicOn ? L("Đang dùng kiểu cột mảnh cổ điển — bấm lần nữa để trở về kiểu trước.")
                            : L("Đổi sang kiểu cột trắng mảnh, dày, gọn gàng — kiểu spectrum cổ điển hay dùng trong video nhạc."))
            overlaySlider("Cỡ ngang", vizKFBinding(\.widthFrac, base: v.widthFrac), 0.2...1.0, "%.2f", reset: MusicVisualizer().widthFrac)
            overlaySlider("Chiều cao", vizKFBinding(\.heightFrac, base: v.heightFrac), 0.04...0.6, "%.2f", reset: MusicVisualizer().heightFrac)
            overlaySlider("Dời ngang", vizKFBinding(\.offsetX, base: v.offsetX), -0.5...0.5, "%.2f", reset: 0)
            overlaySlider("Nâng lên", vizKFBinding(\.baselineY, base: v.baselineY), 0...0.9, "%.2f", reset: MusicVisualizer().baselineY)
            overlaySlider("Độ mờ", vizKFBinding(\.opacity, base: v.opacity), 0...1, "%.2f", reset: 1)

            HStack(spacing: 8) {
                Text(L("Chuyển động")).font(.caption.bold())
                if !vizKF.isEmpty { Text(String(format: L("%d mốc"), vizKF.count)).font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint) }
                Spacer()
                if !vizKF.isEmpty {
                    Button { store.perform(L("Xoá chuyển động sóng")) { store.project.visualizer?.keyframes = [] } }
                        label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Xoá hết"))
                    Button { kfClip.vizFrames = vizKF } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Sao chép"))
                }
                if kfClip.vizFrames != nil {
                    Button {
                        if let src = kfClip.vizFrames {
                            store.perform(L("Dán chuyển động sóng")) { store.project.visualizer?.keyframes = src }
                        }
                    } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).help(L("Dán"))
                }
                KeyframeControl(
                    hasAny: !vizKF.isEmpty, atKeyframe: vizNearIdx != nil,
                    canPrev: vizKF.contains { $0.t < vizSongT - 0.02 },
                    canNext: vizKF.contains { $0.t > vizSongT + 0.02 },
                    onPrev: { if let t = vizKF.map(\.t).filter({ $0 < vizSongT - 0.02 }).max() {
                        seekTo(t + store.project.karaokeClipStart) } },
                    onToggle: {
                        store.perform(L("Keyframe sóng")) {
                            if let ni = vizNearIdx { store.project.visualizer?.keyframes.remove(at: ni) }
                            else { store.project.visualizer?.upsertKeyframe(atSong: vizSongT) }
                        }
                    },
                    onNext: { if let t = vizKF.map(\.t).filter({ $0 > vizSongT + 0.02 }).min() {
                        seekTo(t + store.project.karaokeClipStart) } })
            }
            Text(vizKF.isEmpty
                 ? L("Bấm ◇ để bắt đầu. Rồi dời vạch đỏ + chỉnh cỡ/vị trí/độ mờ (hoặc kéo sóng trên màn hình xem trước) → tự tạo mốc.")
                 : L("Dời vạch đỏ tới lúc khác, chỉnh cỡ/vị trí/độ mờ → tự ghi mốc."))
                .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            overlaySlider("Sáng (glow)", v.glow, 0...1, "%.2f", reset: MusicVisualizer().glow)
            overlaySlider("Độ nhạy", v.sensitivity, 0.3...3, "%.2f", reset: 1)
            overlaySlider("Độ mượt", v.smoothing, 0...1, "%.2f", reset: MusicVisualizer().smoothing)
            DisclosureGroup(L("Màu sắc")) {
                VStack(alignment: .leading, spacing: 5) {
                    Picker(L("Kiểu màu"), selection: v.gradientDir) {
                        ForEach(MusicVisualizer.GradientDir.allCases) { Text($0.label).tag($0) }
                    }.controlSize(.small)
                    if v.wrappedValue.gradientDir == .rainbow {
                        overlaySlider("Dải màu", v.rainbowSpread, 0.2...3, "%.2f")
                        overlaySlider("Xoay màu", v.rainbowShift, 0...1, "%.2f")
                    } else {
                        HStack(spacing: 14) {
                            AppColorField(color: v.wrappedValue.color1, supportsOpacity: false, label: "Màu gốc") {
                                v.wrappedValue.color1 = $0
                            }
                            AppColorField(color: v.wrappedValue.color2, supportsOpacity: false, label: "Màu ngọn") {
                                v.wrappedValue.color2 = $0
                            }
                        }.font(.caption2)
                    }
                    HStack(spacing: 10) {
                        Toggle(L("Glow theo màu gốc"), isOn: v.glowAuto).toggleStyle(.checkbox).font(.caption2)
                        if !v.wrappedValue.glowAuto {
                            AppColorField(color: v.wrappedValue.glowColor, label: "Màu glow") {
                                v.wrappedValue.glowColor = $0
                            }.font(.caption2)
                        }
                    }
                    AppColorField(color: v.wrappedValue.tipColor, label: "Chấm sáng ở ngọn (alpha > 0 để bật)") {
                        v.wrappedValue.tipColor = $0
                    }.font(.caption2)
                }
            }.font(.caption)
            DisclosureGroup(L("Chi tiết")) {
                VStack(alignment: .leading, spacing: 5) {
                    overlaySlider("Số cột", Binding(get: { Double(v.wrappedValue.bandCount) },
                                                    set: { v.wrappedValue.bandCount = Int($0) }), 12...200, "%.0f")
                    overlaySlider("Khe cột", v.barGapFrac, 0...0.85, "%.2f", reset: MusicVisualizer().barGapFrac)
                    overlaySlider("Bo góc", v.cornerRadiusFrac, 0...0.5, "%.2f", reset: MusicVisualizer().cornerRadiusFrac)
                    if v.wrappedValue.style == .segments {
                        overlaySlider("Số đốt", Binding(get: { Double(v.wrappedValue.segCount) },
                                                        set: { v.wrappedValue.segCount = Int($0) }), 4...36, "%.0f")
                    }
                    if v.wrappedValue.style == .radial || v.wrappedValue.style == .radialBlob
                        || v.wrappedValue.style == .radialRing {
                        overlaySlider("Xoay", v.rotation, -180...180, "%.0f", reset: 0)
                    }
                    if v.wrappedValue.style == .waveLine || v.wrappedValue.style == .radialRing {
                        overlaySlider("Nét", v.lineWidthFrac, 0.002...0.03, "%.3f")
                    }
                    if v.wrappedValue.style == .barsMirror || v.wrappedValue.style == .areaGlow {
                        Toggle(L("Đối xứng 2 bên"), isOn: v.mirror).toggleStyle(.checkbox).font(.caption)
                    }
                    Toggle(L("Đè lên trên chữ"), isOn: v.aboveText).toggleStyle(.checkbox).font(.caption)
                }
            }.font(.caption)
        }
        .disabled(!on)
        .opacity(on ? 1 : 0.5)
    }

    func addOverlay() {
        guard let url = FilePanels.chooseBackgroundImage() else { return }
        let dur = playback.duration > 0.5 ? playback.duration : 5
        var clip = OverlayClip(kind: .image, url: url, start: 0, duration: dur)
        clip.lane = freeOverlayLane(start: 0, end: clip.end)
        store.perform(L("Thêm lớp đè")) { store.project.overlays.append(clip) }
        selectedOverlayID = clip.id
    }

    /// Thêm 1 LỚP CHỮ (kind == .text) — hoạt động như lớp ảnh: có clip trên timeline,
    /// kéo–giãn–xoay trên preview, chỉnh nội dung/font/màu ở inspector bên phải.
    func addTextOverlay(at time: TimeInterval? = nil, lane: Int? = nil) {
        let dur = min(playback.duration > 0.5 ? playback.duration : 6, 6)
        // Lớp đè sống theo GIỜ-TIMELINE (không trừ karaokeClipStart như timing lời).
        let ph = time ?? playback.currentTime
        let start = max(0, ph)
        var clip = OverlayClip()
        clip.kind = .text
        clip.name = L("Chữ")
        clip.text = L("Văn bản")
        clip.start = start
        clip.duration = dur
        clip.scale = 1
        clip.aboveText = true
        clip.textColor = store.project.style.textColor
        clip.textFill = .solid(store.project.style.textColor)
        clip.lane = lane ?? freeOverlayLane(start: start, end: start + dur)
        store.perform(L("Thêm lớp chữ")) { store.project.overlays.append(clip) }
        selectedOverlayID = clip.id
    }

    func freeOverlayLane(start: TimeInterval, end: TimeInterval) -> Int {
        for lane in 0..<4 {
            let clash = store.project.overlays.contains {
                $0.lane == lane && $0.start < end && $0.end > start
            }
            if !clash { return lane }
        }
        return 0
    }

    func removeOverlay(_ id: UUID) {
        store.perform(L("Xoá lớp đè")) {
            store.project.overlays.removeAll { $0.id == id }
            pruneOverlayGroups()
        }
        if selectedOverlayID == id { selectedOverlayID = nil }
        selectedOverlayIDs.remove(id)
    }
}
