import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    // MARK: - Nhóm lớp đè

    func pruneOverlayGroups() {
        let live = Set(store.project.overlays.map(\.id))
        for i in store.project.overlayGroups.indices {
            store.project.overlayGroups[i].memberIDs.removeAll { !live.contains($0) }
        }
        store.project.overlayGroups.removeAll { $0.memberIDs.count < 2 }
    }

    func overlayGroup(forClip id: UUID) -> OverlayGroup? {
        store.project.overlayGroups.first { $0.memberIDs.contains(id) }
    }

    func makeGroupFromSelection() {
        let ids = Array(selectedOverlayIDs)
        guard ids.count >= 2 else { return }
        store.perform(L("Gom nhóm lớp")) {
            // gỡ các id này khỏi nhóm cũ (nếu có) rồi tạo nhóm mới
            for i in store.project.overlayGroups.indices {
                store.project.overlayGroups[i].memberIDs.removeAll { ids.contains($0) }
            }
            store.project.overlayGroups.removeAll { $0.memberIDs.count < 2 }
            let n = store.project.overlayGroups.count + 1
            store.project.overlayGroups.append(OverlayGroup(name: "\(L("Nhóm")) \(n)", memberIDs: ids))
        }
    }

    func ungroup(_ gid: UUID) {
        store.perform(L("Bỏ nhóm")) { store.project.overlayGroups.removeAll { $0.id == gid } }
    }

    func renameGroup(_ gid: UUID) {
        guard let cur = store.project.overlayGroups.first(where: { $0.id == gid })?.name,
              let new = TextPrompt.run(title: L("Đổi tên nhóm"), defaultValue: cur, okTitle: L("Đổi")) else { return }
        store.perform(L("Đổi tên nhóm")) {
            if let i = store.project.overlayGroups.firstIndex(where: { $0.id == gid }) {
                store.project.overlayGroups[i].name = new
            }
        }
    }

    func setGroupFlag(_ gid: UUID, hidden: Bool? = nil, locked: Bool? = nil) {
        guard let g = store.project.overlayGroups.first(where: { $0.id == gid }) else { return }
        store.perform(hidden != nil ? L("Ẩn/hiện nhóm") : L("Khoá/mở nhóm")) {
            for i in store.project.overlays.indices where g.memberIDs.contains(store.project.overlays[i].id) {
                if let h = hidden { store.project.overlays[i].isHidden = h }
                if let l = locked { store.project.overlays[i].isLocked = l }
            }
        }
    }

    func selectGroup(_ gid: UUID) {
        guard let g = store.project.overlayGroups.first(where: { $0.id == gid }), !g.memberIDs.isEmpty else { return }
        selectedOverlayIDs = Set(g.memberIDs)
        selectedOverlayID = g.memberIDs.first
    }

    // MARK: - Lớp đè trên timeline: dời · cắt · tách · nhân đôi

    /// Bước 1 — kéo clip ★ KARAOKE: chốt mốc bắt đầu mới (1 undo / lần kéo).
    func timelineKaraokeClipMove(_ newStart: Double) {
        let v = max(0, newStart)
        guard abs(v - store.project.karaokeClipStart) > 0.0005 else { return }
        store.perform(L("Dời clip Karaoke")) { store.project.karaokeClipStart = v }
    }

    func timelineOverlayMove(_ id: UUID, _ newStart: Double, _ newLane: Int) {
        store.perform(L("Dời lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            store.project.overlays[i].start = max(0, newStart)
            store.project.overlays[i].lane = max(0, min(3, newLane))
        }
    }

    func timelineOverlayTrim(_ id: UUID, _ newStart: Double, _ newDuration: Double) {
        store.perform(L("Cắt lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            var c = store.project.overlays[i]
            var s = max(0, newStart)
            var dur = max(0.1, newDuration)

            if c.kind == .video {
                let src = c.sourceDuration > 0.05 ? c.sourceDuration : .greatestFiniteMagnitude
                let deltaLeft = s - c.start            // >0 = cắt bớt đầu, <0 = kéo ngược ra
                if abs(deltaLeft) > 0.0005 {           // KÉO MÉP TRÁI → dời điểm vào nguồn
                    var newTrim = c.trimStart + deltaLeft
                    if newTrim < 0 { s -= newTrim; dur += newTrim; newTrim = 0 }   // hết đầu nguồn
                    c.trimStart = newTrim
                }
                // KÉO MÉP PHẢI (hoặc sau khi nắn trái) — không vượt quá phần còn lại của nguồn.
                dur = min(dur, max(0.1, src - c.trimStart))
            }
            c.start = max(0, s)
            c.duration = dur
            store.project.overlays[i] = c
        }
    }

    func timelineOverlaySplit(_ id: UUID, _ atTime: Double) {
        store.perform(L("Tách lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            let c = store.project.overlays[i]
            guard atTime > c.start + 0.1, atTime < c.end - 0.1 else { return }
            var left = c
            left.duration = atTime - c.start
            var right = c
            right.id = UUID()
            right.start = atTime
            right.duration = c.end - atTime
            if c.kind == .video {
                right.trimStart = c.trimStart + (atTime - c.start)   // nửa phải vào nguồn muộn hơn
            }
            store.project.overlays[i] = left
            store.project.overlays.insert(right, at: i + 1)
        }
    }

    func timelineToggleLaneHidden(_ lane: Int) {
        let clips = store.project.overlays.filter { $0.lane == lane }
        guard !clips.isEmpty else { return }
        let makeHidden = !clips.allSatisfy { $0.isHidden }   // còn 1 cái hiện → ẩn hết
        store.perform(makeHidden ? L("Ẩn cả làn") : L("Hiện cả làn")) {
            for i in store.project.overlays.indices where store.project.overlays[i].lane == lane {
                store.project.overlays[i].isHidden = makeHidden
            }
        }
    }

    func timelineToggleLaneLocked(_ lane: Int) {
        let clips = store.project.overlays.filter { $0.lane == lane }
        guard !clips.isEmpty else { return }
        let makeLocked = !clips.contains { $0.isLocked }     // chưa cái nào khoá → khoá hết
        store.perform(makeLocked ? L("Khoá cả làn") : L("Mở khoá cả làn")) {
            for i in store.project.overlays.indices where store.project.overlays[i].lane == lane {
                store.project.overlays[i].isLocked = makeLocked
            }
        }
    }

    /// Nút loa đầu làn lớp đè: tắt / bật tiếng MỌI clip mang tiếng trong làn (audio + video).
    func timelineToggleLaneAudioMuted(_ lane: Int) {
        let audible = store.project.overlays.filter {
            $0.lane == lane && ($0.kind == .audio || $0.kind == .video)
        }
        guard !audible.isEmpty else { return }
        let makeMuted = !audible.allSatisfy { $0.audioMuted }   // còn 1 cái mở tiếng → tắt hết
        store.perform(makeMuted ? L("Tắt tiếng cả làn") : L("Bật tiếng cả làn")) {
            for i in store.project.overlays.indices
            where store.project.overlays[i].lane == lane
                && (store.project.overlays[i].kind == .audio || store.project.overlays[i].kind == .video) {
                store.project.overlays[i].audioMuted = makeMuted
            }
        }
    }

    func timelineOverlayFade(_ id: UUID, _ fin: Double, _ fout: Double) {
        store.perform(L("Chỉnh fade lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            let d = store.project.overlays[i].duration
            store.project.overlays[i].fadeIn = max(0, min(fin, d))
            store.project.overlays[i].fadeOut = max(0, min(fout, d))
        }
    }

    func timelineOverlayRename(_ id: UUID, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        store.perform(L("Đổi tên clip")) {
            if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                store.project.overlays[i].name = clean
            }
        }
    }

    /// Chuyển cảnh mờ: kéo clip SAU (`bID`) chồng lên clip trước cùng làn `dur` giây + đặt fadeIn.
    func timelineOverlayTransition(_ bID: UUID, _ dur: Double) {
        store.perform(L("Chuyển cảnh")) {
            guard let bi = store.project.overlays.firstIndex(where: { $0.id == bID }) else { return }
            var b = store.project.overlays[bi]
            guard let a = store.project.overlays
                .filter({ $0.lane == b.lane && $0.id != bID && $0.start < b.start })
                .max(by: { $0.start < $1.start }) else { return }
            let ov = max(0.1, min(dur, b.duration * 0.9, a.duration * 0.9, b.start - a.start))
            b.start = max(a.start, b.start - ov)
            b.fadeIn = ov
            store.project.overlays[bi] = b
        }
    }

    func timelineOverlayDuplicate(_ id: UUID) {
        store.perform(L("Nhân đôi lớp đè")) {
            guard let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
            var copy = store.project.overlays[i]
            copy.id = UUID()
            copy.start = store.project.overlays[i].end
            copy.lane = freeOverlayLane(start: copy.start, end: copy.start + copy.duration)
            store.project.overlays.insert(copy, at: i + 1)
            selectedOverlayID = copy.id
        }
    }

    func toggleOverlayHidden(_ id: UUID) {
        store.perform(L("Ẩn / hiện lớp đè")) {
            if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                store.project.overlays[i].isHidden.toggle()
            }
        }
    }

    /// (U4) Khoá lớp đè — chặn kéo/xoay/phóng nhầm ở preview (KHÔNG chặn ẩn/hiện/xoá).
    func toggleOverlayLocked(_ id: UUID) {
        store.perform(L("Khoá / mở khoá lớp đè")) {
            if let i = store.project.overlays.firstIndex(where: { $0.id == id }) {
                store.project.overlays[i].isLocked.toggle()
            }
        }
    }

    // MARK: - (U6) Kho media — nhập ảnh, kéo xuống timeline để đặt lên video.

    func mediaPoolThumb(_ item: MediaPoolItem, size: CGFloat = 60) -> some View {
        let h = size * 0.7
        let icon: String = {
            switch item.kind {
            case .audio: return "music.note"
            case .video: return "film"
            case .image: return "photo"
            }
        }()
        return VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.elevated)
                if item.kind == .image, let url = item.resolveURL(), let ns = NSImage(contentsOf: url) {
                    Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size, height: h).clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(item.kind == .audio ? Theme.accent : .secondary)
                }
            }
            .frame(width: size, height: h)
            Text(item.name).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(width: size)
        }
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .contextMenu {
            Button(L("Đặt vào timeline (ở mốc đang phát)")) { placeMediaPoolItem(item) }
            Button(L("Xoá khỏi kho"), role: .destructive) { removeMediaPoolItem(item.id) }
        }
        .help(L("Kéo xuống timeline để đặt lên video, hoặc bấm chuột phải"))
    }

    func importMediaPoolImages() {
        let urls = FilePanels.chooseImagesToImport()
        guard !urls.isEmpty else { return }
        store.perform(L("Nhập file vào kho")) {
            for url in urls { store.project.mediaPool.append(MediaPoolItem(url: url)) }
        }
    }

    func removeMediaPoolItem(_ id: UUID) {
        store.perform(L("Xoá file khỏi kho")) { store.project.mediaPool.removeAll { $0.id == id } }
    }

    /// Kéo file TỪ FINDER thẳng vào ô kho (ảnh / nhạc / video).
    func handleMediaPoolFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") })
        else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                store.perform(L("Nhập file vào kho")) { store.project.mediaPool.append(MediaPoolItem(url: url)) }
            }
        }
        return true
    }

    /// Đặt 1 ảnh trong kho lên timeline TẠI MỐC PHÁT HIỆN TẠI — tạo `OverlayClip` mới,
    /// dùng lại ĐÚNG cơ chế lớp đè đã có (không đổi cách vẽ/xuất video).
    func placeMediaPoolItem(_ item: MediaPoolItem, at time: TimeInterval? = nil, lane: Int? = nil) {
        guard let url = item.resolveURL() else { return }
        // NHẠC từ kho: bấm ở lưới (lane == nil) → nạp làm bài chính; KÉO xuống 1 làn lớp đè
        // (lane != nil) → thành CLIP TIẾNG trên làn đó (trộn kèm khi phát + xuất).
        if item.kind == .audio, lane == nil {
            loadAudio(from: url)
            return
        }
        let start = max(0, time ?? playback.currentTime)
        let isVideo = item.kind == .video
        let isAudio = item.kind == .audio
        var dur: TimeInterval = 5
        var srcDur: TimeInterval = 0
        if isVideo || isAudio {
            let d = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            if d.isFinite, d > 0.2 { dur = d; srcDur = d }
        }
        let songDur = max(playback.duration, playback.virtualDuration)
        if songDur > 0.5 { dur = min(dur, max(0.5, songDur - start)) }
        let kind: BackgroundMedia.Kind = isVideo ? .video : (isAudio ? .audio : .image)
        var clip = OverlayClip(kind: kind, url: url, start: start, duration: dur)
        clip.sourceDuration = srcDur
        let targetLane = lane.map { max(0, min(3, $0)) }
        clip.lane = targetLane ?? freeOverlayLane(start: start, end: clip.end)
        store.perform(isVideo ? L("Đặt video lên timeline")
                      : isAudio ? L("Đặt tiếng lên timeline") : L("Đặt ảnh từ kho lên timeline")) {
            // Thả TRÚNG 1 làn → chèn kiểu ripple: clip nào ở làn đó mà chồng/đứng sau
            // điểm thả thì đẩy sang phải để chừa chỗ (như CapCut).
            if let tl = targetLane {
                for i in store.project.overlays.indices
                where store.project.overlays[i].lane == tl
                    && store.project.overlays[i].end > clip.start + 0.001 {
                    store.project.overlays[i].start += clip.duration
                }
            }
            store.project.overlays.append(clip)
        }
        selectedOverlayID = clip.id
    }

    /// Kéo–thả 1 item kho xuống ĐÚNG làn + mốc trên timeline (từ canvas AppKit).
    func timelineMediaDropAt(_ idStr: String, _ time: Double, _ lane: Int) {
        if idStr == Self.newTextDragToken { addTextOverlay(at: max(0, time), lane: lane); return }
        guard let id = UUID(uuidString: idStr),
              let item = store.project.mediaPool.first(where: { $0.id == id }) else { return }
        placeMediaPoolItem(item, at: time, lane: lane)
    }

    /// Chuỗi đánh dấu khi KÉO nút "Thêm 1 lớp chữ" thả xuống timeline.
    static let newTextDragToken = "karaoke.newtext"


    func replaceOverlayImage(_ id: UUID) {
        guard let url = FilePanels.chooseBackgroundImage(),
              let i = store.project.overlays.firstIndex(where: { $0.id == id }) else { return }
        var clip = store.project.overlays[i]
        clip.lastKnownPath = url.path
        clip.name = url.deletingPathExtension().lastPathComponent
        clip.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        store.perform(L("Đổi ảnh lớp đè")) { store.project.overlays[i] = clip }
        OverlayImageStore.flush()
    }

    func overlayCoverScale(_ clip: OverlayClip) -> Double {
        guard let img = OverlayImageStore.image(for: clip) else { return 1.9 }
        let r = store.project.resolution
        let cw = CGFloat(r.width), ch = CGFloat(r.height)
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0, cw > 0, ch > 0 else { return 1.9 }
        let fitBase = min(cw / iw, ch / ih)
        let fillBase = max(cw / iw, ch / ih)
        return fitBase > 0 ? Double(fillBase / fitBase) : 1.9
    }
}
