import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Kiểm thử nội bộ (không phải tính năng): chạy `alignBySearch` trên 1 file giọng + 1 file lời,
/// in kết quả ra stdout. Gọi: `KaraokeMaker --align-test <vocal.wav> <lyrics.txt>`.
enum AlignTestCLI {
    static func run(vocal: String, lyricsFile: String, mix: String? = nil) {
        setbuf(stdout, nil)
        defer { fflush(stdout) }
        let vurl = URL(fileURLWithPath: vocal)
        let murl = mix.map { URL(fileURLWithPath: $0) }
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: lyricsFile), encoding: .utf8) else {
            FileHandle.standardError.write(Data("khong doc duoc file loi\n".utf8)); return
        }
        let blocks = parseBlocks(raw)
        print("blocks: \(blocks.count) — \(blocks.map { $0.count }) dòng")
        do {
            let aligned = try LocalAligner.alignBySearch(vocalURL: vurl, mixURL: murl, blocks: blocks) { p in
                if Int(p * 100) % 10 == 0 { FileHandle.standardError.write(Data("  \(Int(p*100))%\r".utf8)) }
            }
            FileHandle.standardError.write(Data("\n".utf8))
            // ĐÚNG CHUỖI như app: buildLines → capRunaway → smoothWordGaps → tidyOverlaps
            var (lines, _) = ForcedAligner.buildLines(from: aligned, preroll: 2.0)
            lines = AdvancedKaraoke.capRunaway(lines)
            lines = AdvancedKaraoke.smoothWordGaps(lines)
            lines = AdvancedKaraoke.borrowRepeatRhythm(lines)
            lines = AdvancedKaraoke.tidyOverlaps(lines, songDur: 1e9)
            print("=== \(lines.count) dòng ===")
            var prevE = -1.0
            for (i, l) in lines.enumerated() {
                let s = l.words.first?.start ?? -1
                let e = l.words.last?.end ?? -1
                var bad = ""
                if (e - s) > 10 { bad += "  <<DÀI" }
                if s < prevE - 0.05 { bad += "  <<ĐÈ" }
                print(String(format: "%2d  %7.2f - %7.2f (%4.1fs)  %@%@", i, s, e, e - s, l.text, bad))
                if ProcessInfo.processInfo.environment["KM_WORDS"] != nil {
                    let seg = l.words.map { String(format: "%@[%.2f]", $0.text, ($0.end ?? 0) - ($0.start ?? 0)) }.joined(separator: " ")
                    print("      " + seg)
                }
                prevE = e
            }
        } catch {
            print("LỖI: \(error)")
        }
    }

    /// `KaraokeMaker --separate <mix.wav> <out-vocal.wav> [--hq]` — tách giọng (MDX ONNX) để test.
    static func separate(source: String, vocalOut: String, hq: Bool) {
        setbuf(stdout, nil)
        let src = URL(fileURLWithPath: source)
        let vout = URL(fileURLWithPath: vocalOut)
        let aout = vout.deletingPathExtension().appendingPathExtension("accomp.wav")
        let cfg: MDXSeparator.Config = hq ? .hq : .fast
        print("Tách giọng \(hq ? "HQ/MDX23C" : "nhanh/Voc_FT"): \(src.lastPathComponent) → \(vout.path)")
        do {
            _ = try MDXSeparator.separate(source: src, vocalOut: vout, accompOut: aout, config: cfg) { p in
                FileHandle.standardError.write(Data(String(format: "  %d%%\r", Int(p * 100)).utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
            print("OK vocal: \(vout.path)")
        } catch {
            print("LỖI: \(error)")
            exit(1)
        }
    }

    /// Kiểm thử phổ "sóng nhạc": phân tích + in vài khung + vẽ thử 1 khung ra PNG.
    static func vizProbe(audio: String) {
        setbuf(stdout, nil)
        let url = URL(fileURLWithPath: audio)
        guard let d = SpectrumStore.dataBlocking(for: url) else { print("PHÂN TÍCH LỖI"); return }
        print("frames=\(d.frames.count)  fps=\(d.fps)  bands=\(d.bandCount)  dur≈\(String(format: "%.1f", Double(d.frames.count) / d.fps))s")
        for t in [1.0, 30.0, 60.0, 90.0] where t * d.fps < Double(d.frames.count) {
            let b = d.bands(at: t, want: 16)
            print(String(format: "t=%5.1f  ", t) + b.map { String(format: "%.2f", $0) }.joined(separator: " "))
        }
        let w = 1920, h = 1080
        for (name, style) in [("bars", MusicVisualizer.Style.barsMirror), ("up", .barsUp),
                              ("seg", .segments), ("dots", .dots),
                              ("wave", .waveLine), ("area", .areaGlow),
                              ("radial", .radial), ("blob", .radialBlob)] {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var spec = MusicVisualizer.freshDefault()
            spec.style = style
            VisualizerRenderer.draw(in: ctx, canvasSize: CGSize(width: w, height: h), spec: spec,
                                    bands: d.bands(at: 30.0, want: spec.bandCount), flipped: false)
            if let img = ctx.makeImage(),
               let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: "/tmp/viz_\(name).png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("PNG -> /tmp/viz_\(name).png")
            }
        }
    }

    /// (Dự án "Nhân bản lời thiếu" — M2) Trích chroma/MFCC, in vài khung + vẽ ảnh nhiệt để mắt kiểm.
    static func featProbe(audio: String, vocalCheck: String? = nil) {
        setbuf(stdout, nil)
        let url = URL(fileURLWithPath: audio)
        do {
            let (hop, chroma, mfcc) = try LocalAligner.extractFeatures(vocalURL: url)
            print("frames=\(chroma.count)  hop=\(String(format: "%.3f", hop))s  dur≈\(String(format: "%.1f", Double(chroma.count) * hop))s")
            for t in [10.0, 30.0, 60.0, 90.0, 150.0] {
                let fi = Int(t / hop)
                guard fi >= 0, fi < chroma.count else { continue }
                print(String(format: "t=%6.1f chroma  ", t) + chroma[fi].map { String(format: "%.2f", $0) }.joined(separator: " "))
            }
            heatmapPNG(chroma, path: "/tmp/feat_chroma.png", perRowNorm: false)
            heatmapPNG(mfcc, path: "/tmp/feat_mfcc.png", perRowNorm: true)
            print("PNG -> /tmp/feat_chroma.png (12 hàng), /tmp/feat_mfcc.png (13 hàng)")

            let mixReps = LocalAligner.detectRepeats(chroma: chroma, hopSec: hop)

            let seq = LocalAligner.labelStructure(repeats: mixReps, totalFrames: chroma.count)
            let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
            print("M4 chuỗi cấu trúc: \(seq.count) đoạn")
            for s in seq {
                let name = s.cluster < letters.count ? letters[s.cluster] : "#\(s.cluster)"
                print(String(format: "  %6.1f-%6.1fs  cụm %@ (dài %.1fs)",
                             Double(s.sF) * hop, Double(s.eF) * hop, name, Double(s.eF - s.sF) * hop))
            }

            if let vc = vocalCheck {
                let (hopV, chromaV, _) = try LocalAligner.extractFeatures(vocalURL: URL(fileURLWithPath: vc))
                let vocalReps = LocalAligner.detectRepeats(chroma: chromaV, hopSec: hopV)
                let merged = LocalAligner.combineRepeats(mix: mixReps, vocal: vocalReps)
                print("M3 dò lặp (đối chứng 2 tầng: trộn=\(mixReps.count), giọng=\(vocalReps.count)): \(merged.count) cặp")
                for r in merged {
                    let a0 = Double(r.a) * hop, a1 = Double(r.aEnd) * hop
                    let b0 = Double(r.b) * hop, b1 = Double(r.bEnd) * hop
                    let tag = r.corroborated ? "✓ 2 tầng đồng ý" : (r.source == "chỉ-giọng" ? "⚠ chỉ giọng thấy" : "· chỉ bản trộn")
                    print(String(format: "  [%6.1f-%6.1fs] ~= [%6.1f-%6.1fs]  dài %4.1fs  điểm=%.2f  %@",
                                 a0, a1, b0, b1, a1 - a0, r.score, tag))
                }
            } else {
                print("M3 dò lặp: \(mixReps.count) cặp đoạn (ngưỡng thích ứng theo bài)")
                for r in mixReps {
                    let a0 = Double(r.a) * hop, a1 = Double(r.aEnd) * hop
                    let b0 = Double(r.b) * hop, b1 = Double(r.bEnd) * hop
                    print(String(format: "  [%6.1f-%6.1fs] ~= [%6.1f-%6.1fs]  dài %4.1fs  điểm=%.2f",
                                 a0, a1, b0, b1, a1 - a0, r.score))
                }
            }
            ssmPNG(chroma, path: "/tmp/feat_ssm.png")
            print("PNG -> /tmp/feat_ssm.png (ma trận tự-tương-đồng)")
        } catch {
            print("LOI: \(error)")
        }
    }

    private static func heatmapPNG(_ data: [[Float]], path: String, perRowNorm: Bool) {
        guard !data.isEmpty, let rows = data.first?.count, rows > 0 else { return }
        let cols = data.count
        var norm = data
        if perRowNorm {
            for r in 0..<rows {
                let vals = data.map { $0[r] }
                let mn = vals.min() ?? 0, mx = vals.max() ?? 1
                let span = max(1e-6, mx - mn)
                for c in 0..<cols { norm[c][r] = (data[c][r] - mn) / span }
            }
        } else {
            for c in 0..<cols { for r in 0..<rows { norm[c][r] = max(0, min(1, data[c][r])) } }
        }
        let rowH = 8, w = cols, h = rows * rowH
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for c in 0..<cols {
            for r in 0..<rows {
                let v = CGFloat(norm[c][r])
                ctx.setFillColor(CGColor(srgbRed: v, green: 0.15 + v * 0.75, blue: 1 - v, alpha: 1))
                ctx.fill(CGRect(x: c, y: (rows - 1 - r) * rowH, width: 1, height: rowH))
            }
        }
        if let img = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// Vẽ ma trận tự-tương-đồng (chroma) ra ảnh xám — đường chéo lặp hiện thành vệt sáng ngoài đường chéo chính.
    private static func ssmPNG(_ chroma: [[Float]], path: String) {
        let N = chroma.count
        guard N > 4 else { return }
        let dim = chroma[0].count
        var vecs = chroma
        for i in 0..<N {
            var norm: Float = 0; for v in vecs[i] { norm += v * v }
            norm = sqrt(max(norm, 1e-9)); for k in 0..<dim { vecs[i][k] /= norm }
        }
        // giới hạn cỡ ảnh để nhẹ (lấy mẫu thưa nếu bài dài)
        let maxSide = 1000
        let stride = max(1, N / maxSide)
        let side = (N + stride - 1) / stride
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        for xi in 0..<side {
            let i = min(N - 1, xi * stride)
            for yj in 0..<side {
                let j = min(N - 1, yj * stride)
                var s: Float = 0; for k in 0..<dim { s += vecs[i][k] * vecs[j][k] }
                let v0 = max(0, min(1, CGFloat(s)))
                let v = pow(v0, 8)   // nén tương phản: chỉ đoạn giống RÕ mới sáng, bỏ nền nhiễu nhịp/hợp âm
                ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
                ctx.fill(CGRect(x: xi, y: side - 1 - yj, width: 1, height: 1))
            }
        }
        if let img = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    /// (Dự án "Nhân bản lời thiếu" — M5, CHỈ BÁO CÁO, không đụng kết quả canh giờ thật) Đối chiếu
    /// các dòng lời ĐÃ ĐẶT (từ `alignBySearch` — luồng đang chạy, không đổi) với chuỗi cấu trúc âm
    /// thanh (M3+M4, chạy trên bản trộn gốc) để xem: những đoạn audio còn thiếu lời mà thuộc CÙNG
    /// cụm audio với 1 đoạn đã có lời — có nên vá thêm không, và vá gì.
    static func m5Test(vocal: String, mix: String, lyricsFile: String) {
        setbuf(stdout, nil)
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: lyricsFile), encoding: .utf8) else {
            print("khong doc duoc file loi"); return
        }
        let blocks = parseBlocks(raw)
        let uLines = blocks.flatMap { $0 }
        let sec = LocalAligner.sectionize(uLines)
        func norm(_ s: String) -> String {
            s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "vi_VN")).lowercased()
                .filter { $0.isLetter || $0.isNumber }
        }
        var textToCluster: [String: Int] = [:]
        for s in sec { for u in s.lo...s.hi { textToCluster[norm(uLines[u])] = s.cluster } }
        print("M1: \(sec.count) khối lời, \(Set(sec.map { $0.cluster }).count) cụm")

        do {
            let lines = try LocalAligner.alignBySearch(vocalURL: URL(fileURLWithPath: vocal), blocks: blocks) { _ in }
            print("alignBySearch (luồng hiện tại, KHÔNG đổi): \(lines.count) dòng đã đặt")

            let (hop, chromaMix, _) = try LocalAligner.extractFeatures(vocalURL: URL(fileURLWithPath: mix))
            let reps = LocalAligner.detectRepeats(chroma: chromaMix, hopSec: hop)
            let seq = LocalAligner.labelStructure(repeats: reps, totalFrames: chromaMix.count)
            print("M3+M4 (bản trộn gốc): \(reps.count) cặp lặp -> \(seq.count) đoạn cấu trúc")

            // audioCluster -> cụm lời: đúc từ những chỗ ĐÃ có lời (không đoán, chỉ đọc lại)
            var audioToLyric: [Int: Int] = [:]
            for l in lines {
                guard let s0 = l.words.first?.start, let e0 = l.words.last?.end,
                      let lc = textToCluster[norm(l.text)] else { continue }
                let sF = Int(s0 / hop), eF = Int(e0 / hop)
                for seg in seq where seg.sF < eF && seg.eF > sF {
                    if audioToLyric[seg.cluster] == nil { audioToLyric[seg.cluster] = lc }
                }
            }
            func covered(_ f: Int) -> Bool {
                lines.contains {
                    guard let s0 = $0.words.first?.start, let e0 = $0.words.last?.end else { return false }
                    return f >= Int(s0 / hop) - 2 && f <= Int(e0 / hop) + 2
                }
            }
            var suggested = 0
            for seg in seq {
                guard let lc = audioToLyric[seg.cluster] else { continue }
                guard !covered((seg.sF + seg.eF) / 2) else { continue }
                suggested += 1
                print(String(format: "  ĐỀ XUẤT VÁ: %6.1f-%6.1fs (cụm audio %d, dài %.1fs) <- cụm lời %d",
                             Double(seg.sF) * hop, Double(seg.eF) * hop, seg.cluster,
                             Double(seg.eF - seg.sF) * hop, lc))
            }
            print("Tổng: \(suggested) đoạn audio nên vá thêm lời (BÁO CÁO — chưa áp dụng vào output thật)")
        } catch {
            print("LOI: \(error)")
        }
    }

    // MARK: - (M8) Bộ test hồi quy: chạy CẢ TẬP bài mẫu, so với mốc đã biết đúng.
    // Nguyên tắc: chỉ kiểm tính chất CHUNG (đủ dòng, đơn điệu, không chồng, không lỗ trống
    // lúc đang hát) — không có luật riêng cho bài nào, để bài mới thêm vào tự nhiên được
    // kiểm bằng đúng thước đo đó, không phải sửa test cho từng bài.
    private struct RegressManifest: Decodable {
        struct Song: Decodable {
            let id: String
            let name: String
            let vocal: String
            let lyrics: String
            let mix: String?
            let baselineLines: Int
        }
        let songs: [Song]
    }

    /// `KaraokeMaker --regress-test <manifest.json>` — 1 lệnh chạy hết tập bài mẫu.
    static func regressTest(manifestPath: String) {
        setbuf(stdout, nil)
        let manifestURL = URL(fileURLWithPath: manifestPath)
        let baseDir = manifestURL.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(RegressManifest.self, from: data) else {
            print("Không đọc/parse được manifest: \(manifestPath)"); return
        }

        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

        print("=== HỒI QUY: \(manifest.songs.count) bài (\(manifestPath)) ===")
        var okCount = 0
        for song in manifest.songs {
            let vocalURL = baseDir.appendingPathComponent(song.vocal)
            let lyricsURL = baseDir.appendingPathComponent(song.lyrics)
            guard let raw = try? String(contentsOf: lyricsURL, encoding: .utf8) else {
                print("\(pad(song.id, 6)) LỖI: không đọc được file lời \(lyricsURL.path)"); continue
            }
            let blocks = parseBlocks(raw)
            let mixURL: URL? = song.mix.flatMap { path in
                FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
            if song.mix != nil, mixURL == nil {
                FileHandle.standardError.write(Data("  (\(song.id): không thấy file mix \(song.mix!) — vẫn test phần không-mix)\n".utf8))
            }
            do {
                let lines = try LocalAligner.alignBySearch(vocalURL: vocalURL, mixURL: mixURL, blocks: blocks) { _ in }
                var problems: [String] = []

                // đơn điệu + không chồng: mốc bắt đầu dòng sau phải >= mốc bắt đầu dòng trước;
                // 2 dòng LIỀN NHAU không được đè lên nhau quá 34% dòng ngắn hơn — CÙNG ngưỡng
                // bước (H) trong luồng thật đang dùng để giữ/bỏ, để không báo sai những chỗ
                // app tự coi là "chấp nhận được".
                var overlaps = 0, nonMonotone = 0
                var prevS = -1.0, prevE = -1.0
                for l in lines {
                    let s = l.words.first?.start ?? 0, e = l.words.last?.end ?? s
                    if s < prevS { nonMonotone += 1 }
                    if prevE > 0 {
                        let ov = prevE - s
                        let shorter = min(prevE - prevS, e - s)
                        if ov > 0.34 * max(0.1, shorter) { overlaps += 1 }
                    }
                    prevS = s; prevE = e
                }

                // lỗ trống LIÊN TỤC > 4s NẰM TRONG 1 đoạn đang có hát (không tính nhạc dạo) —
                // đo lỗ LỚN NHẤT bên trong từng đoạn hát, không phải tổng lỗ cả đoạn (1 đoạn
                // hát dài đầy hơi thở ngắn giữa các câu KHÔNG phải là lỗi).
                let samples = try LocalAligner.readSamples(vocalURL)
                let sung = LocalAligner.sungIntervals(samples: samples)
                let covered: [(Double, Double)] = lines.compactMap {
                    guard let s = $0.words.first?.start, let e = $0.words.last?.end else { return nil }
                    return (s, e)
                }.sorted { $0.0 < $1.0 }
                var bigGaps: [String] = []
                for seg in sung where seg.end - seg.start > 1.0 {
                    let clipped = covered.compactMap { c -> (Double, Double)? in
                        let s = max(c.0, seg.start), e = min(c.1, seg.end)
                        return s < e ? (s, e) : nil
                    }.sorted { $0.0 < $1.0 }
                    var cursor = seg.start, maxGap = 0.0
                    for c in clipped {
                        if c.0 > cursor { maxGap = max(maxGap, c.0 - cursor) }
                        cursor = max(cursor, c.1)
                    }
                    maxGap = max(maxGap, seg.end - cursor)
                    if maxGap > 4.0 {
                        bigGaps.append(String(format: "%.0f-%.0fs(lỗ %.0fs)", seg.start, seg.end, maxGap))
                    }
                }

                if overlaps > 0 { problems.append("chồng \(overlaps) chỗ") }
                if nonMonotone > 0 { problems.append("lệch thứ tự \(nonMonotone) chỗ") }
                if !bigGaps.isEmpty { problems.append("lỗ >4s lúc hát: " + bigGaps.joined(separator: "; ")) }
                if lines.count != song.baselineLines { problems.append("dòng \(lines.count) ≠ mốc \(song.baselineLines)") }

                let pass = problems.isEmpty
                if pass { okCount += 1 }
                let status = pass ? "✓ KHỚP" : "✗ LỆCH — " + problems.joined(separator: ", ")
                print("\(pad(song.id, 6)) \(pad(song.name, 24)) dòng=\(pad(String(lines.count), 4)) mốc=\(pad(String(song.baselineLines), 4)) \(status)")
            } catch {
                print("\(pad(song.id, 6)) LỖI: \(error)")
            }
        }
        print("— \(okCount)/\(manifest.songs.count) bài khớp mốc. —")
    }

    private static func parseBlocks(_ raw: String) -> [[String]] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = []; var cur: [String] = []
        func flush() { if !cur.isEmpty { blocks.append(cur); cur = [] } }
        for rl in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rl.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let f = line.first, let l = line.last,
               ((f == "[" && l == "]") || (f == "(" && l == ")")), line.count <= 40 { flush(); continue }
            cur.append(line)
        }
        flush()
        return blocks
    }
}
