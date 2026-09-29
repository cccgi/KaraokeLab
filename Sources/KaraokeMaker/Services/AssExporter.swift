import Foundation

/// Xuất phụ đề .ass (Advanced SubStation Alpha) với hiệu ứng karaoke `\kf`
/// (quét sáng từng chữ). Mở bằng Aegisub, VLC, hoặc nạp làm phụ đề trong phần mềm dựng.
enum AssExporter {

    static func make(from project: KaraokeProject) -> String {
        let w = max(2, project.resolution.width)
        let h = max(2, project.resolution.height)
        let scale = Double(min(w, h)) / 1080.0        // khớp cách renderer phóng chữ
        let style = project.style

        var out = ""

        // ----- [Script Info] -----
        out += "[Script Info]\r\n"
        out += "Title: \(project.name)\r\n"
        out += "ScriptType: v4.00+\r\n"
        out += "WrapStyle: 0\r\n"
        out += "ScaledBorderAndShadow: yes\r\n"
        out += "PlayResX: \(w)\r\n"
        out += "PlayResY: \(h)\r\n\r\n"

        // ----- [V4+ Styles] -----
        let fontSize = Int((style.fontSize * scale).rounded())
        let spacing = Int((style.characterSpacing * scale).rounded())
        let outline = style.outlineEnabled ? max(0, style.outlineWidth * scale) : 0
        let shadow = style.shadowEnabled ? max(abs(style.shadowOffsetX), abs(style.shadowOffsetY)) * scale : 0
        let borderStyle = style.backgroundEnabled ? 3 : 1
        let backColour = style.backgroundEnabled ? assColor(style.backgroundColor) : assColor(style.shadowColor)

        // Căn lề kiểu numpad ASS (1-3 đáy, 4-6 giữa, 7-9 đỉnh).
        let vert = style.verticalAnchor
        let row = vert > 0.62 ? 0 : (vert > 0.34 ? 3 : 6)
        let col: Int
        switch style.alignment {
        case .leading:  col = 1
        case .center:   col = 2
        case .trailing: col = 3
        }
        let alignment = row + col
        let marginV: Int
        switch row {
        case 0:  marginV = Int((1 - vert) * Double(h))
        case 6:  marginV = Int(vert * Double(h))
        default: marginV = 0
        }
        let marginLR = Int(style.horizontalMarginRatio * Double(w))

        out += "[V4+ Styles]\r\n"
        out += "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
        out += "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
        out += "Alignment, MarginL, MarginR, MarginV, Encoding\r\n"
        out += "Style: Default,"
        out += "\(sanitizeFont(style.fontName)),\(max(1, fontSize)),"
        out += "\(assColor(style.highlightColor)),\(assColor(style.textColor)),"
        out += "\(assColor(style.outlineColor)),\(backColour),"
        out += "\(style.fontBold ? -1 : 0),\(style.fontItalic ? -1 : 0),\(style.fontUnderline ? -1 : 0),0,"
        out += "100,100,\(spacing),0,\(borderStyle),"
        out += "\(fmt(outline)),\(fmt(shadow)),"
        out += "\(alignment),\(marginLR),\(marginLR),\(max(0, marginV)),1\r\n\r\n"

        // ----- [Events] -----
        out += "[Events]\r\n"
        out += "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n"

        for line in project.lines {
            guard let s = line.start, let e = line.end, e > s else { continue }
            let text = karaokeText(for: line, lineStart: s, lineEnd: e)
            guard !text.isEmpty else { continue }
            out += "Dialogue: 0,\(assTime(s)),\(assTime(e)),Default,,0,0,0,,\(text)\r\n"
        }

        return out
    }

    // MARK: - Dựng text có tag \kf

    private static func karaokeText(for line: LyricLine, lineStart: Double, lineEnd: Double) -> String {
        // Lấy danh sách (chữ, start, end): ưu tiên timing từng chữ đã có, nếu không thì chia đều.
        //
        // (2026-09-23) SỬA LỖI MẤT CHỮ: `line.hasWordTiming` chỉ kiểm tra `words` KHÔNG RỖNG,
        // không kiểm tra TỪNG từ có đủ cả `start` LẪN `end`. Trước đây nhánh này dùng
        // `words.compactMap { guard ws, we else return nil }` — bất kỳ từ nào thiếu 1 trong 2 mốc
        // (canh lời chưa xong hết từng chữ, hoặc user sửa tay còn dở) bị ÂM THẦM BỎ QUA, mất hẳn
        // khỏi phụ đề xuất ra dù dòng đó vẫn có `line.start`/`line.end` hợp lệ — đúng hiện tượng
        // user báo "mỗi dòng thiếu vài từ". Giờ chỉ dùng nhánh timing-từng-chữ khi TẤT CẢ từ trong
        // dòng đều có đủ mốc; nếu THIẾU dù chỉ 1 từ, cả dòng rơi về nhánh chia đều bên dưới (dùng
        // `line.text` — luôn đủ chữ, chỉ mất độ chính xác quét sáng cho riêng dòng đó).
        // (2026-09-23) THÊM: `words[]` có thể CŨ so với `text` hiện tại — sửa lời tay (ô sửa lời ở
        // danh sách dòng, `setLineText`) chỉ đổi `line.text`, KHÔNG đụng `line.words` (mảng canh
        // từng chữ, do thuật toán canh lời dựng — không được sửa file đó). Nếu user gõ THÊM chữ
        // sau khi đã canh xong, `words[]` vẫn còn là bản CŨ (ít từ hơn) → dùng `words[]` sẽ THIẾU
        // đúng phần vừa gõ thêm, dù mỗi từ trong đó vẫn "đủ mốc". So số từ tách được từ `text`
        // HIỆN TẠI với số phần tử `words[]` — lệch (dòng đã bị sửa tay thêm/bớt chữ) thì coi như
        // KHÔNG đáng tin, rơi về nhánh chia đều bên dưới (luôn đúng `text` hiện tại, không bao giờ
        // thiếu chữ, chỉ mất độ chính xác quét sáng riêng dòng đó).
        let textTokenCount = WordTiming.tokens(line.text).count
        let allWordsTimed = !line.words.isEmpty
            && line.words.count == textTokenCount
            && line.words.allSatisfy { $0.start != nil && $0.end != nil }
        let units: [(text: String, start: Double, end: Double)]
        if allWordsTimed {
            units = line.words.map { w in (w.text, w.start!, max(w.start!, w.end!)) }
        } else {
            let toks = WordTiming.tokens(line.text)
            guard !toks.isEmpty else { return "" }
            let weights = toks.map { Double(max(1, $0.count)) }
            let total = weights.reduce(0, +)
            var cur = lineStart
            var acc: [(String, Double, Double)] = []
            for (i, t) in toks.enumerated() {
                let d = (lineEnd - lineStart) * weights[i] / total
                acc.append((t, cur, cur + d))
                cur += d
            }
            units = acc
        }
        guard !units.isEmpty else { return "" }

        // (2026-09-24) SỬA LỖI "MỞ BẰNG CapCut MẤT CHỮ CUỐI MỖI DÒNG": trước đây mỗi tag `\kf`
        // làm tròn xen ti-giây RIÊNG LẺ (`cs(...)` cho từng khoảng), rồi cộng dồn bằng
        // `cursor += dur/100.0` — sai số làm tròn của TỪNG chữ dồn lại qua cả dòng có thể khiến
        // TỔNG các `\kf` VƯỢT quá mốc kết thúc Dialogue đã khai (`assTime(e)`, làm tròn RIÊNG,
        // theo đường tính khác hẳn). App này (và VLC/Aegisub) vẫn hiển thị dư ra sau khi hết giờ
        // dòng nên không thấy gì lạ — CapCut tính chặt hơn, cắt bỏ phần rơi SAU mốc kết thúc, hay
        // rơi đúng vào đúng chữ cuối (khoảng bị đẩy lố nhiều nhất, do lỗi làm tròn dồn tới đó).
        // Sửa: đổi sang làm tròn theo MỐC TUYỆT ĐỐI (giống hệt cách `assTime()` làm tròn `s`/`e`)
        // rồi LẤY HIỆU 2 mốc liền nhau ra thời lượng — đảm bảo tổng luôn khớp CHÍNH XÁC khoảng
        // `assTime(s)…assTime(e)` đã khai, không bao giờ vượt.
        let startCS = Int((lineStart * 100).rounded())
        let endCS = Int((lineEnd * 100).rounded())
        let totalCS = max(1, endCS - startCS)

        // Mốc (tuyệt đối) kết thúc từng đoạn theo thứ tự: [lặng đầu?] rồi mỗi chữ [lặng trước?] + chữ.
        var segments: [(text: String?, endAbs: Double)] = []
        var prevEnd = lineStart
        for u in units {
            let uStart = max(u.start, prevEnd)
            if uStart - prevEnd > 0.01 { segments.append((nil, uStart)) }
            let uEnd = max(u.end, uStart)
            segments.append((u.text, uEnd))
            prevEnd = uEnd
        }
        // Chốt mốc CUỐI CÙNG = đúng `lineEnd` — chỗ hấp thụ hết sai số làm tròn cộng dồn, khỏi
        // để dòng nào đó lố ra ngoài mốc Dialogue đã khai.
        if !segments.isEmpty { segments[segments.count - 1].endAbs = lineEnd }

        let lastWordIdx = segments.lastIndex { $0.text != nil }
        var result = ""
        var prevCS = 0
        for (si, seg) in segments.enumerated() {
            var boundCS = min(totalCS, Int((seg.endAbs * 100).rounded()) - startCS)
            if seg.text != nil { boundCS = max(prevCS + 1, boundCS) }   // chữ luôn có ít nhất 1cs
            let dur = boundCS - prevCS
            prevCS = boundCS
            if let text = seg.text {
                result += "{\\kf\(max(1, dur))}\(escape(text))"
                if si != lastWordIdx { result += " " }
            } else if dur > 3 {
                result += "{\\kf\(dur)}"
            }
        }
        return result.replacingOccurrences(of: "\n", with: "\\N")
    }

    // MARK: - Tiện ích

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    private static func assTime(_ t: Double) -> String {
        let total = max(0, Int((t * 100).rounded()))
        let h = total / 360_000
        let m = (total % 360_000) / 6_000
        let s = (total % 6_000) / 100
        let c = total % 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, c)
    }

    /// ASS dùng &HAABBGGRR, AA: 00 = đục, FF = trong suốt.
    private static func assColor(_ c: RGBAColor) -> String {
        func hx(_ v: Double) -> String {
            String(format: "%02X", max(0, min(255, Int((v * 255).rounded()))))
        }
        return "&H\(hx(1 - c.a))\(hx(c.b))\(hx(c.g))\(hx(c.r))"
    }

    private static func sanitizeFont(_ name: String) -> String {
        name.replacingOccurrences(of: ",", with: " ")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
    }
}
