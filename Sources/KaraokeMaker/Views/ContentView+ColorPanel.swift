import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    // MARK: - C7 · Bảng màu Basic (dùng cho lớp đè + nền)

    @ViewBuilder
    func colorBasicPanel(_ b: Binding<ColorAdjust>, sample: (() -> CGImage?)? = nil,
                                 sampleKeySuffix: String = "") -> some View {
        let dirty = !b.wrappedValue.isIdentity
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.xs) {
                Text(L("MÀU")).sectionHeaderStyle()
                if dirty { Circle().fill(Theme.accent).frame(width: 5, height: 5).help(L("Đã chỉnh màu")) }
                Spacer()
                Button {
                    bypassColor.toggle()
                    ColorPipeline.bypass = bypassColor
                    OverlayImageStore.flush(); BackgroundImageStore.flush()
                } label: { Image(systemName: bypassColor ? "eye.slash" : "eye") }
                    .buttonStyle(KMIconButtonStyle(selected: bypassColor)).help(L("Xem Trước / Sau (tạm tắt chỉnh màu)"))
                Button { copiedColor = b.wrappedValue } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.kmIcon).help(L("Sao chép thông số màu"))
                Button { if let c = copiedColor { b.wrappedValue = c } }
                    label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.kmIcon).disabled(copiedColor == nil).help(L("Dán thông số màu"))
                Menu {
                    Button(L("Lưu preset màu…")) {
                        if let name = TextPrompt.run(title: L("Lưu preset màu"),
                                                     defaultValue: "\(L("Màu")) \(colorPresets.presets.count + 1)") {
                            colorPresets.add(name: name, adjust: b.wrappedValue)
                        }
                    }
                    if !colorPresets.presets.isEmpty {
                        Divider()
                        ForEach(colorPresets.presets) { pr in
                            Button(pr.name) { b.wrappedValue = pr.adjust }
                        }
                        Divider()
                        Menu(L("Xoá preset")) {
                            ForEach(colorPresets.presets) { pr in
                                Button(pr.name, role: .destructive) { colorPresets.delete(pr.id) }
                            }
                        }
                    }
                } label: { Image(systemName: "paintpalette") }
                    .menuStyle(.borderlessButton).frame(width: 24).help(L("Preset màu"))
                Button(L("Về gốc")) { b.wrappedValue = ColorAdjust() }
                    .buttonStyle(.kmSecondarySmall).disabled(!dirty)
            }
            if bypassColor {
                Label(L("Đang xem BẢN GỐC (chỉnh màu tạm tắt)."), systemImage: "eye.slash")
                    .font(Theme.Typo.helper).foregroundStyle(Theme.warning)
            }
            if let sample {
                ColorScopes(provider: sample, key: b.wrappedValue.key + sampleKeySuffix)
            }
            Text(L("ÁNH SÁNG")).font(Theme.Typo.badge).kerning(0.4).foregroundStyle(Theme.inkFaint).padding(.top, Theme.Space.xs)
            colorSlider("Phơi sáng", b.exposure)
            colorSlider("Tương phản", b.contrast)
            colorSlider("Sáng nổi", b.highlights)
            colorSlider("Vùng tối", b.shadows)
            colorSlider("Điểm trắng", b.whites)
            colorSlider("Điểm đen", b.blacks)

            Text(L("MÀU SẮC")).font(Theme.Typo.badge).kerning(0.4).foregroundStyle(Theme.inkFaint).padding(.top, Theme.Space.xs)
                .padding(.top, 2)
            colorSlider("Nhiệt độ", b.temperature, track: [
                Color(red: 0.20, green: 0.45, blue: 1.00), Color(red: 1.00, green: 0.82, blue: 0.20)])
            colorSlider("Sắc màu", b.tint, track: [
                Color(red: 0.20, green: 0.85, blue: 0.30), Color(red: 1.00, green: 0.20, blue: 0.85)])
            colorSlider("Độ rực", b.vibrance)
            colorSlider("Bão hoà", b.saturation, track: [
                Color(white: 0.55), Color(red: 0.95, green: 0.12, blue: 0.12)])

            Text(L("HIỆU ỨNG")).font(Theme.Typo.badge).kerning(0.4).foregroundStyle(Theme.inkFaint).padding(.top, Theme.Space.xs)
                .padding(.top, 2)
            colorSlider("Tối góc", b.vignette, bipolar: false)

            colorSection("ĐƯỜNG CONG", "curve", active: !b.wrappedValue.curves.isIdentity) {
                curvesEditor(b.curves)
            }
            colorSection("HSL / CHỌN MÀU", "hsl", active: !b.wrappedValue.hsl.isIdentity) {
                hslEditor(b.hsl)
            }
            colorSection("LUT", "lut", active: b.wrappedValue.lut?.isActive == true) {
                lutEditor(b)
            }
        }
        .onDisappear { clearColorBypass() }
    }

    func clearColorBypass() {
        guard bypassColor || ColorPipeline.bypass else { return }
        bypassColor = false
        ColorPipeline.bypass = false
        OverlayImageStore.flush(); BackgroundImageStore.flush()
    }

    @ViewBuilder
    func colorSection<C: View>(_ title: String, _ id: String, active: Bool,
                                       @ViewBuilder _ content: () -> C) -> some View {
        let open = colorExpanded.contains(id)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Button {
                if open { colorExpanded.remove(id) } else { colorExpanded.insert(id) }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkFaint).frame(width: 10)
                    Text(L(title)).font(Theme.Typo.badge).kerning(0.4)
                        .foregroundStyle(active ? Theme.ink : Theme.inkDim)
                    // Mục đã chỉnh = chấm nhấn (không chỉ đổi màu chữ).
                    if active { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                    Spacer()
                }
                .frame(height: Theme.ControlH.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }

    // MARK: C8 · Curve editor

    @ViewBuilder
    func curvesEditor(_ b: Binding<ToneCurves>) -> some View {
        let chans = ["Chung", "Đỏ", "Lục", "Lam"]  // keys
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $curveChan) {
                ForEach(0..<4, id: \.self) { Text(L(chans[$0])).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            ToneCurveGraph(curve: curveBinding(b, curveChan))
                .frame(height: 130)
            Button(L("Đường cong về thẳng")) {
                switch curveChan {
                case 1: b.wrappedValue.red = ToneCurve()
                case 2: b.wrappedValue.green = ToneCurve()
                case 3: b.wrappedValue.blue = ToneCurve()
                default: b.wrappedValue.master = ToneCurve()
                }
            }
            .buttonStyle(.kmSecondarySmall)
        }
    }

    func curveBinding(_ b: Binding<ToneCurves>, _ ch: Int) -> Binding<ToneCurve> {
        switch ch {
        case 1: return b.red
        case 2: return b.green
        case 3: return b.blue
        default: return b.master
        }
    }

    // MARK: C9 · HSL editor

    @ViewBuilder
    func hslEditor(_ b: Binding<HSLAdjust>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("", selection: $hslBand) {
                ForEach(0..<8, id: \.self) { Text(HSLAdjust.bandNames[$0]).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small)
            colorSlider("Tông màu", Binding(get: { b.wrappedValue.hue[hslBand] },
                                            set: { b.wrappedValue.hue[hslBand] = $0 }))
            colorSlider("Bão hoà", Binding(get: { b.wrappedValue.sat[hslBand] },
                                           set: { b.wrappedValue.sat[hslBand] = $0 }))
            colorSlider("Sáng", Binding(get: { b.wrappedValue.lum[hslBand] },
                                        set: { b.wrappedValue.lum[hslBand] = $0 }))
            Button(L("Dải này về 0")) {
                b.wrappedValue.hue[hslBand] = 0
                b.wrappedValue.sat[hslBand] = 0
                b.wrappedValue.lum[hslBand] = 0
            }
            .controlSize(.mini)
        }
    }

    // MARK: C10 · LUT

    @ViewBuilder
    func lutEditor(_ b: Binding<ColorAdjust>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let ref = b.wrappedValue.lut, !ref.path.isEmpty {
                HStack {
                    Text(ref.name.isEmpty ? (ref.path as NSString).lastPathComponent : ref.name)
                        .font(.caption2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Bỏ")) { b.wrappedValue.lut = nil }.controlSize(.mini)
                }
                colorSlider("Độ mạnh", Binding(
                    get: { b.wrappedValue.lut?.intensity ?? 1 },
                    set: { b.wrappedValue.lut?.intensity = $0 }), bipolar: false)
            } else {
                Button(L("Chọn file .cube…")) {
                    if let url = FilePanels.chooseLUT() {
                        b.wrappedValue.lut = LUTRef(path: url.path,
                                                   name: url.deletingPathExtension().lastPathComponent,
                                                   intensity: 1)
                    }
                }
                .controlSize(.small)
                Text(L("LUT 3D .cube (áp trong sRGB).")).font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    /// Slider màu: nội bộ −1…1 (hoặc 0…1), hiện −100…100. Bấm đúp = về 0. (vẽ bằng `KMSliderRow` chung)
    func colorSlider(_ label: String, _ v: Binding<Double>, bipolar: Bool = true,
                             track: [Color]? = nil) -> some View {
        KMSliderRow(L(label), v, (bipolar ? -1 : 0)...1, defaultValue: 0, track: track, valueWidth: 30) {
            "\(Int(($0 * 100).rounded()))"
        }
    }

    /// Hàng trượt số (lớp chữ, sóng nhạc…). `reset` = giá trị khi bấm đúp (nil = không có mặc định).
    func overlaySlider(_ label: String, _ value: Binding<Double>,
                               _ range: ClosedRange<Double>, _ fmt: String, reset: Double? = nil) -> some View {
        KMSliderRow(L(label), value, range, defaultValue: reset) { String(format: fmt, $0) }
    }

    /// Hàng "Hiện dần / Mờ dần" — thanh trượt + số giây. Bấm đúp = 0.
    func fadeRow(_ label: String, _ value: Binding<Double>, max maxDur: Double) -> some View {
        KMSliderRow(L(label), value, 0...Swift.max(0.1, maxDur), defaultValue: 0) { String(format: "%.1fs", $0) }
    }

    func overlayBinding(_ id: UUID) -> Binding<OverlayClip>? {
        guard store.project.overlays.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { store.project.overlays.first(where: { $0.id == id }) ?? OverlayClip() },
            set: { newVal in
                store.edit(L("Sửa lớp đè")) {
                    if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                        store.project.overlays[i] = newVal
                    }
                }
            })
    }
}
