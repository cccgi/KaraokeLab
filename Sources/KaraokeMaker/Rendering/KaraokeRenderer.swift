import AppKit
import CoreText

/// Bộ vẽ MỘT khung hình karaoke — dựng bằng Core Text để viền sạch (1 nét, bo góc),
/// hỗ trợ chia dòng thủ công (`\n` trong lời) và quét chữ chạy đúng qua từng dòng.
///
/// Bên gọi thiết lập sẵn hệ toạ độ gốc trên-trái, y hướng xuống, đơn vị = pixel.
enum KaraokeRenderer {

    struct FrameLines {
        var current: LyricLine?
        var next: LyricLine?
        /// != nil khi câu chính ĐÃ HIỆN nhưng CHƯA tới lúc hát (time < mốc hát thật).
        var prerollStart: TimeInterval?
        /// true khi câu chính hiện sớm hơn khá lâu (>2.5s) so với lúc hát → hiện 3-2-1.
        var countdown = false
    }

    /// Các block `[start,end]` đã được `TimingEditor.makeContiguous` làm KHÍT nhau ⇒
    /// gần như lúc nào cũng có 1 câu. Mốc HÁT thật nằm ở `words.first.start`; vệt quét
    /// tự đứng yên tới lúc đó (progress theo `words`).
    /// CHẠY MỖI KHUNG — không cấp phát. GIỮ NGUYÊN như bản ổn định (HEAD): câu "đang chạy"
    /// lấy từ `[start,e)`, đếm ngược khi block có khoảng hở phía trước.
    static func frameLines(in project: KaraokeProject, at time: TimeInterval) -> FrameLines {
        var curIdx = -1
        for i in project.lines.indices {
            let l = project.lines[i]
            guard let s = l.start, let e = l.end else { continue }
            if time >= s && time < e { curIdx = i; break }
        }
        var current = curIdx >= 0 ? project.lines[curIdx] : nil

        var next: LyricLine?
        if curIdx >= 0 {
            var i = curIdx + 1
            while i < project.lines.count {
                if project.lines[i].isTimed { next = project.lines[i]; break }
                i += 1
            }
        } else {
            var bestStart = Double.greatestFiniteMagnitude
            for l in project.lines {
                guard let s = l.start, l.end != nil, s > time, s < bestStart else { continue }
                bestStart = s; next = l
            }
        }

        // Nghỉ giữa 2 câu (không câu nào đang active) NHƯNG có câu kế sắp tới → GIỮ NGUYÊN câu
        // VỪA hát xong (đã hát trọn — progress tự bão hoà = 1) thay vì để trống, cho tới khi câu
        // kế thật sự bắt đầu. Vậy dòng 2 "câu ngắn mượn câu kế" không biến mất giữa chừng, đỡ mất
        // trí nhớ người xem. Chỉ áp khi thật sự có câu VỪA kết thúc SÁT trước mốc hiện tại.
        if current == nil, next != nil {
            var bestEnd = -Double.greatestFiniteMagnitude
            var prevIdx = -1
            for i in project.lines.indices {
                let l = project.lines[i]
                guard let e = l.end, l.start != nil, e <= time, e > bestEnd else { continue }
                bestEnd = e; prevIdx = i
            }
            if prevIdx >= 0 {
                current = project.lines[prevIdx]
                curIdx = prevIdx
            }
        }

        var out = FrameLines(current: current, next: next)
        if curIdx >= 0, let cur = current, let bs = cur.start {
            let vocalStart = cur.words.first?.start ?? bs
            if time < vocalStart {
                out.prerollStart = vocalStart
                let prevBlockEnd = curIdx > 0 ? (project.lines[curIdx - 1].end ?? bs) : -1
                out.countdown = bs > prevBlockEnd + 0.15
            }
        }
        return out
    }

    // MARK: - PREVIEW: kế hoạch vẽ được cache theo dòng

    /// Canvas giữ 1 thể hiện; chỉ dựng lại phần tốn kém khi ĐỔI dòng / đổi style / đổi cỡ.
    final class PreviewPlan {
        fileprivate var lastStyle: KaraokeStyle?
        fileprivate var lastNStyle: KaraokeStyle?
        fileprivate var lastSize: CGSize = .zero
        fileprivate var curID: UUID?
        fileprivate var curSig: Int = 0
        fileprivate var curFillerSig: Int = 0
        fileprivate var nxtSig: Int = 0
        fileprivate var curRows: [Row] = []
        fileprivate var curStatic: NSImage?
        fileprivate var curWordTimes: [(s: Double, e: Double)] = []
        fileprivate var curWordWidths: [CGFloat] = []
        fileprivate var curWordTotal: CGFloat = 0
        fileprivate var curHasWords = false
        fileprivate var nxtID: UUID?
        fileprivate var nxtRows: [Row] = []
        fileprivate var nxtStatic: NSImage?
        // Bản CGImage cho đường XUẤT VIDEO (chạy nền, không NSGraphicsContext).
        fileprivate var curStaticCG: CGImage?
        fileprivate var nxtStaticCG: CGImage?
        public init() {}

        /// Khung bao khối CHỮ CHÍNH (hệ y-down, toạ độ canvas) từ lần vẽ gần nhất —
        /// để Preview làm sáng khi rà chuột / biết vùng kéo.
        var mainBlockRect: CGRect? {
            guard let first = curRows.first else { return nil }
            return curRows.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        }
        /// Khung bao khối CÂU NHẮC (nếu có).
        var nextBlockRect: CGRect? {
            guard let first = nxtRows.first else { return nil }
            return nxtRows.dropFirst().reduce(first.rect) { $0.union($1.rect) }
        }

        /// Xoá cache (khi tắt hẳn lớp chữ — M-F).
        func reset() {
            curID = nil; curSig = 0; curFillerSig = 0; curRows = []; curStatic = nil; curStaticCG = nil
            curWordTimes = []; curWordWidths = []; curWordTotal = 0; curHasWords = false
            nxtID = nil; nxtRows = []; nxtStatic = nil; nxtStaticCG = nil
            lastStyle = nil; lastNStyle = nil; lastSize = .zero
        }
    }

    /// Chữ ký nội dung 1 dòng — đổi khi sửa lời / kéo mốc chữ → buộc dựng lại cache preview.
    fileprivate static func lineSig(_ l: LyricLine) -> Int {
        var h = Hasher()
        h.combine(l.id); h.combine(l.text)
        h.combine(l.start ?? -1); h.combine(l.end ?? -1); h.combine(l.words.count)
        for w in l.words { h.combine(w.text); h.combine(w.start ?? -1); h.combine(w.end ?? -1) }
        return h.finalize()
    }

    /// Biến hình CẢ KHỐI chữ (dời ngang theo `style.horizontalOffset` + keyframe dọc/ngang/cỡ
    /// của `project.textKeyframes`). Áp `saveGState` + translate/scale — bên gọi PHẢI `restoreGState`
    /// đúng 1 lần ở cuối. KHÔNG đụng layout/cache (chỉ là biến hình sau khi vẽ).
    private static func applyBlockKF(_ cg: CGContext, project: KaraokeProject, style: KaraokeStyle,
                                    t: TimeInterval, canvasSize: CGSize) {
        let baseA = style.verticalAnchor, baseH = style.horizontalOffset
        let kf = project.textBlockTransform(atSong: t, baseAnchor: baseA, baseHOffset: baseH)
        let hOff = CGFloat(kf.hOffset) * canvasSize.width
        let dyA = CGFloat(kf.anchor - baseA) * canvasSize.height
        let fs = CGFloat(kf.fontScale)
        cg.saveGState()
        if abs(fs - 1) > 0.001 {
            // phóng quanh điểm neo của khối (giữ chữ đứng yên tại vị trí, chỉ đổi cỡ).
            let cx = canvasSize.width / 2 + hOff
            let cy = CGFloat(baseA) * canvasSize.height + dyA
            cg.translateBy(x: cx, y: cy); cg.scaleBy(x: fs, y: fs); cg.translateBy(x: -cx, y: -cy)
        }
        if hOff != 0 || dyA != 0 { cg.translateBy(x: hOff, y: dyA) }
    }

    /// Bản PREVIEW cực nhẹ: dựng kế hoạch 1 lần/dòng, mỗi khung chỉ dán ảnh + tô phần đang hát.
    static func drawPreview(in cg: CGContext, canvasSize: CGSize, project: KaraokeProject,
                            time: TimeInterval, plan: PreviewPlan, nextLineDY: CGFloat = 0) {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        if project.lyricsHidden { plan.reset(); return }   // M-F — ẩn hẳn lớp chữ

        // Bù tinh chỉnh đồng bộ cả bài (mặc định 0). Vệt quét vẫn khoá theo mốc thật.
        let t = time - project.followOffset

        let resScale = Double(min(canvasSize.width, canvasSize.height)) / 1080.0
        let style = project.style.scaled(by: resScale)
        let nStyle = project.nextLineStyle.scaled(by: resScale)
        let marginX = canvasSize.width * CGFloat(style.horizontalMarginRatio)
        let maxWidth = max(10, canvasSize.width - marginX * 2)

        // So sánh struct (rẻ) thay vì dựng chuỗi khoá mỗi khung.
        if plan.lastStyle != style || plan.lastNStyle != nStyle || plan.lastSize != canvasSize {
            plan.lastStyle = style
            plan.lastNStyle = nStyle
            plan.lastSize = canvasSize
            plan.curID = nil
            plan.nxtID = nil
        }

        let lines = frameLines(in: project, at: t)

        // Dời / phóng CẢ KHỐI chữ (ngang + keyframe dọc/cỡ) — KHÔNG đụng layout → không rebuild cache.
        _ = applyBlockKF(cg, project: project, style: style, t: t, canvasSize: canvasSize)

        // ----- Câu chính -----
        // "Luôn 2 dòng": mượn câu kế tiếp làm dòng 2 khi câu chính ngắn.
        // "Luôn 2 dòng" giờ là THUỘC TÍNH CHẾ ĐỘ (`style.alwaysTwoRows`) — preset "Karaoke" bật,
        // "Lyric" tắt (chỉ 1 dòng). Không còn ép cứng cho mọi style.
        let fillerText: String? = style.alwaysTwoRows ? lines.next?.text : nil
        let fillerSig = fillerText?.hashValue ?? 0
        if let cur = lines.current {
            let sig = Self.lineSig(cur)
            if plan.curID != cur.id || plan.curSig != sig || plan.curFillerSig != fillerSig {
                plan.curID = cur.id
                plan.curSig = sig
                plan.curFillerSig = fillerSig
                plan.curRows = buildRows(cur.text, style: style, canvasSize: canvasSize,
                                         maxWidth: maxWidth, marginX: marginX,
                                         anchorY: CGFloat(style.verticalAnchor),
                                         fillerText: fillerText)
                plan.curStatic = renderStatic(rows: plan.curRows, style: style, canvasSize: canvasSize)
                plan.curHasWords = cur.hasWordTiming
                if cur.hasWordTiming {
                    plan.curWordTimes = cur.words.map { ($0.start ?? -1, $0.end ?? -1) }
                    let (w, tot) = measureWordWidths(cur.words, style: style)
                    plan.curWordWidths = w
                    plan.curWordTotal = tot
                } else {
                    plan.curWordTimes = []; plan.curWordWidths = []; plan.curWordTotal = 0
                }
            }
            let progress = plan.curHasWords
                ? cachedWordProgress(times: plan.curWordTimes, widths: plan.curWordWidths,
                                     total: plan.curWordTotal, time: t)
                : wipeProgress(line: cur, time: t)
            let sungCol: CGColor? = cur.singer.map { role in
                cgColor(project.singerColors[role.rawValue] ?? SingerRole.defaultColor(role), 1)
            }
            let full = CGRect(origin: .zero, size: canvasSize)
            if let xf = effectXform(line: cur, style: style, rows: plan.curRows, time: t) {
                // Lưu/khôi phục qua NSGraphicsContext (không phải cg.saveGState thô) để
                // `NSImage.draw(in:)` KHÔNG bị lật ngược trong view isFlipped.
                NSGraphicsContext.current?.saveGraphicsState()
                applyEffect(xf, to: cg)
                plan.curStatic?.draw(in: full, from: .zero, operation: .sourceOver, fraction: xf.alpha)
                wipeHighlight(cg: cg, rows: plan.curRows, style: style, progress: progress, sungColor: sungCol)
                NSGraphicsContext.current?.restoreGraphicsState()
            } else {
                plan.curStatic?.draw(in: full)
                wipeHighlight(cg: cg, rows: plan.curRows, style: style, progress: progress, sungColor: sungCol)
            }

            // Nghỉ dài / câu đầu: 3 chấm đếm ngược 3-2-1 phía trên chữ đầu câu chính.
            if lines.countdown, let ps = lines.prerollStart {
                drawCountdownDots(cg: cg, rows: plan.curRows, style: style, secondsLeft: ps - t)
            }
            // Đánh dấu người hát: icon phía TRÊN dấu 3 chấm, hiện suốt câu.
            if let role = cur.singer, let first = plan.curRows.first {
                drawSingerIcon(role, cg: cg, aboveRow: first, style: style,
                               tint: sungCol ?? cgColor(style.highlightColor, 1))
            }
        } else {
            plan.curID = nil
        }

        // ("Nhắc câu tiếp theo" đã gỡ 2026-09-09 — thay bằng "Luôn 2 dòng" ở câu chính.)
        _ = nextLineDY
        plan.nxtID = nil; plan.nxtRows = []; plan.nxtStatic = nil
        cg.restoreGState()   // hOff
    }

    /// Icon người hát (VECTOR, tô màu `tint` = màu vai đã chọn) — phía TRÊN dấu 3 chấm, canh mép
    /// trái, GIỮ tỉ lệ. Context y-XUỐNG nên vẽ path thẳng, không cần lật.
    private static func drawSingerIcon(_ role: SingerRole, cg: CGContext, aboveRow first: Row,
                                       style: KaraokeStyle, tint: CGColor) {
        let dotR = max(2, CGFloat(style.fontSize) * 0.11)
        let boxH = max(16, CGFloat(style.fontSize) * 1.15)
        let w = boxH * SingerIcon.aspect(role)
        let bottom = first.rect.minY - CGFloat(style.fontSize) * 0.16 - dotR * 2 - dotR * 1.5
        let rect = CGRect(x: first.x, y: bottom - boxH, width: w, height: boxH)
        SingerIcon.draw(role, in: cg, rect: rect, color: tint)
    }

    /// 3 chấm ĐẾM NGƯỢC (3→2→1) phía trên chữ đầu tiên — báo còn mấy giây nữa vào nhịp.
    private static func drawCountdownDots(cg: CGContext, rows: [Row], style: KaraokeStyle,
                                          secondsLeft: Double) {
        guard let first = rows.first, secondsLeft > 0 else { return }
        let n = min(3, max(1, Int(ceil(secondsLeft))))
        let r = max(2, CGFloat(style.fontSize) * 0.11)
        let gap = r * 3.0
        let y = first.rect.minY - r - CGFloat(style.fontSize) * 0.16
        let x0 = first.x + r
        cg.saveGState()
        for k in 0..<n {
            let rect = CGRect(x: x0 + CGFloat(k) * gap - r, y: y - r, width: r * 2, height: r * 2)
            if style.outlineEnabled {
                cg.setLineWidth(max(1, CGFloat(style.outlineWidth) * 0.5))
                cg.setStrokeColor(cgColor(style.outlineColor, 1))
                cg.strokeEllipse(in: rect)
            }
            cg.setFillColor(cgColor(style.highlightColor, 1))
            cg.fillEllipse(in: rect)
        }
        cg.restoreGState()
    }

    private static func renderStatic(rows: [Row], style: KaraokeStyle, canvasSize: CGSize) -> NSImage {
        let img = NSImage(size: canvasSize)
        img.lockFocusFlipped(true)
        if let ctx = NSGraphicsContext.current?.cgContext {
            drawBlock(cg: ctx, rows: rows, style: style, alpha: 1, wipe: false, progress: 0, canvasSize: canvasSize)
        }
        img.unlockFocus()
        return img
    }

    /// Như `renderStatic` nhưng ra CGImage bằng CGContext thuần — an toàn khi chạy nền
    /// (xuất video), không cần NSGraphicsContext / NSImage.lockFocus.
    private static func renderStaticCG(rows: [Row], style: KaraokeStyle, canvasSize: CGSize) -> CGImage? {
        let w = Int(canvasSize.width.rounded()), h = Int(canvasSize.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(true)
        // Khớp hệ toạ độ mà drawBlock mong đợi: y-DOWN, gốc trên-trái (như view lật).
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        drawBlock(cg: ctx, rows: rows, style: style, alpha: 1, wipe: false, progress: 0, canvasSize: canvasSize)
        return ctx.makeImage()
    }

    /// Dán ảnh tĩnh (đã dựng ở hệ y-DOWN) vào context xuất video (cũng y-DOWN):
    /// lật tạm về y-UP để `cg.draw` đặt ảnh đúng chiều.
    private static func blitStaticCG(_ img: CGImage?, in cg: CGContext, canvasSize: CGSize) {
        guard let img else { return }
        cg.saveGState()
        cg.translateBy(x: 0, y: canvasSize.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: CGRect(origin: .zero, size: canvasSize))
        cg.restoreGState()
    }

    /// Đường XUẤT VIDEO — như `drawPreview` (bake chữ tĩnh 1 lần/câu, mỗi khung chỉ
    /// dán ảnh + tô phần đang hát) nhưng dùng CGImage, an toàn chạy nền.
    static func drawExport(in cg: CGContext, canvasSize: CGSize, project: KaraokeProject,
                           time: TimeInterval, plan: PreviewPlan) {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        if project.lyricsHidden { return }   // M-F
        cg.setShouldAntialias(true)
        cg.setShouldSmoothFonts(true)

        let t = time - project.followOffset
        let resScale = Double(min(canvasSize.width, canvasSize.height)) / 1080.0
        let style = project.style.scaled(by: resScale)
        let nStyle = project.nextLineStyle.scaled(by: resScale)
        let marginX = canvasSize.width * CGFloat(style.horizontalMarginRatio)
        let maxWidth = max(10, canvasSize.width - marginX * 2)

        if plan.lastStyle != style || plan.lastNStyle != nStyle || plan.lastSize != canvasSize {
            plan.lastStyle = style
            plan.lastNStyle = nStyle
            plan.lastSize = canvasSize
            plan.curID = nil
            plan.nxtID = nil
        }

        let lines = frameLines(in: project, at: t)

        _ = applyBlockKF(cg, project: project, style: style, t: t, canvasSize: canvasSize)

        // "Luôn 2 dòng" giờ là THUỘC TÍNH CHẾ ĐỘ (`style.alwaysTwoRows`) — preset "Karaoke" bật,
        // "Lyric" tắt (chỉ 1 dòng). Không còn ép cứng cho mọi style.
        let fillerText: String? = style.alwaysTwoRows ? lines.next?.text : nil
        let fillerSig = fillerText?.hashValue ?? 0
        if let cur = lines.current {
            let sig = Self.lineSig(cur)
            if plan.curID != cur.id || plan.curSig != sig || plan.curFillerSig != fillerSig || plan.curStaticCG == nil {
                plan.curID = cur.id
                plan.curSig = sig
                plan.curFillerSig = fillerSig
                plan.curRows = buildRows(cur.text, style: style, canvasSize: canvasSize,
                                         maxWidth: maxWidth, marginX: marginX,
                                         anchorY: CGFloat(style.verticalAnchor),
                                         fillerText: fillerText)
                plan.curStaticCG = renderStaticCG(rows: plan.curRows, style: style, canvasSize: canvasSize)
            }
            let progress = cur.hasWordTiming
                ? wordWipeProgress(words: cur.words, style: style, time: t)
                : wipeProgress(line: cur, time: t)
            let sungCol: CGColor? = cur.singer.map { role in
                cgColor(project.singerColors[role.rawValue] ?? SingerRole.defaultColor(role), 1)
            }
            if let xf = effectXform(line: cur, style: style, rows: plan.curRows, time: t) {
                cg.saveGState()
                applyEffect(xf, to: cg)
                blitStaticCG(plan.curStaticCG, in: cg, canvasSize: canvasSize)
                wipeHighlight(cg: cg, rows: plan.curRows, style: style, progress: progress, sungColor: sungCol)
                cg.restoreGState()
            } else {
                blitStaticCG(plan.curStaticCG, in: cg, canvasSize: canvasSize)
                wipeHighlight(cg: cg, rows: plan.curRows, style: style, progress: progress, sungColor: sungCol)
            }
            if lines.countdown, let ps = lines.prerollStart {
                drawCountdownDots(cg: cg, rows: plan.curRows, style: style, secondsLeft: ps - t)
            }
            if let role = cur.singer, let first = plan.curRows.first {
                drawSingerIcon(role, cg: cg, aboveRow: first, style: style,
                               tint: sungCol ?? cgColor(style.highlightColor, 1))
            }
        } else {
            plan.curID = nil
        }

        // ("Nhắc câu tiếp theo" đã gỡ 2026-09-09.)
        plan.nxtID = nil; plan.nxtRows = []; plan.nxtStaticCG = nil
        cg.restoreGState()   // hOff
    }

    private static func measureWordWidths(_ words: [LyricWord], style: KaraokeStyle) -> ([CGFloat], CGFloat) {
        var attrs: [NSAttributedString.Key: Any] = [.font: resolvedFont(style)]
        if style.characterSpacing != 0 { attrs[.kern] = CGFloat(style.characterSpacing) }
        var w: [CGFloat] = []; w.reserveCapacity(words.count)
        var total: CGFloat = 0
        for word in words {
            let str = style.textCase.apply(to: word.text) + " "
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
            let width = max(1, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
            w.append(width); total += width
        }
        return (w, total)
    }

    private static func cachedWordProgress(times: [(s: Double, e: Double)], widths: [CGFloat],
                                           total: CGFloat, time: TimeInterval) -> Double {
        guard total > 0 else { return 1 }
        var sung: CGFloat = 0
        for i in times.indices {
            let (ws, we) = times[i]
            guard ws >= 0 else { break }
            if we > ws {
                if time >= we { sung += widths[i] }
                else if time > ws { sung += widths[i] * CGFloat((time - ws) / (we - ws)); break }
                else { break }
            } else {
                if time >= ws { sung += widths[i] } else { break }
            }
        }
        return Double(min(sung / total, 1))
    }

    // MARK: - Entry

    static func draw(in cg: CGContext, canvasSize: CGSize, project: KaraokeProject, time: TimeInterval) {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return }
        cg.saveGState()
        cg.setAllowsAntialiasing(true)
        cg.setShouldAntialias(true)
        cg.setShouldSmoothFonts(true)

        // Quy chiếu theo khung 1080: nhân mọi thông số pixel để chữ giữ nguyên tỉ lệ
        // ở mọi độ phân giải (1080 / 2K / 4K / dọc / vuông).
        // Bù tinh chỉnh đồng bộ cả bài (mặc định 0). Vệt quét vẫn khoá theo mốc thật.
        let t = time - project.followOffset

        let resScale = Double(min(canvasSize.width, canvasSize.height)) / 1080.0
        let style = project.style.scaled(by: resScale)
        let marginX = canvasSize.width * CGFloat(style.horizontalMarginRatio)
        let maxWidth = max(10, canvasSize.width - marginX * 2)
        let lines = frameLines(in: project, at: t)

        let hOff = CGFloat(style.horizontalOffset) * canvasSize.width
        if hOff != 0 { cg.translateBy(x: hOff, y: 0) }

        if let current = lines.current {
            let progress = current.hasWordTiming
                ? wordWipeProgress(words: current.words, style: style, time: t)
                : wipeProgress(line: current, time: t)
            // "Luôn 2 dòng" giờ là THUỘC TÍNH CHẾ ĐỘ (`style.alwaysTwoRows`) — preset "Karaoke" bật,
        // "Lyric" tắt (chỉ 1 dòng). Không còn ép cứng cho mọi style.
        let fillerText: String? = style.alwaysTwoRows ? lines.next?.text : nil
            let rows = buildRows(current.text, style: style, canvasSize: canvasSize,
                                 maxWidth: maxWidth, marginX: marginX,
                                 anchorY: CGFloat(style.verticalAnchor), fillerText: fillerText)
            drawBlock(cg: cg, rows: rows, style: style, alpha: 1, wipe: true, progress: progress, canvasSize: canvasSize)
            if lines.countdown, let ps = lines.prerollStart {
                drawCountdownDots(cg: cg, rows: rows, style: style, secondsLeft: ps - t)
            }
        }

        cg.restoreGState()
    }

    /// Hiệu ứng chữ VÀO/RA: trả (alpha, dời, phóng, tâm). nil = không hiệu ứng.
    /// "Hiệu ứng chữ vào / ra" đã BỎ HẲN (2026-09-09) — luôn trả nil (không biến hình).
    private static func effectXform(line: LyricLine, style: KaraokeStyle, rows: [Row],
                                    time: TimeInterval)
        -> (alpha: CGFloat, dx: CGFloat, dy: CGFloat, scale: CGFloat, center: CGPoint)? {
        nil
    }

    private static func applyEffect(
        _ xf: (alpha: CGFloat, dx: CGFloat, dy: CGFloat, scale: CGFloat, center: CGPoint)?,
        to cg: CGContext) {
        guard let xf else { return }
        cg.setAlpha(xf.alpha)
        if xf.scale != 1 {
            cg.translateBy(x: xf.center.x, y: xf.center.y)
            cg.scaleBy(x: xf.scale, y: xf.scale)
            cg.translateBy(x: -xf.center.x, y: -xf.center.y)
        }
        if xf.dx != 0 || xf.dy != 0 { cg.translateBy(x: xf.dx, y: xf.dy) }
    }

    /// Tô phần chữ ĐANG hát — chạy mỗi khung, PHẢI RẺ (không cấp phát).
    /// `sungColor` != nil → màu riêng của câu (đánh dấu người hát).
    private static func wipeHighlight(cg: CGContext, rows: [Row], style: KaraokeStyle,
                                     progress: Double, sungColor: CGColor? = nil) {
        // Dòng "mượn" (câu kế tiếp) KHÔNG tính vào vệt quét.
        let total = rows.reduce(CGFloat(0)) { $0 + ($1.isFiller ? 0 : $1.width) }
        guard total > 0 else { return }
        let sung = total * CGFloat(clamp(progress, 0, 1))
        // Gradient chỉ dùng khi KHÔNG có màu người-hát riêng (song ca) & chưa hát là gradient.
        let hlFill = style.highlightFill
        let useGradient = sungColor == nil && !(hlFill.isSolid || hlFill.color == hlFill.color2)
        let highlight = sungColor ?? cgColor(hlFill.flatColor, 1)

        let ow: CGFloat = (style.outlineEnabled && style.outlineWidth > 0) ? CGFloat(style.outlineWidth) : 0
        let fancy = style.softWipe || style.wipeGlow
            || (ow > 0 && style.outlineColorSung != style.outlineColor)

        var cursor: CGFloat = 0
        for r in rows where !r.isFiller {
            let rowSung = max(0, min(r.width, sung - cursor))
            if rowSung > 0.5 {
                if fancy {
                    wipeRowFancy(cg, r, style: style, rowSung: rowSung, highlight: highlight, ow: ow)
                } else if useGradient {
                    cg.saveGState()
                    cg.clip(to: CGRect(x: r.x, y: r.rect.minY, width: rowSung, height: r.rect.height))
                    var xf = CGAffineTransform(translationX: r.x, y: r.baselineY).scaledBy(x: 1, y: -1)
                    if let gp = r.path.copy(using: &xf) {
                        cg.addPath(gp); cg.clip()
                        hlFill.fill(rect: r.rect, in: cg)
                    }
                    cg.restoreGState()
                } else {
                    // Đường nhanh — giống hệt bản gốc, 0 cấp phát.
                    cg.saveGState()
                    cg.clip(to: CGRect(x: r.x, y: r.rect.minY, width: rowSung, height: r.rect.height))
                    cg.translateBy(x: r.x, y: r.baselineY)
                    cg.scaleBy(x: 1, y: -1)
                    cg.addPath(r.path)
                    cg.setFillColor(highlight)
                    cg.fillPath()
                    cg.restoreGState()
                }
            }
            cursor += r.width
        }
    }

    /// Nhánh CHẬM: chỉ khi bật mép mềm / vệt sáng / viền-hát khác màu.
    private static func wipeRowFancy(_ cg: CGContext, _ r: Row, style: KaraokeStyle,
                                     rowSung: CGFloat, highlight: CGColor, ow: CGFloat) {
        var xform = CGAffineTransform(translationX: r.x, y: r.baselineY).scaledBy(x: 1, y: -1)
        guard let gp = r.path.copy(using: &xform) else { return }
        let feather: CGFloat = style.softWipe ? max(8, CGFloat(style.fontSize) * 0.5) : 0

        cg.saveGState()
        cg.clip(to: CGRect(x: r.x - ow * 1.5, y: r.rect.minY - ow * 2,
                           width: rowSung + ow * 1.5, height: r.rect.height + ow * 4))
        if ow > 0, style.outlineColorSung != style.outlineColor {
            cg.addPath(gp)
            cg.setLineWidth(ow * 2); cg.setLineJoin(.round); cg.setLineCap(.round)
            cg.setStrokeColor(cgColor(style.outlineColorSung, 1))
            cg.strokePath()
        }
        cg.addPath(gp); cg.clip()
        if feather > 1, rowSung < r.width - 1 {
            let clear = highlight.copy(alpha: 0) ?? CGColor(gray: 0, alpha: 0)
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [highlight, clear] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(g, start: CGPoint(x: r.x + max(0, rowSung - feather), y: r.rect.midY),
                                  end: CGPoint(x: r.x + rowSung, y: r.rect.midY),
                                  options: [.drawsBeforeStartLocation])
        } else {
            cg.setFillColor(highlight)
            cg.fill(CGRect(x: r.x, y: r.rect.minY, width: rowSung, height: r.rect.height))
        }
        cg.restoreGState()

        if style.wipeGlow, rowSung < r.width - 1 {
            cg.saveGState()
            cg.setShadow(offset: .zero, blur: max(6, CGFloat(style.fontSize) * 0.35),
                         color: highlight.copy(alpha: 0.9))
            cg.setFillColor(highlight.copy(alpha: 0.9) ?? highlight)
            cg.fill(CGRect(x: r.x + rowSung - 1.5, y: r.rect.minY + 2, width: 3, height: r.rect.height - 4))
            cg.restoreGState()
        }
    }

    /// Quét line-level (dòng KHÔNG có `words`): chạy tuyến tính trên `[start,end]`.
    /// Dòng có `words` (đường AI) thì dùng `cachedWordProgress` — tự đứng yên tới
    /// khi `words.first.start` (mốc hát thật) rồi mới chạy.
    private static func wipeProgress(line: LyricLine, time: TimeInterval) -> Double {
        guard let s = line.start, let e = line.end, e > s else { return 1 }
        return clamp((time - s) / (e - s), 0, 1)
    }

    /// Tiến độ quét theo TIMING TỪNG CHỮ: mỗi chữ sáng dần trong khoảng riêng.
    /// Trả về phần bề rộng đã hát / tổng bề rộng (đo theo font hiện tại).
    private static let wwLock = NSLock()
    private static var wwCache: [String: (widths: [CGFloat], total: CGFloat)] = [:]

    private static func wordWipeProgress(words: [LyricWord], style: KaraokeStyle, time: TimeInterval) -> Double {
        // Bề rộng từng chữ KHÔNG đổi giữa các khung — cache theo chữ + font.
        let key = words.map { $0.text }.joined(separator: "\u{1}")
            + "|\(style.fontName)|\(Int(style.fontSize))|\(style.fontBold)|\(style.fontItalic)"
            + "|\(style.textCase.rawValue)|\(Int(style.characterSpacing * 10))"

        let widths: [CGFloat]
        let total: CGFloat
        wwLock.lock()
        let hit = wwCache[key]
        wwLock.unlock()
        if let hit {
            widths = hit.widths; total = hit.total
        } else {
            var attrs: [NSAttributedString.Key: Any] = [.font: resolvedFont(style)]
            if style.characterSpacing != 0 { attrs[.kern] = CGFloat(style.characterSpacing) }
            var w: [CGFloat] = []; w.reserveCapacity(words.count)
            var t: CGFloat = 0
            for word in words {
                let str = style.textCase.apply(to: word.text) + " "
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: str, attributes: attrs))
                let width = max(1, CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil)))
                w.append(width); t += width
            }
            widths = w; total = t
            wwLock.lock()
            if wwCache.count > 48 { wwCache.removeAll(keepingCapacity: true) }
            wwCache[key] = (w, t)
            wwLock.unlock()
        }
        guard total > 0 else { return 1 }

        var sung: CGFloat = 0
        for (i, w) in words.enumerated() {
            guard let ws = w.start else { break }
            if let we = w.end, we > ws {
                if time >= we { sung += widths[i] }
                else if time > ws { sung += widths[i] * CGFloat((time - ws) / (we - ws)); break }
                else { break }
            } else {
                if time >= ws { sung += widths[i] } else { break }
            }
        }
        return Double(min(sung / total, 1))
    }

    // MARK: - Dựng dòng (Core Text)

    fileprivate struct Row {
        let path: CGPath        // baseline-relative, y-up, đã scale
        let x: CGFloat          // mép trái trên màn hình
        let baselineY: CGFloat
        let width: CGFloat
        let rect: CGRect        // (x, rowTop, width, lineHeight) trong hệ y-down
        let underline: Bool
        /// Dòng "mượn" câu kế tiếp để khung luôn 2 dòng — vẽ tĩnh (màu chưa hát),
        /// KHÔNG bao giờ bị vệt quét chạy qua.
        var isFiller: Bool = false
    }

    // Cache path glyph theo dòng — path không đổi giữa các khung, chỉ vùng quét đổi.
    // Giúp xuất video nhanh hơn nhiều (mỗi câu dựng path 1 lần thay vì mỗi khung).
    private static let rowCacheLock = NSLock()
    private static var rowCache: [String: [Row]] = [:]

    private static func rowCacheKey(_ rawText: String, _ style: KaraokeStyle,
                                    _ canvasSize: CGSize, _ maxWidth: CGFloat,
                                    _ marginX: CGFloat, _ anchorY: CGFloat, _ fillerText: String?) -> String {
        let s = style
        return [rawText, "→\(fillerText ?? "")", s.fontName, "\(s.fontSize)", "\(s.fontBold)", "\(s.fontItalic)",
                "\(s.fontUnderline)", s.textCase.rawValue, "\(s.characterSpacing)",
                "\(s.lineSpacing)", s.alignment.rawValue,
                "\(Int(maxWidth))", "\(Int(marginX))", "\(Int(anchorY * 10000))",
                "\(Int(canvasSize.width))x\(Int(canvasSize.height))"].joined(separator: "\u{1}")
    }

    /// `fillerText` != nil + câu chính chỉ 1 dòng ⇒ mượn dòng đầu của `fillerText` làm
    /// dòng 2 (đánh dấu `isFiller`, KHÔNG quét). Câu chính đã ≥ 2 dòng ⇒ bỏ qua filler.
    private static func buildRows(
        _ rawText: String, style: KaraokeStyle,
        canvasSize: CGSize, maxWidth: CGFloat, marginX: CGFloat, anchorY: CGFloat,
        fillerText: String? = nil
    ) -> [Row] {
        let key = rowCacheKey(rawText, style, canvasSize, maxWidth, marginX, anchorY, fillerText)
        rowCacheLock.lock()
        let cached = rowCache[key]
        rowCacheLock.unlock()
        if let cached { return cached }

        let rows = buildRowsUncached(rawText, style: style, canvasSize: canvasSize,
                                     maxWidth: maxWidth, marginX: marginX, anchorY: anchorY,
                                     fillerText: fillerText)
        rowCacheLock.lock()
        if rowCache.count > 64 { rowCache.removeAll(keepingCapacity: true) }
        rowCache[key] = rows
        rowCacheLock.unlock()
        return rows
    }

    private static func buildRowsUncached(
        _ rawText: String, style: KaraokeStyle,
        canvasSize: CGSize, maxWidth: CGFloat, marginX: CGFloat, anchorY: CGFloat,
        fillerText: String? = nil
    ) -> [Row] {
        let hasManualBreak = rawText.contains("\n")
        let text = style.textCase.apply(to: rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let font = resolvedFont(style)

        // Dựng danh sách CTLine cho MỘT chuỗi: tự ngắt dòng theo bề rộng + tôn trọng "\n".
        let makeCTLines: (String) -> [CTLine] = { string in
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            para.lineSpacing = CGFloat(style.lineSpacing)
            para.alignment = .left
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
            if style.characterSpacing != 0 { attrs[.kern] = CGFloat(style.characterSpacing) }
            let attr = NSAttributedString(string: string, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attr)
            let boxPath = CGPath(rect: CGRect(x: 0, y: 0, width: maxWidth, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), boxPath, nil)
            let linesCF = CTFrameGetLines(frame)
            var out: [CTLine] = []
            for i in 0..<min(CFArrayGetCount(linesCF), 8) {
                out.append(unsafeBitCast(CFArrayGetValueAtIndex(linesCF, i), to: CTLine.self))
            }
            return out
        }

        var ctLines = makeCTLines(text)
        guard !ctLines.isEmpty else { return [] }

        // Câu dài tràn khung & KHÔNG có ngắt dòng thủ công -> tự chia CÂN BẰNG 2 nửa.
        if !hasManualBreak, ctLines.count >= 2, let balanced = balancedTwoLineSplit(text) {
            let two = makeCTLines(balanced)
            if !two.isEmpty { ctLines = two }
        }

        // "Luôn 2 dòng": câu chính chỉ 1 dòng -> mượn DÒNG ĐẦU của câu kế tiếp làm dòng 2.
        var fillerCount = 0
        if let fillerText, ctLines.count == 1 {
            let fillerCooked = style.textCase.apply(to: fillerText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !fillerCooked.isEmpty, let f0 = makeCTLines(fillerCooked).first {
                ctLines.append(f0)
                fillerCount = 1
            }
        }

        // Hiển thị từ 2 dòng trở lên -> SO LE (dòng lẻ lệch trái, dòng chẵn lệch phải).
        let stagger = ctLines.count >= 2

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(ctLines[0], &ascent, &descent, &leading)
        let lineHeight = ascent + descent + leading + CGFloat(style.lineSpacing)
        let totalHeight = lineHeight * CGFloat(ctLines.count)
        let blockTop = anchorY * canvasSize.height - totalHeight / 2

        var rows: [Row] = []
        for (i, ctLine) in ctLines.enumerated() {
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(ctLine, &a, &d, &l))
            let path = glyphPath(for: ctLine)

            let align: KaraokeTextAlignment = stagger
                ? (i % 2 == 0 ? .leading : .trailing)
                : style.alignment
            let x: CGFloat
            switch align {
            case .leading: x = marginX
            case .center: x = marginX + (maxWidth - w) / 2
            case .trailing: x = marginX + (maxWidth - w)
            }

            let rowTop = blockTop + CGFloat(i) * lineHeight
            let baselineY = rowTop + ascent
            let rect = CGRect(x: x, y: rowTop, width: max(1, w), height: lineHeight)
            let filler = i >= ctLines.count - fillerCount
            rows.append(Row(path: path, x: x, baselineY: baselineY, width: w, rect: rect,
                            underline: style.fontUnderline, isFiller: filler))
        }
        return rows
    }

    private static func resolvedFont(_ style: KaraokeStyle) -> NSFont {
        var font = NSFont(name: style.fontName, size: CGFloat(style.fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(style.fontSize))
        let manager = NSFontManager.shared
        if style.fontBold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if style.fontItalic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// Gộp path của mọi glyph trong 1 dòng thành MỘT path (baseline-relative, y-up).
    private static func glyphPath(for line: CTLine) -> CGPath {
        let combined = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line)
        for runIndex in 0..<CFArrayGetCount(runs) {
            let run = unsafeBitCast(CFArrayGetValueAtIndex(runs, runIndex), to: CTRun.self)
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }

            let runFont: CTFont
            if let value = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] {
                runFont = value as! CTFont
            } else {
                continue
            }

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for i in 0..<count {
                guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                combined.addPath(gp, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
        return combined
    }

    // MARK: - Vẽ 1 block

    private static func drawBlock(cg: CGContext, rows: [Row], style: KaraokeStyle, alpha: CGFloat, wipe: Bool, progress: Double, canvasSize: CGSize) {
        guard !rows.isEmpty else { return }

        // Nền (đơn sắc hoặc gradient)
        if style.backgroundEnabled {
            var box = rows[0].rect
            for r in rows.dropFirst() { box = box.union(r.rect) }
            let pad = CGFloat(style.backgroundPadding)
            box = box.insetBy(dx: -pad, dy: -pad * 0.5)
            let radius = CGFloat(style.backgroundCornerRadius)
            cg.saveGState()
            cg.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            let bgFill = style.backgroundFill
            if bgFill.isSolid || bgFill.color == bgFill.color2 {
                cg.setFillColor(cgColor(bgFill.flatColor, alpha))
                cg.fillPath()
            } else {
                bgFill.fillCurrentPath(in: cg, bounds: box, alpha: alpha)
            }
            cg.restoreGState()
        }

        // Khung bao khối chữ + path glyph gộp (hệ màn hình y-down) — cho bóng/glow gradient.
        let blockBounds = rows.dropFirst().reduce(rows[0].rect) { $0.union($1.rect) }
        func combinedGlyphPath() -> CGPath {
            let m = CGMutablePath()
            for r in rows {
                var xf = CGAffineTransform(translationX: r.x, y: r.baselineY).scaledBy(x: 1, y: -1)
                if let gp = r.path.copy(using: &xf) { m.addPath(gp) }
            }
            return m
        }

        // Bóng
        if style.shadowEnabled {
            if style.shadowFill.isFlat {
                // Đường CŨ: fill + nét bo góc, cùng độ dày viền, lệch + nhoè.
                let col = cgColor(style.shadowFill.flatColor, alpha)
                let strokeW = (style.outlineEnabled && style.outlineWidth > 0 ? CGFloat(style.outlineWidth) : 1) * 2
                cg.saveGState()
                cg.translateBy(x: CGFloat(style.shadowOffsetX), y: CGFloat(style.shadowOffsetY))
                if style.shadowRadius > 0 {
                    cg.setShadow(offset: .zero, blur: CGFloat(style.shadowRadius), color: col)
                }
                for r in rows {
                    cg.saveGState()
                    cg.translateBy(x: r.x, y: r.baselineY)
                    cg.scaleBy(x: 1, y: -1)
                    cg.addPath(r.path)
                    cg.setFillColor(col); cg.setStrokeColor(col)
                    cg.setLineWidth(strokeW); cg.setLineJoin(.round); cg.setLineCap(.round)
                    cg.drawPath(using: .fillStroke)
                    cg.restoreGState()
                }
                cg.restoreGState()
            } else {
                style.shadowFill.drawSoftGlow(
                    shape: combinedGlyphPath(), in: cg, layerSize: canvasSize, bounds: blockBounds,
                    offset: CGSize(width: style.shadowOffsetX, height: style.shadowOffsetY),
                    blur: CGFloat(style.shadowRadius), yUp: false, alpha: alpha)
            }
        }

        // Glow
        if style.glowEnabled, style.glowRadius > 0 {
            if style.glowFill.isFlat {
                cg.saveGState()
                cg.setShadow(offset: .zero, blur: CGFloat(style.glowRadius),
                             color: cgColor(style.glowFill.flatColor, alpha))
                let fill = cgColor(style.glowFill.flatColor, alpha)
                for _ in 0..<2 { for r in rows { fillRow(cg, r, color: fill) } }
                cg.restoreGState()
            } else {
                style.glowFill.drawSoftGlow(
                    shape: combinedGlyphPath(), in: cg, layerSize: canvasSize, bounds: blockBounds,
                    offset: .zero, blur: CGFloat(style.glowRadius), yUp: false, alpha: alpha)
            }
        }

        // Viền: 1 nét cho cả dòng, bo góc tròn (đơn sắc hoặc gradient).
        if style.outlineEnabled, style.outlineWidth > 0 {
            let oFill = style.outlineFill
            let oSolid = oFill.isSolid || oFill.color == oFill.color2
            let stroke = cgColor(oFill.flatColor, alpha)
            let lw = CGFloat(style.outlineWidth) * 2
            for r in rows {
                var xf = CGAffineTransform(translationX: r.x, y: r.baselineY).scaledBy(x: 1, y: -1)
                guard let gp = r.path.copy(using: &xf) else { continue }
                cg.saveGState()
                cg.addPath(gp)
                cg.setLineWidth(lw); cg.setLineJoin(.round); cg.setLineCap(.round)
                if oSolid {
                    cg.setStrokeColor(stroke)
                    cg.strokePath()
                } else {
                    cg.replacePathWithStrokedPath()      // path = hình viền
                    oFill.fillCurrentPath(in: cg, bounds: r.rect, alpha: alpha)
                }
                cg.restoreGState()
            }
        }

        // Tô chữ chưa hát (đơn sắc hoặc gradient).
        let baseFill = style.textFill
        let base = cgColor(baseFill.flatColor, alpha)
        for r in rows {
            if baseFill.isSolid || baseFill.color == baseFill.color2 {
                fillRow(cg, r, color: base)
            } else {
                fillRowGradient(cg, r, fill: baseFill, alpha: alpha)
            }
            if r.underline {
                cg.saveGState()
                cg.setFillColor(base)
                cg.fill(CGRect(x: r.x, y: r.baselineY + 3, width: r.width, height: max(1, CGFloat(style.fontSize) * 0.045)))
                cg.restoreGState()
            }
        }

        // Quét chữ đang hát: chạy hết dòng 1 mới sang dòng 2… (bỏ qua dòng "mượn").
        guard wipe else { return }
        let total = rows.reduce(CGFloat(0)) { $0 + ($1.isFiller ? 0 : $1.width) }
        let sung = total * CGFloat(clamp(progress, 0, 1))
        let hlFill = style.highlightFill
        let hlSolid = cgColor(hlFill.flatColor, alpha)
        var cursor: CGFloat = 0
        for r in rows where !r.isFiller {
            let rowSung = max(0, min(r.width, sung - cursor))
            if rowSung > 0.5 {
                cg.saveGState()
                cg.clip(to: CGRect(x: r.x, y: r.rect.minY, width: rowSung, height: r.rect.height))
                if hlFill.isSolid || hlFill.color == hlFill.color2 {
                    cg.translateBy(x: r.x, y: r.baselineY)
                    cg.scaleBy(x: 1, y: -1)
                    cg.addPath(r.path)
                    cg.setFillColor(hlSolid)
                    cg.fillPath()
                } else {
                    var xf = CGAffineTransform(translationX: r.x, y: r.baselineY).scaledBy(x: 1, y: -1)
                    if let gp = r.path.copy(using: &xf) {
                        cg.addPath(gp); cg.clip()
                        hlFill.fill(rect: r.rect, in: cg, alpha: alpha)
                    }
                }
                cg.restoreGState()
            }
            cursor += r.width
        }
    }

    /// Tô 1 dòng bằng GRADIENT (kẹp theo hình glyph).
    private static func fillRowGradient(_ cg: CGContext, _ r: Row, fill: ColorFill, alpha: CGFloat) {
        var xf = CGAffineTransform(translationX: r.x, y: r.baselineY).scaledBy(x: 1, y: -1)
        guard let gp = r.path.copy(using: &xf) else { return }
        cg.saveGState()
        cg.addPath(gp); cg.clip()
        fill.fill(rect: r.rect, in: cg, alpha: alpha)
        cg.restoreGState()
    }

    private static func fillRow(_ cg: CGContext, _ r: Row, color: CGColor) {
        cg.saveGState()
        cg.translateBy(x: r.x, y: r.baselineY)
        cg.scaleBy(x: 1, y: -1)
        cg.addPath(r.path)
        cg.setFillColor(color)
        cg.fillPath()
        cg.restoreGState()
    }

    // MARK: - Tiện ích

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

    /// Chia câu thành 2 dòng sao cho số ký tự 2 nửa gần bằng nhau, cắt ở ranh giới từ.
    /// Trả `nil` nếu ít hơn 2 từ (không chia được).
    private static func balancedTwoLineSplit(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.count >= 2 else { return nil }
        let total = words.reduce(0) { $0 + $1.count } + (words.count - 1)
        var acc = 0
        var best = 1
        var bestDiff = Int.max
        for i in 0..<(words.count - 1) {
            acc += words[i].count + 1
            let diff = abs((total - acc) - acc)
            if diff < bestDiff { bestDiff = diff; best = i + 1 }
        }
        return words[0..<best].joined(separator: " ") + "\n" + words[best...].joined(separator: " ")
    }

    private static func cgColor(_ c: RGBAColor, _ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a * Double(alpha))
    }
}
