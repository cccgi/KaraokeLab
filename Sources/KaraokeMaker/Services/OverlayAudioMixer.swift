import Foundation
import AVFoundation
import QuartzCore

/// Phát TIẾNG của các clip VIDEO lớp đè trong lúc XEM THỬ (khi bật "Bật tiếng của clip video").
///
/// HOÀN TOÀN TÁCH KHỎI bài hát chính: mỗi clip 1 `AVPlayer` riêng (chỉ lấy track audio),
/// không đụng tới `PlaybackController` / `AVAudioPlayer` của bài hát. Mặc định TẮT nên
/// project cũ + hành vi cũ không đổi. Chỉ chạy khi có ít nhất 1 clip bật tiếng.
@MainActor
final class OverlayAudioMixer: ObservableObject {

    /// View cấp 2 nguồn: danh sách clip cần phát tiếng + đồng hồ hiện tại.
    var clipsProvider: (() -> [OverlayClip])?
    var clockProvider: (() -> (time: TimeInterval, playing: Bool))?

    private final class Entry {
        let player: AVPlayer
        var path: String
        var seeking = false
        init(player: AVPlayer, path: String) { self.player = player; self.path = path }
    }
    private var entries: [UUID: Entry] = [:]
    private var ticker: Timer?

    // MARK: Vòng đời

    func activate() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] tm in
            guard let self else { tm.invalidate(); return }   // view đã biến mất mà quên deactivate
            Task { @MainActor in self.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func deactivate() {
        ticker?.invalidate()
        ticker = nil
        stopAll()
    }

    func stopAll() {
        for (_, e) in entries { e.player.pause() }
        entries.removeAll()
    }

    // MARK: Đồng bộ

    private func tick() {
        guard let cp = clipsProvider, let kp = clockProvider else { return }
        let clips = cp()
        if clips.isEmpty && entries.isEmpty { return }
        let s = kp()
        sync(clips: clips, time: s.time, playing: s.playing)
    }

    /// Gọi mỗi nhịp (và ngay khi play/pause/seek đổi).
    func sync(clips: [OverlayClip], time: TimeInterval, playing: Bool) {
        // 1) Bỏ player của clip không còn trong danh sách.
        let wanted = Set(clips.map(\.id))
        for (id, e) in entries where !wanted.contains(id) {
            e.player.pause(); entries[id] = nil
        }

        // 2) Tạo / cập nhật player cho từng clip.
        for clip in clips {
            guard let url = clip.resolveURL() else {
                if let e = entries[clip.id] { e.player.pause(); entries[clip.id] = nil }
                continue
            }
            var entry = entries[clip.id]
            if entry == nil || entry!.path != url.path {
                entry?.player.pause()
                guard let p = Self.makeAudioPlayer(url) else {
                    entries[clip.id] = nil; continue         // video không có tiếng → bỏ qua êm
                }
                entry = Entry(player: p, path: url.path)
                entries[clip.id] = entry
            }
            guard let entry else { continue }
            let player = entry.player

            let active = time >= clip.start - 0.03 && time < clip.end
            guard active else {
                if player.rate != 0 { player.pause() }
                continue
            }

            // Âm lượng theo fade in/out của clip.
            var v = 1.0
            let into = time - clip.start
            let toEnd = clip.end - time
            if clip.fadeIn > 0.01 { v = min(v, max(0, into / clip.fadeIn)) }
            if clip.fadeOut > 0.01 { v = min(v, max(0, toEnd / clip.fadeOut)) }
            player.volume = Float(max(0, min(1, v)))

            // Bám thời gian: chỉ seek khi lệch nhiều (AVPlayer tự chạy mượt giữa 2 nhịp).
            let target = max(0, clip.trimStart + into)
            let cur = player.currentTime().seconds
            if !entry.seeking, cur.isFinite, abs(cur - target) > 0.30 {
                entry.seeking = true
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: CMTime(value: 1, timescale: 30)) { [weak entry] _ in
                    // `Entry` isn't itself @MainActor and AVPlayer doesn't guarantee this handler
                    // runs on any particular thread — every other access to `seeking` (in `tick()`)
                    // is MainActor-isolated, so hop back explicitly rather than write from wherever
                    // AVFoundation happens to call this.
                    Task { @MainActor in entry?.seeking = false }
                }
            }

            if playing {
                if player.rate == 0 { player.play() }
            } else {
                if player.rate != 0 { player.pause() }
            }
        }
    }

    // MARK: Helper

    /// `AVPlayer` chỉ chứa track AUDIO của file (khỏi giải mã video cho nhẹ).
    private static func makeAudioPlayer(_ url: URL) -> AVPlayer? {
        let asset = AVURLAsset(url: url)
        guard let aTrack = asset.tracks(withMediaType: .audio).first else { return nil }
        let comp = AVMutableComposition()
        guard let dst = comp.addMutableTrack(withMediaType: .audio,
                                             preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        try? dst.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: aTrack, at: .zero)
        let p = AVPlayer(playerItem: AVPlayerItem(asset: comp))
        p.automaticallyWaitsToMinimizeStalling = false
        p.actionAtItemEnd = .pause
        return p
    }
}
