import Foundation

/// 1 mốc chuyển động của CẢ KHỐI chữ karaoke (giờ = giây trong BÀI): vị trí dọc/ngang + nhân cỡ.
struct TextBlockKeyframe: Equatable {
    var t: TimeInterval
    var verticalAnchor: Double
    var horizontalOffset: Double
    var fontScale: Double = 1          // nhân vào style.fontSize (1 = giữ nguyên)
    var easeRaw: String = KFEase.easeInOut.rawValue
    var ease: KFEase {
        get { KFEase(rawValue: easeRaw) ?? .easeInOut }
        set { easeRaw = newValue.rawValue }
    }
}

extension TextBlockKeyframe: Codable {
    enum CodingKeys: String, CodingKey { case t, verticalAnchor, horizontalOffset, fontScale, easeRaw }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t                = (try? c.decode(Double.self, forKey: .t)) ?? 0
        verticalAnchor   = (try? c.decode(Double.self, forKey: .verticalAnchor)) ?? 0.82
        horizontalOffset = (try? c.decode(Double.self, forKey: .horizontalOffset)) ?? 0
        fontScale        = (try? c.decode(Double.self, forKey: .fontScale)) ?? 1
        easeRaw          = (try? c.decode(String.self, forKey: .easeRaw)) ?? KFEase.easeInOut.rawValue
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t); try c.encode(verticalAnchor, forKey: .verticalAnchor)
        try c.encode(horizontalOffset, forKey: .horizontalOffset)
        try c.encode(fontScale, forKey: .fontScale)
        try c.encode(easeRaw, forKey: .easeRaw)
    }
}

/// Tham chiếu tới file audio người dùng đã import.
/// Lưu `bookmark` (security-scoped bookmark của macOS) để lần sau mở project
/// vẫn đọc lại được file dù người dùng đã di chuyển/đổi tên thư mục.
/// `lastKnownPath` là phương án dự phòng cho con người đọc.
struct AudioReference: Codable, Equatable {
    var lastKnownPath: String
    var bookmark: Data?
    var duration: TimeInterval?
    var sampleRate: Double?
    var fileName: String

    init(lastKnownPath: String, bookmark: Data? = nil, duration: TimeInterval? = nil, sampleRate: Double? = nil) {
        self.lastKnownPath = lastKnownPath
        self.bookmark = bookmark
        self.duration = duration
        self.sampleRate = sampleRate
        self.fileName = (lastKnownPath as NSString).lastPathComponent
    }
}

/// Chế độ export. Ưu tiên: SRT, rồi Transparent Karaoke Video.
enum ExportMode: String, Codable, CaseIterable {
    case srt                 // Mode A
    case transparentVideo    // Mode B (ProRes 4444, có alpha)
    case finalVideo          // Mode C (video nền + chữ) — làm sau
}

struct ExportSettings: Codable, Equatable {
    var lastMode: ExportMode = .srt
    var outputFolderPath: String?
    var srtIncludeBOM: Bool = false
}

/// Toàn bộ một dự án karaoke. Đây là thứ được ghi ra file `.kbproj` (JSON).
///
/// Mở lại app -> nạp lại nguyên trạng: audio, lyrics, timing, style,
/// resolution, export settings. Người dùng KHÔNG phải làm lại timing.
struct KaraokeProject: Equatable {
    /// Đánh số phiên bản định dạng file, phục vụ nâng cấp/di trú sau này.
    var schemaVersion: Int = 1

    var name: String = "Untitled"
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    var audio: AudioReference?

    /// Vocal / beat ĐÃ TÁCH sẵn (từ `BeatSeparation`) — lưu VÀO PROJECT (gói, xem
    /// `materializeMedia`) để mở project ở MÁY KHÁC không phải tách lại từ đầu.
    /// `nil` = chưa tách xong, hoặc project cũ lưu trước khi có 2 khoá này.
    var vocalStem: AudioReference?
    var beatStem: AudioReference?

    var resolution: VideoResolution = .hd1080p
    var style: KaraokeStyle = .mine0

    /// Style RIÊNG cho câu nhắc tiếp theo — độc lập hoàn toàn với `style`.
    var nextLineStyle: KaraokeStyle = KaraokeProject.defaultNextLineStyle()

    /// Nền hình (ảnh/video) cho Preview + xuất video nền đục (Mode C). `nil` = không có.
    var backgroundMedia: BackgroundMedia?

    /// Các lớp ảnh/logo đè lên trên chữ (track phía trên kiểu CapCut). Rỗng = không có.
    var overlays: [OverlayClip] = []

    /// Nhóm lớp đè (gom clip có tên). Rỗng = không nhóm.
    var overlayGroups: [OverlayGroup] = []

    /// (U6) Ảnh đã NHẬP vào kho, kéo được xuống timeline. CHƯA đặt = chưa nằm trong `overlays`.
    var mediaPool: [MediaPoolItem] = []

    /// "Sóng nhạc" vẽ theo audio gốc. `nil` = không bật.
    var visualizer: MusicVisualizer?

    /// Chuyển động CẢ KHỐI chữ karaoke (vị trí dọc / ngang / cỡ) theo GIỜ BÀI. Rỗng = tĩnh.
    var textKeyframes: [TextBlockKeyframe] = []

    /// (dùng bởi renderer + preview) biến hình khối chữ tại `songT`. Rỗng keyframe → giá trị tĩnh.
    func textBlockTransform(atSong songT: TimeInterval, baseAnchor: Double, baseHOffset: Double)
        -> (anchor: Double, hOffset: Double, fontScale: Double) {
        guard let a0 = textKeyframes.first, let b0 = textKeyframes.last else {
            return (baseAnchor, baseHOffset, 1)
        }
        func pick(_ f: (TextBlockKeyframe) -> Double) -> Double {
            if songT <= a0.t { return f(a0) }
            if songT >= b0.t { return f(b0) }
            for i in 0..<(textKeyframes.count - 1) {
                let a = textKeyframes[i], b = textKeyframes[i + 1]
                guard songT >= a.t, songT <= b.t else { continue }
                let u = (songT - a.t) / max(0.0001, b.t - a.t)
                let e = b.ease.apply(u)
                return f(a) + (f(b) - f(a)) * e
            }
            return f(a0)
        }
        return (pick { $0.verticalAnchor }, pick { $0.horizontalOffset }, pick { $0.fontScale })
    }

    mutating func upsertTextKeyframe(atSong songT: TimeInterval, anchor: Double, hOffset: Double,
                                    fontScale: Double = 1) {
        let t = max(0, songT)
        let kf = TextBlockKeyframe(t: t, verticalAnchor: anchor, horizontalOffset: hOffset, fontScale: fontScale)
        if let i = textKeyframes.firstIndex(where: { abs($0.t - t) < 0.05 }) { textKeyframes[i] = kf }
        else { textKeyframes.append(kf); textKeyframes.sort { $0.t < $1.t } }
    }

    mutating func removeTextKeyframe(nearSong songT: TimeInterval, tol: TimeInterval = 0.15) {
        textKeyframes.removeAll { abs($0.t - songT) < tol }
    }

    static func defaultNextLineStyle() -> KaraokeStyle {
        .mine0Next
    }

    /// Lời bài hát ở dạng văn bản thô (người dùng dán vào). Giữ lại để mở
    /// project vẫn còn, và để tách dòng lại khi cần.
    var rawLyrics: String = ""

    /// Khoảng "bù trước" (giây) khi bấm T: điểm bắt đầu dòng = thời điểm bấm − giá trị này.
    /// Giúp chữ hiện sớm hơn lúc hát, kiểu karaoke.
    var tapLeadIn: TimeInterval = 0.5

    // M-D · Cắt bài hát + âm lượng (không đổi timeline-time; chỉ giới hạn vùng phát/xuất).
    var audioTrimStart: TimeInterval = 0   // giây; 0 = từ đầu
    var audioTrimEnd: TimeInterval = 0     // giây; 0 = đến hết bài
    var audioGain: Double = 1              // 0…1
    var audioMuted: Bool = false           // tắt tiếng nhanh (giữ nguyên audioGain)
    var audioFadeIn: TimeInterval = 0      // fade âm thanh ở ĐẦU đoạn cắt (chỉ lúc xuất)
    var audioFadeOut: TimeInterval = 0     // fade âm thanh ở CUỐI đoạn cắt

    /// M-F · Ẩn hẳn lớp chữ karaoke (preview + xuất) — để làm nền / kiểm tra bố cục.
    var lyricsHidden: Bool = false

    /// Bước 1 — "Clip Karaoke": giây trên dòng thời gian DỰNG mà cả cụm karaoke (nhạc + chữ + nền)
    /// bắt đầu. 0 = khớp đầu như cũ. Kéo clip ★ KARAOKE trên timeline để đổi. KHÔNG đụng timing chữ:
    /// mọi thứ tính tại `thời-gian-hiện-tại − karaokeClipStart`. 1 bộ phát duy nhất.
    var karaokeClipStart: TimeInterval = 0

    /// Dải quét highlight chạy xong ở bao nhiêu phần của câu (0.3…1.0).
    /// (Đã ẩn khỏi UI 2026-08-31 — renderer luôn dùng 100%. Giữ khoá để mở file cũ.)
    var wipeCompletion: Double = 1.0

    /// Bù chung (giây) tinh chỉnh đồng bộ: renderer đánh giá tại `time - followOffset`.
    /// Âm = chạy sớm hơn. Mặc định 0 (ẩn khỏi UI) — chỉ dùng khi cần kéo cả bài.
    var followOffset: TimeInterval = 0

    /// (Không dùng nữa — câu kế giờ hiện NGAY khi câu trước xong. Giữ khoá cho file cũ.)
    var displayLead: TimeInterval = 2.0

    /// Vệt quét bắt đầu TRỄ hơn mốc câu bao nhiêu giây ("vô nhịp mới chạy"). Ẩn khỏi UI.
    var wipeLead: TimeInterval = 0.5

    /// Danh sách dòng lời đã tách, kèm timing.
    var lines: [LyricLine] = []

    /// Màu "nhớ" cho mỗi vai người hát (Nam / Nữ / Song ca) — key = SingerRole.rawValue.
    /// Gán icon cho 1 câu → tự lấy màu này; chỉnh màu câu đó → cập nhật lại đây.
    var singerColors: [String: RGBAColor] = SingerRole.defaultColors

    var exportSettings: ExportSettings = ExportSettings()

    /// Có bất kỳ dòng nào đã gán timing đầy đủ chưa.
    var hasAnyTiming: Bool { lines.contains { $0.isTimed } }

    /// Đã có dòng nào dùng timing theo từng từ chưa.
    var usesWordLevelTiming: Bool { lines.contains { $0.hasWordTiming } }

    // MARK: - (2026-09-13) Project dạng GÓI — tự mang theo media, mở máy khác không thiếu.

    /// Copy TOÀN BỘ media (nhạc, vocal/beat đã tách, nền, kho + lớp đè ảnh/video/nhạc) vào
    /// `<packageURL>/Media/`, đổi từng tham chiếu sang đường dẫn NẰM TRONG project. Gọi lúc LƯU
    /// (`ProjectStore.write`). File nào không tìm thấy gốc (đã bị xoá/di chuyển) thì BỎ QUA ÊM —
    /// không chặn lưu — nhưng TRẢ VỀ tên các món bị bỏ qua, để `ProjectStore` báo cho người dùng
    /// biết (trước đây bỏ qua HOÀN TOÀN im lặng — mở project ở máy khác mới phát hiện ra mất, xem
    /// `KNOWN_ISSUES.md` "package format · mất media êm").
    @discardableResult
    mutating func materializeMedia(intoPackage packageURL: URL) -> [String] {
        let mediaDir = ProjectPackage.mediaDir(for: packageURL)
        var missing: [String] = []
        func put(_ url: URL, base: String) -> String? {
            let name = ProjectPackage.name(base, ext: url.pathExtension)
            return ProjectPackage.materialize(source: url, into: mediaDir, preferredName: name)?.path
        }
        if let a = audio {
            if let url = AudioLoader.resolveURL(from: a), let p = put(url, base: "audio") {
                audio?.lastKnownPath = p; audio?.bookmark = nil
            } else {
                missing.append(L("File nhạc") + " (\(a.fileName))")
            }
        }
        if let v = vocalStem {
            if let url = AudioLoader.resolveURL(from: v), let p = put(url, base: "vocal") {
                vocalStem?.lastKnownPath = p; vocalStem?.bookmark = nil
            } else {
                missing.append(L("Giọng đã tách"))
            }
        }
        if let b = beatStem {
            if let url = AudioLoader.resolveURL(from: b), let p = put(url, base: "beat") {
                beatStem?.lastKnownPath = p; beatStem?.bookmark = nil
            } else {
                missing.append(L("Nhạc nền đã tách"))
            }
        }
        if let m = backgroundMedia {
            if let url = m.resolveURL(), let p = put(url, base: "background") {
                backgroundMedia?.lastKnownPath = p; backgroundMedia?.bookmark = nil
            } else {
                missing.append(L("Ảnh/video nền") + (m.fileName.isEmpty ? "" : " (\(m.fileName))"))
            }
        }
        for i in mediaPool.indices {
            if let url = mediaPool[i].resolveURL(),
               let p = put(url, base: "pool-\(mediaPool[i].id.uuidString)") {
                mediaPool[i].lastKnownPath = p; mediaPool[i].bookmark = nil
            } else {
                missing.append(L("Media trong kho") + " (\(mediaPool[i].name))")
            }
        }
        for i in overlays.indices {
            guard overlays[i].kind != .text else { continue }
            if let url = overlays[i].resolveURL(),
               let p = put(url, base: "overlay-\(overlays[i].id.uuidString)") {
                overlays[i].lastKnownPath = p; overlays[i].bookmark = nil
            } else {
                missing.append(L("Lớp đè") + " (\(overlays[i].name))")
            }
        }
        return missing
    }

    /// Sau khi MỞ 1 project dạng gói: nếu đường dẫn đã lưu lần trước không còn đúng (cả thư mục
    /// `.kbproj` bị DI CHUYỂN / ĐỔI TÊN sau khi lưu) — tự tìm lại đúng file trong `Media/` của
    /// CHÍNH gói đang mở (khớp theo TÊN file, vì lúc lưu đã đặt tên cố định) — tự "lành", không
    /// hỏi lại người dùng đường dẫn.
    mutating func rehomeMediaIfNeeded(inPackage packageURL: URL) {
        let mediaDir = ProjectPackage.mediaDir(for: packageURL)
        func fix(_ path: inout String, _ bookmark: inout Data?) {
            guard !path.isEmpty, !FileManager.default.fileExists(atPath: path) else { return }
            let candidate = mediaDir.appendingPathComponent((path as NSString).lastPathComponent)
            guard FileManager.default.fileExists(atPath: candidate.path) else { return }
            path = candidate.path; bookmark = nil
        }
        if var a = audio { fix(&a.lastKnownPath, &a.bookmark); audio = a }
        if var v = vocalStem { fix(&v.lastKnownPath, &v.bookmark); vocalStem = v }
        if var b = beatStem { fix(&b.lastKnownPath, &b.bookmark); beatStem = b }
        if var m = backgroundMedia { fix(&m.lastKnownPath, &m.bookmark); backgroundMedia = m }
        for i in mediaPool.indices {
            var item = mediaPool[i]; fix(&item.lastKnownPath, &item.bookmark); mediaPool[i] = item
        }
        for i in overlays.indices {
            var clip = overlays[i]; fix(&clip.lastKnownPath, &clip.bookmark); overlays[i] = clip
        }
    }

    /// Sau khi MỞ (cả project dạng gói lẫn file JSON đơn cũ): những món media KHÔNG CÒN tìm thấy
    /// trên đĩa (đã rehome nhưng vẫn thiếu, hoặc file JSON đơn cũ trỏ ra ngoài máy khác không có
    /// file gốc đó) — trả tên để `ProjectStore` báo cho người dùng, thay vì im lặng để nền/nhạc
    /// trống mà không rõ vì sao (xem `KNOWN_ISSUES.md`).
    func missingMediaLabels() -> [String] {
        var missing: [String] = []
        if let a = audio, AudioLoader.resolveURL(from: a) == nil {
            missing.append(L("File nhạc") + " (\(a.fileName))")
        }
        if let m = backgroundMedia, m.resolveURL() == nil {
            missing.append(L("Ảnh/video nền") + (m.fileName.isEmpty ? "" : " (\(m.fileName))"))
        }
        for item in mediaPool where item.resolveURL() == nil {
            missing.append(L("Media trong kho") + " (\(item.name))")
        }
        for clip in overlays where clip.kind != .text && clip.resolveURL() == nil {
            missing.append(L("Lớp đè") + " (\(clip.name))")
        }
        return missing
    }
}

// MARK: - Codable "khoan dung"
//
// Đọc file bằng `decodeIfPresent` cho từng khoá: nếu một project cũ thiếu
// khoá mới (do format lớn dần qua các Phase) thì dùng giá trị mặc định,
// KHÔNG làm hỏng việc mở file.
extension KaraokeProject: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, name, createdAt, modifiedAt
        case audio, vocalStem, beatStem, resolution, style, nextLineStyle, backgroundMedia, overlays, visualizer, rawLyrics, tapLeadIn, wipeCompletion, followOffset, displayLead, wipeLead, lines, exportSettings, singerColors, mediaPool, textKeyframes, overlayGroups
        case audioTrimStart, audioTrimEnd, audioGain, audioMuted, lyricsHidden
        case audioFadeIn, audioFadeOut, karaokeClipStart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        schemaVersion  = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? schemaVersion
        name           = try container.decodeIfPresent(String.self, forKey: .name) ?? name
        createdAt      = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? createdAt
        modifiedAt     = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? modifiedAt
        audio          = try container.decodeIfPresent(AudioReference.self, forKey: .audio)
        vocalStem      = try container.decodeIfPresent(AudioReference.self, forKey: .vocalStem)
        beatStem       = try container.decodeIfPresent(AudioReference.self, forKey: .beatStem)
        resolution     = try container.decodeIfPresent(VideoResolution.self, forKey: .resolution) ?? resolution
        style          = try container.decodeIfPresent(KaraokeStyle.self, forKey: .style) ?? style
        nextLineStyle  = try container.decodeIfPresent(KaraokeStyle.self, forKey: .nextLineStyle) ?? nextLineStyle
        backgroundMedia = try container.decodeIfPresent(BackgroundMedia.self, forKey: .backgroundMedia)
        overlays       = try container.decodeIfPresent([OverlayClip].self, forKey: .overlays) ?? overlays
        visualizer     = try container.decodeIfPresent(MusicVisualizer.self, forKey: .visualizer)
        rawLyrics      = try container.decodeIfPresent(String.self, forKey: .rawLyrics) ?? rawLyrics
        tapLeadIn      = try container.decodeIfPresent(TimeInterval.self, forKey: .tapLeadIn) ?? tapLeadIn
        audioTrimStart = try container.decodeIfPresent(TimeInterval.self, forKey: .audioTrimStart) ?? audioTrimStart
        audioTrimEnd   = try container.decodeIfPresent(TimeInterval.self, forKey: .audioTrimEnd) ?? audioTrimEnd
        audioGain      = try container.decodeIfPresent(Double.self, forKey: .audioGain) ?? audioGain
        audioMuted     = try container.decodeIfPresent(Bool.self, forKey: .audioMuted) ?? audioMuted
        audioFadeIn    = try container.decodeIfPresent(TimeInterval.self, forKey: .audioFadeIn) ?? audioFadeIn
        audioFadeOut   = try container.decodeIfPresent(TimeInterval.self, forKey: .audioFadeOut) ?? audioFadeOut
        lyricsHidden   = try container.decodeIfPresent(Bool.self, forKey: .lyricsHidden) ?? lyricsHidden
        karaokeClipStart = try container.decodeIfPresent(TimeInterval.self, forKey: .karaokeClipStart) ?? karaokeClipStart
        wipeCompletion = try container.decodeIfPresent(Double.self, forKey: .wipeCompletion) ?? wipeCompletion
        followOffset   = try container.decodeIfPresent(TimeInterval.self, forKey: .followOffset) ?? followOffset
        displayLead    = try container.decodeIfPresent(TimeInterval.self, forKey: .displayLead) ?? displayLead
        wipeLead       = try container.decodeIfPresent(TimeInterval.self, forKey: .wipeLead) ?? wipeLead
        lines          = try container.decodeIfPresent([LyricLine].self, forKey: .lines) ?? lines
        exportSettings = try container.decodeIfPresent(ExportSettings.self, forKey: .exportSettings) ?? exportSettings
        singerColors   = try container.decodeIfPresent([String: RGBAColor].self, forKey: .singerColors) ?? singerColors
        mediaPool      = try container.decodeIfPresent([MediaPoolItem].self, forKey: .mediaPool) ?? mediaPool
        textKeyframes  = try container.decodeIfPresent([TextBlockKeyframe].self, forKey: .textKeyframes) ?? textKeyframes
        overlayGroups  = try container.decodeIfPresent([OverlayGroup].self, forKey: .overlayGroups) ?? overlayGroups
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(audio, forKey: .audio)
        try container.encodeIfPresent(vocalStem, forKey: .vocalStem)
        try container.encodeIfPresent(beatStem, forKey: .beatStem)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(style, forKey: .style)
        try container.encode(nextLineStyle, forKey: .nextLineStyle)
        try container.encodeIfPresent(backgroundMedia, forKey: .backgroundMedia)
        try container.encode(overlays, forKey: .overlays)
        try container.encodeIfPresent(visualizer, forKey: .visualizer)
        try container.encode(rawLyrics, forKey: .rawLyrics)
        try container.encode(tapLeadIn, forKey: .tapLeadIn)
        try container.encode(audioTrimStart, forKey: .audioTrimStart)
        try container.encode(audioTrimEnd, forKey: .audioTrimEnd)
        try container.encode(audioGain, forKey: .audioGain)
        try container.encode(audioMuted, forKey: .audioMuted)
        try container.encode(audioFadeIn, forKey: .audioFadeIn)
        try container.encode(audioFadeOut, forKey: .audioFadeOut)
        try container.encode(lyricsHidden, forKey: .lyricsHidden)
        try container.encode(karaokeClipStart, forKey: .karaokeClipStart)
        try container.encode(wipeCompletion, forKey: .wipeCompletion)
        try container.encode(followOffset, forKey: .followOffset)
        try container.encode(displayLead, forKey: .displayLead)
        try container.encode(wipeLead, forKey: .wipeLead)
        try container.encode(lines, forKey: .lines)
        try container.encode(exportSettings, forKey: .exportSettings)
        try container.encode(singerColors, forKey: .singerColors)
        try container.encode(mediaPool, forKey: .mediaPool)
        try container.encode(textKeyframes, forKey: .textKeyframes)
        try container.encode(overlayGroups, forKey: .overlayGroups)
    }
}
