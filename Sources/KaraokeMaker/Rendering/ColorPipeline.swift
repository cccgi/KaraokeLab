import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// C1 — Color processing subsystem. 1 transform toán học DUY NHẤT cho preview + export.
///
/// Pipeline (working space = extended-linear sRGB):
///   input → white balance (CITemperatureAndTint) → [kernel: exposure · tonal HL/SH/WH/BL ·
///   contrast S-curve · vibrance · saturation] → vignette → output sRGB.
///
/// Neutral (mọi field = 0) → kernel trả nguyên input; `ImageFX.apply` còn chặn identity ở ngoài.
enum ColorPipeline {

    static let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
    static let outputSpace  = CGColorSpace(name: CGColorSpace.sRGB)

    /// CIContext DÙNG CHUNG (reuse — không tạo mới mỗi khung).
    static let context: CIContext = {
        var opts: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ]
        if let workingSpace { opts[.workingColorSpace] = workingSpace }
        if let outputSpace  { opts[.outputColorSpace]  = outputSpace }
        opts[.workingFormat] = NSNumber(value: CIFormat.RGBAh.rawValue)   // 16-bit float — tránh banding
        return CIContext(options: opts)
    }()

    /// So sánh Trước/Sau: bật → `applyCG` trả nguyên ảnh (bỏ qua chỉnh màu).
    /// `ContentView` phải flush cache + vẽ lại preview khi đổi cờ này.
    static var bypass = false

    /// HDR policy = TONE-MAP xuống SDR. Bắn 1 lần khi gặp nguồn PQ/HLG.
    static let hdrNote = Notification.Name("ColorPipeline.hdrSource")
    private static var hdrWarned = false

    private static func isHDRSpace(_ cs: CGColorSpace?) -> Bool {
        guard let n = cs?.name as String? else { return false }
        return n.contains("2100") || n.contains("PQ") || n.contains("HLG") || n.contains("2020")
    }

    /// Nén nhẹ vùng > 1 (giữ nguyên 0…1) — dùng khi nguồn HDR, vì output là sRGB SDR.
    private static let rolloffKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 kmRoll(__sample s) {
        vec3 c = max(s.rgb, 0.0);
        vec3 over = 1.0 + log(max(c, 1.0)) * 0.45;
        vec3 k = mix(c, over, step(1.0, c));
        return vec4(min(k, 1.7), s.a);
    }
    """)

    // MARK: Kernel

    /// Core Image Kernel Language (legacy string). Chạy TRONG working space (linear).
    /// Tham số theo thang −1…1 (trừ `ev` truyền thẳng EV).
    private static let kernelSource = """
    kernel vec4 kmColor(__sample s, float ev, float con, float hi, float sh,
                        float wh, float bl, float vib, float sat) {
        vec3 rgb = s.rgb;

        // 1) Exposure — nhân sáng tuyến tính theo stop.
        rgb *= pow(2.0, ev);

        // 2) Luminance (Rec.709 linear) + vị trí "cảm nhận" cho mask.
        vec3 lumC = vec3(0.2126, 0.7152, 0.0722);
        float Y = max(dot(rgb, lumC), 0.0);
        float p = sqrt(clamp(Y, 0.0, 1.0));            // ~gamma, để chia vùng tông

        // 3) Mask tông CHỒNG MỀM (không ngưỡng cứng).
        float mSh = 1.0 - smoothstep(0.00, 0.55, p);   // shadows: dải tối rộng
        float mHi = smoothstep(0.45, 1.00, p);         // highlights: dải sáng rộng
        float mBl = 1.0 - smoothstep(0.00, 0.22, p);   // blacks: điểm đen
        float mWh = smoothstep(0.80, 1.00, p);         // whites: điểm trắng

        float Yn = Y;
        Yn *= (1.0 + sh * 0.90 * mSh);
        Yn *= (1.0 + hi * 0.90 * mHi);
        Yn *= (1.0 + bl * 1.10 * mBl);
        Yn *= (1.0 + wh * 0.70 * mWh);

        // 4) Contrast — S-curve luỹ thừa quanh mid-grey linear 0.18 (toe/shoulder mềm, không kẹp 0.5).
        float cg = 1.0 + con;                          // con −1..1 → cg 0..2
        float pv = 0.18;
        float contrasted = pv * pow(max(Yn / pv, 0.0), cg);
        Yn = mix(Yn, contrasted, 0.85);

        // Áp thay đổi luminance NHƯNG giữ hue (scale theo tỉ lệ).
        float scale = Yn / max(Y, 1e-4);
        rgb *= scale;

        // 5) Vibrance (đẩy màu NHẠT nhiều hơn) + Saturation.
        float Y2 = max(dot(rgb, lumC), 1e-4);
        vec3 grey = vec3(Y2);
        float chroma = clamp(length(rgb - grey) / (Y2 + 0.5), 0.0, 1.0);
        float amt = sat + vib * (1.0 - chroma);
        rgb = mix(grey, rgb, clamp(1.0 + amt, 0.0, 3.0));

        return vec4(max(rgb, 0.0), s.a);
    }
    """

    private static let kernel: CIColorKernel? = CIColorKernel(source: kernelSource)

    // MARK: Process

    /// Áp `adj` lên `CIImage` (working space). Trả `CIImage` mới.
    static func process(_ input: CIImage, _ adj: ColorAdjust) -> CIImage {
        if bypass { return input }
        var img = input

        // White balance TRƯỚC (Apple chromatic adaptation — không phải RGB offset).
        if adj.temperature != 0 || adj.tint != 0 {
            let dTemp = adj.temperature * 3200.0        // ±3200K quanh 6500
            // Đảo dấu: user chốt "kéo TRÁI (âm) = ngả LỤC, kéo PHẢI (dương) = ngả HỒNG"
            // (chuẩn Lightroom/CapCut) — trục y thô của CITemperatureAndTint ngược chiều đó.
            let dTint = -adj.tint * 60.0                // trục y
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - dTemp, y: dTint),
            ])
        }

        // Kernel: exposure · tonal · contrast · vibrance · saturation.
        let needsKernel = adj.exposure != 0 || adj.contrast != 0 || adj.highlights != 0
            || adj.shadows != 0 || adj.whites != 0 || adj.blacks != 0
            || adj.vibrance != 0 || adj.saturation != 0
        if needsKernel, let kernel {
            let ev = Float(max(-1, min(1, adj.exposure)) * 4.0)
            let args: [Any] = [
                img,
                ev,
                Float(adj.contrast), Float(adj.highlights), Float(adj.shadows),
                Float(adj.whites), Float(adj.blacks),
                Float(adj.vibrance), Float(adj.saturation),
            ]
            if let out = kernel.apply(extent: img.extent, arguments: args) {
                img = out
            }
        }

        // C8 — Tone curves (bake thành color cube, áp trong sRGB).
        if !adj.curves.isIdentity, let f = curvesFilter(adj.curves) {
            f.setValue(img, forKey: kCIInputImageKey)
            if let out = f.outputImage { img = out }
        }

        // C9 — HSL / selective (kernel, 8 dải overlap mềm).
        if !adj.hsl.isIdentity, let k = hslKernel {
            let h = adj.hsl
            func v4(_ a: [Double], _ i: Int) -> CIVector {
                CIVector(x: CGFloat(a[i]), y: CGFloat(a[i+1]), z: CGFloat(a[i+2]), w: CGFloat(a[i+3]))
            }
            let args: [Any] = [img,
                               v4(h.hue, 0), v4(h.hue, 4),
                               v4(h.sat, 0), v4(h.sat, 4),
                               v4(h.lum, 0), v4(h.lum, 4)]
            if let out = k.apply(extent: img.extent, arguments: args) { img = out }
        }

        // C10 — LUT (.cube) + hoà theo intensity.
        if let ref = adj.lut, ref.isActive, let cube = lutCube(ref.path) {
            cube.setValue(img, forKey: kCIInputImageKey)
            if let lutImg = cube.outputImage, let mixK = mixKernel {
                let t = Float(max(0, min(1, ref.intensity)))
                if let out = mixK.apply(extent: img.extent, arguments: [img, lutImg, t]) { img = out }
            }
        }

        // Vignette (effect, sau cùng).
        if adj.vignette > 0 {
            img = img.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: adj.vignette * 2.0,
                kCIInputRadiusKey: 1.7,
            ])
        }
        return img
    }

    /// Áp `adj` lên `CGImage`, trả `CGImage` (sRGB 8-bit). Dùng cho ảnh nền / lớp đè / khung video.
    static func applyCG(_ cg: CGImage, _ adj: ColorAdjust) -> CGImage {
        if bypass, !isHDRSpace(cg.colorSpace) { return cg }
        let src = CIImage(cgImage: cg)
        var out = bypass ? src : process(src, adj)

        // HDR policy — nguồn PQ/HLG: nén vùng sáng vượt ngưỡng về SDR + báo 1 lần.
        if isHDRSpace(cg.colorSpace) {
            if !hdrWarned {
                hdrWarned = true
                DispatchQueue.main.async { NotificationCenter.default.post(name: hdrNote, object: nil) }
            }
            if let k = rolloffKernel, let r = k.apply(extent: out.extent, arguments: [out]) { out = r }
        }
        let rect = out.extent.isInfinite ? src.extent : out.extent
        return context.createCGImage(out, from: rect,
                                     format: .RGBA8, colorSpace: outputSpace) ?? cg
    }

    // MARK: C8 — Tone curves → color cube

    private static let cubeDim = 32
    private static var curveCache: (key: String, filter: CIFilter)?

    private static func curvesFilter(_ c: ToneCurves) -> CIFilter? {
        if let hit = curveCache, hit.key == c.key { return hit.filter }
        let n = cubeDim
        var data = [Float](repeating: 0, count: n * n * n * 4)
        let inv = 1.0 / Double(n - 1)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = c.red.sample(c.master.sample(Double(ri) * inv))
                    let g = c.green.sample(c.master.sample(Double(gi) * inv))
                    let b = c.blue.sample(c.master.sample(Double(bi) * inv))
                    let o = (bi * n * n + gi * n + ri) * 4
                    data[o] = Float(r); data[o+1] = Float(g); data[o+2] = Float(b); data[o+3] = 1
                }
            }
        }
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(cubeDim, forKey: "inputCubeDimension")
        f.setValue(Data(bytes: data, count: data.count * 4), forKey: "inputCubeData")
        if let sp = outputSpace { f.setValue(sp, forKey: "inputColorSpace") }
        curveCache = (c.key, f)
        return f
    }

    // MARK: C9 — HSL kernel

    private static let hslKernel: CIColorKernel? = CIColorKernel(source: """
    float bandW(float H, float c) {
        float dh = abs(mod(H - c + 540.0, 360.0) - 180.0);
        return 1.0 - smoothstep(25.0, 55.0, dh);
    }
    kernel vec4 kmHSL(__sample s, vec4 h0, vec4 h1, vec4 s0, vec4 s1, vec4 l0, vec4 l1) {
        vec3 rgb = max(s.rgb, 0.0);
        float mx = max(max(rgb.r, rgb.g), rgb.b);
        float mn = min(min(rgb.r, rgb.g), rgb.b);
        float L = (mx + mn) * 0.5;
        float d = mx - mn;
        float H = 0.0; float S = 0.0;
        if (d > 1e-5) {
            S = d / (1.0 - abs(2.0*L - 1.0) + 1e-5);
            if (mx == rgb.r) H = mod((rgb.g - rgb.b)/d, 6.0);
            else if (mx == rgb.g) H = (rgb.b - rgb.r)/d + 2.0;
            else H = (rgb.r - rgb.g)/d + 4.0;
            H = H * 60.0;
            if (H < 0.0) H = H + 360.0;
        }
        float hs = 0.0; float sm = 0.0; float lm = 0.0; float w;
        w = bandW(H,   0.0); hs += w*h0.x; sm += w*s0.x; lm += w*l0.x;
        w = bandW(H,  30.0); hs += w*h0.y; sm += w*s0.y; lm += w*l0.y;
        w = bandW(H,  60.0); hs += w*h0.z; sm += w*s0.z; lm += w*l0.z;
        w = bandW(H, 120.0); hs += w*h0.w; sm += w*s0.w; lm += w*l0.w;
        w = bandW(H, 190.0); hs += w*h1.x; sm += w*s1.x; lm += w*l1.x;
        w = bandW(H, 240.0); hs += w*h1.y; sm += w*s1.y; lm += w*l1.y;
        w = bandW(H, 285.0); hs += w*h1.z; sm += w*s1.z; lm += w*l1.z;
        w = bandW(H, 320.0); hs += w*h1.w; sm += w*s1.w; lm += w*l1.w;
        H = mod(H + hs * 60.0 + 360.0, 360.0);
        S = clamp(S * (1.0 + sm), 0.0, 2.0);
        L = clamp(L * (1.0 + lm * 0.5), 0.0, 1.0);
        float C = (1.0 - abs(2.0*L - 1.0)) * S;
        float Hp = H / 60.0;
        float X = C * (1.0 - abs(mod(Hp, 2.0) - 1.0));
        vec3 o;
        if (Hp < 1.0) o = vec3(C, X, 0.0);
        else if (Hp < 2.0) o = vec3(X, C, 0.0);
        else if (Hp < 3.0) o = vec3(0.0, C, X);
        else if (Hp < 4.0) o = vec3(0.0, X, C);
        else if (Hp < 5.0) o = vec3(X, 0.0, C);
        else o = vec3(C, 0.0, X);
        float m = L - C * 0.5;
        return vec4(o + m, s.a);
    }
    """)

    private static let mixKernel: CIColorKernel? = CIColorKernel(source:
        "kernel vec4 kmMix(__sample a, __sample b, float t){ return vec4(mix(a.rgb, b.rgb, t), a.a); }")

    // MARK: C10 — LUT .cube

    private static var lutCache: (path: String, filter: CIFilter)?

    private static func lutCube(_ path: String) -> CIFilter? {
        if let hit = lutCache, hit.path == path { return hit.filter }
        guard let parsed = parseCube(URL(fileURLWithPath: path)),
              let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(parsed.dim, forKey: "inputCubeDimension")
        f.setValue(parsed.data, forKey: "inputCubeData")
        if let sp = outputSpace { f.setValue(sp, forKey: "inputColorSpace") }
        lutCache = (path, f)
        return f
    }

    /// Parse `.cube` (LUT_3D_SIZE, thứ tự đỏ chạy nhanh nhất — khớp CIColorCube).
    static func parseCube(_ url: URL) -> (dim: Int, data: Data)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var dim = 0
        var vals: [Float] = []
        vals.reserveCapacity(64 * 64 * 64 * 4)
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            let p = line.split(separator: " ").map(String.init)
            if p.first == "LUT_3D_SIZE" {
                dim = Int(p.count > 1 ? p[1] : "0") ?? 0
            } else if p.count == 3, let r = Float(p[0]), let g = Float(p[1]), let b = Float(p[2]) {
                vals.append(r); vals.append(g); vals.append(b); vals.append(1)
            }
        }
        guard dim >= 2, vals.count == dim * dim * dim * 4 else { return nil }
        return (dim, Data(bytes: vals, count: vals.count * 4))
    }

    // MARK: C11 — Histogram (RGB) từ 1 CGImage đã chỉnh màu

    static func histogram(_ cg: CGImage, bins: Int = 128) -> [SIMD3<Float>]? {
        let ci = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIAreaHistogram") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgRect: ci.extent), forKey: "inputExtent")
        f.setValue(bins, forKey: "inputCount")
        f.setValue(1.0, forKey: "inputScale")
        guard let out = f.outputImage else { return nil }
        var buf = [Float](repeating: 0, count: bins * 4)
        context.render(out, toBitmap: &buf, rowBytes: bins * 4 * 4,
                       bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                       format: .RGBAf, colorSpace: nil)
        var mx: Float = 1e-6
        for i in 0..<bins { mx = max(mx, max(buf[i*4], max(buf[i*4+1], buf[i*4+2]))) }
        return (0..<bins).map { SIMD3(buf[$0*4]/mx, buf[$0*4+1]/mx, buf[$0*4+2]/mx) }
    }

    /// C11b — hạ mẫu ảnh (đã chỉnh màu) thành lưới nhỏ RGB [0,1] cho Parade / Vectorscope.
    static func scopeSamples(_ cg: CGImage, cols: Int = 140) -> (px: [SIMD3<Float>], w: Int, h: Int)? {
        let srcW = cg.width, srcH = cg.height
        guard srcW > 0, srcH > 0 else { return nil }
        let w = max(2, min(cols, srcW))
        let h = max(2, Int((Double(w) * Double(srcH) / Double(srcW)).rounded()))
        let scale = CGAffineTransform(scaleX: CGFloat(w) / CGFloat(srcW),
                                      y: CGFloat(h) / CGFloat(srcH))
        let ci = CIImage(cgImage: cg).transformed(by: scale)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        context.render(ci, toBitmap: &buf, rowBytes: w * 4,
                       bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: outputSpace)
        var px = [SIMD3<Float>](); px.reserveCapacity(w * h)
        for i in 0..<(w * h) {
            px.append(SIMD3(Float(buf[i*4]) / 255, Float(buf[i*4+1]) / 255, Float(buf[i*4+2]) / 255))
        }
        return (px, w, h)
    }
}
