import Foundation
import AVFoundation
import Combine
import QuartzCore
import SwiftUI

/// Điều khiển phát audio: load / play / pause / seek, và phát ra thời gian hiện tại.
///
/// Phase 1 dùng `AVAudioPlayer` cho đơn giản. Nếu sau này cần độ chính xác
/// cao hơn (word-level, đồng bộ waveform), chỉ thay phần ruột trong file này;
/// giao diện public giữ nguyên nên phần còn lại của app không phải sửa.
/// Đồng hồ hiển thị NHẸ. Chỉ vài ô nhỏ (nhãn giờ, thanh tua, badge "đang hát")
/// theo dõi nó — `ContentView` KHÔNG, để không bị dựng lại 1 lần/giây khi phát.
///
/// (2026-09-15) `seconds` KHÔNG còn `@Published` — sửa lần 3 (`withTransaction(animation: nil)`)
/// đo `sample` trên iMac 2017 vẫn thấy MỖI lần đổi giá trị này (dù không animate) làm AppKit chạy
/// lại Auto Layout CẢ CỬA SỔ (`+[NSAnimationContext runAnimationGroup:]`), vì việc publish qua
/// `ObservableObject`/`EnvironmentObject` tự nó đã kích hoạt 1 "commit" ở cầu SwiftUI↔AppKit, bất
/// kể có animation hay không. 3 nơi DUY NHẤT đọc `seconds` (`TransportBar`/`NowPlayingBadge`/
/// `PlaybackTicks` trong `PlaybackHUD.swift`) đổi sang tự polling bằng `TimelineView(.periodic)`
/// — cơ chế Apple làm riêng cho UI cập nhật liên tục (đồng hồ, hoạt hình) mà KHÔNG đi qua
/// `objectWillChange`/commit toàn cửa sổ. `seconds` giờ chỉ là biến thường, mấy view đó tự đọc
/// mỗi nhịp `TimelineView` thay vì được "đẩy" tới.
@MainActor
final class PlaybackClock: ObservableObject {
    fileprivate(set) var seconds: TimeInterval = 0

    /// (2026-09-17) Đếm mỗi lần tua/nạp (để Timeline & Preview vẽ lại đúng khung khi DỪNG) —
    /// TRƯỚC nằm ở `PlaybackController.seekGeneration` (`@Published`). Vì `ContentView` giữ
    /// `PlaybackController` qua `@EnvironmentObject`, MỖI lần tua (kể cả tua liên tục lúc kéo
    /// thanh) publish qua đó khiến TOÀN BỘ `ContentView` (cây 3 cột + timeline) bị đánh dấu dựng
    /// lại — đo `sample` lúc kéo/tua thấy đúng chuỗi Auto Layout CẢ CỬA SỔ (~50% luồng chính,
    /// giật 200ms–vài giây trên máy Intel cũ) dù CHẲNG có gì ở 3 cột kia cần đổi khi tua. Dời
    /// sang đây — `PlaybackClock` vốn đã tách riêng (chỉ `TimelineEditor`/`KaraokePreview` mới
    /// cần đọc số này, `ContentView` KHÔNG giữ `@EnvironmentObject var clock` — xác nhận qua grep
    /// toàn repo) — tua bao nhiêu lần cũng KHÔNG còn kéo `ContentView` dựng lại nữa, chỉ 2 view
    /// thực sự cần mới bị ảnh hưởng.
    @Published private(set) var seekGeneration: Int = 0
    fileprivate func bumpSeek() { seekGeneration += 1 }
}

@MainActor
final class PlaybackController: NSObject, ObservableObject {

    let clock = PlaybackClock()

    @Published private(set) var isLoaded: Bool = false
    @Published private(set) var isPlaying: Bool = false
    /// Tăng mỗi lần tua / nạp file — để Preview & Timeline vẽ lại đúng khung khi DỪNG.
    /// (2026-09-17) Dời sang `clock.seekGeneration` — xem comment ở `PlaybackClock`. Đọc qua
    /// `seekGeneration` bên dưới (tương thích ngược cho code cũ) chỉ là lối tắt đọc `clock`.
    var seekGeneration: Int { clock.seekGeneration }

    /// Vị trí phát hiện tại (giây). KHÔNG `@Published` — đọc trực tiếp, không kéo
    /// theo việc dựng lại giao diện. Phần hiển thị đi qua `clock`.
    private(set) var currentTime: TimeInterval = 0

    /// Vị trí AUDIO thô ngay lúc này (không nội suy). Dùng để ghim vạch đỏ lúc pause
    /// ĐÚNG chỗ audio dừng — đọc ngay trong `pause()` nên không dính độ trễ round-trip.
    var audioTimeRaw: TimeInterval {
        if leadOffset > 0.0001 { return currentTime }        // đã là giờ-timeline
        return player?.currentTime ?? currentTime
    }
    /// Tổng thời lượng file, tính bằng giây.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?
    @Published var lastError: String?

    /// Đường bao biên độ để vẽ sóng âm (0...1). Rỗng khi chưa phân tích xong.
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var isAnalyzingWaveform: Bool = false

    /// Độ dài "dòng thời gian" khi CHƯA nạp nhạc — do `TimelineEditor` cập nhật.
    /// Nhờ nó, vạch đỏ vẫn TUA và CHẠY được trên timeline dù chưa có audio
    /// (đường app-edit: kéo playhead để chọn chỗ cắt, xem trước…).
    @Published var virtualDuration: TimeInterval = 0

    /// Bước 2c — clip ★ KARAOKE: cả bản karaoke (nhạc + lời) bắt đầu ở giây `leadOffset`
    /// trên DÒNG THỜI GIAN. `renderTime`/`currentTime` = giờ-timeline; audio phát trễ đúng
    /// bằng `leadOffset`. `leadOffset == 0` ⇒ mọi thứ y hệt như trước.
    private(set) var leadOffset: TimeInterval = 0
    func setLeadOffset(_ v: TimeInterval) {
        let nv = max(0, v)
        guard abs(nv - leadOffset) > 0.0005 else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        leadOffset = nv
        seek(to: currentTime)          // nắn player + đồng hồ về đúng giờ-timeline hiện tại
        if wasPlaying { play() }
    }

    /// Trần để tua tới: có nhạc → theo file (+ mốc clip ★); chưa có → theo timeline ảo.
    var seekCeiling: TimeInterval {
        isLoaded ? max(leadOffset + duration, virtualDuration) : max(virtualDuration, 0)
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var waveformTask: Task<Void, Never>?

    // M-D · Cắt bài + âm lượng. `trimEnd == 0` ⇒ hết bài.
    private(set) var audioTrimStart: TimeInterval = 0
    private(set) var audioTrimEnd: TimeInterval = 0
    private(set) var audioGain: Double = 1
    private(set) var audioMuted: Bool = false
    private var effectiveVolume: Float { audioMuted ? 0 : Float(max(0, min(1, audioGain))) }
    /// Có cắt bài không (chỉ khi đó mới giới hạn vùng phát).
    private var hasAudioTrim: Bool { audioTrimStart > 0.05 || audioTrimEnd > 0.05 }
    /// Khoảng phát hiệu lực (sau khi cắt). Không cắt → [0, duration].
    var playLo: TimeInterval { hasAudioTrim ? max(0, audioTrimStart) : 0 }
    var playHi: TimeInterval {
        let hardEnd = duration > 0 ? duration : .greatestFiniteMagnitude
        return (hasAudioTrim && audioTrimEnd > 0.05) ? min(audioTrimEnd, hardEnd) : hardEnd
    }

    /// `ContentView` gọi mỗi khi project đổi các thông số này (kể cả lúc nạp bài).
    func applyAudioSettings(trimStart: TimeInterval, trimEnd: TimeInterval, gain: Double, muted: Bool = false) {
        audioTrimStart = max(0, trimStart)
        audioTrimEnd = max(0, trimEnd)
        audioGain = min(1, max(0, gain))
        audioMuted = muted
        player?.volume = effectiveVolume
    }

    // Transport ẢO (không audio).
    private var virtualTicker: Timer?
    private var virtualPlaying = false
    private var virtualAnchorHost: CFTimeInterval = 0
    private var virtualAnchorTime: TimeInterval = 0

    /// Cập nhật `currentTime`/`clock.seconds` CHẬM thôi — chỉ để nhãn giờ/thanh tua/dòng đang
    /// hát có giá trị mới khi `TimelineView` (trong `PlaybackHUD.swift`) tự ghé đọc mỗi 1/3 giây
    /// (KHÔNG phải vạch đỏ mượt — cái đó đọc `renderTime` riêng, không qua đây). Khớp tần suất
    /// polling của `TimelineView` — nhanh hơn cũng vô ích vì không ai đọc kịp giữa 2 lần polling.
    private let tickInterval: TimeInterval = 1.0 / 3.0

    /// Neo để NỘI SUY thời gian: `AVAudioPlayer.currentTime` nhảy theo nấc nên
    /// giữa các lần nó cập nhật thật, ta cộng thêm thời gian trôi của đồng hồ hệ thống.
    private var anchorHost: CFTimeInterval = 0
    private var anchorPlayer: TimeInterval = 0

    private func reanchor() {
        anchorHost = CACurrentMediaTime()
        anchorPlayer = player?.currentTime ?? 0
    }

    /// (2026-09-14, sửa lại 2026-09-15) `seconds` giờ là biến thường (không `@Published` —
    /// xem comment ở `PlaybackClock`), nên gán thẳng, không cần `withTransaction` nữa: KHÔNG
    /// còn publish qua Combine → không còn kích hoạt commit SwiftUI↔AppKit mỗi lần đổi.
    private func setClockSeconds(_ t: TimeInterval) {
        clock.seconds = t
    }

    /// Thời gian phát MƯỢT — các canvas tự đọc để vẽ.
    /// CHỈ chạy theo đồng hồ hệ thống (mượt tuyệt đối), neo lại ở play/seek.
    /// KHÔNG chỉnh theo `player.currentTime` khi đang chạy vì giá trị đó nhảy nấc
    /// → chỉnh theo nó = nhập lại đúng cái giật cần tránh. Lệch host/audio suốt
    /// 1 bài chỉ vài ms, không thấy được.
    var renderTime: TimeInterval {
        if virtualPlaying {
            let t = virtualAnchorTime + (CACurrentMediaTime() - virtualAnchorHost)
            let hi = leadOffset > 0.0001 ? max(virtualDuration, leadOffset + duration, 0.01)
                                         : max(virtualDuration, 0.01)
            return min(max(0, t), hi)
        }
        guard isPlaying, let player, player.isPlaying else {
            if leadOffset > 0.0001 { return min(max(0, currentTime), leadOffset + duration) }
            return player?.currentTime ?? currentTime
        }
        let t = anchorPlayer + (CACurrentMediaTime() - anchorHost)
        return min(max(0, t), duration)
    }

    // MARK: - Nạp / gỡ file

    func load(url: URL) {
        stopTicker()
        stopVirtualTicker(); virtualPlaying = false
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.prepareToPlay()

            player = newPlayer
            newPlayer.volume = effectiveVolume
            duration = newPlayer.duration
            currentTime = 0
            setClockSeconds(0)
            clock.bumpSeek()
            isPlaying = false
            isLoaded = true
            loadedURL = url
            lastError = nil

            startWaveformAnalysis(for: url)
        } catch {
            player = nil
            isLoaded = false
            isPlaying = false
            duration = 0
            currentTime = 0
            loadedURL = nil
            lastError = "Không mở được file nhạc: \(error.localizedDescription)"
        }
    }

    func clearError() {
        lastError = nil
    }

    func unload() {
        stopTicker()
        stopVirtualTicker(); virtualPlaying = false
        waveformTask?.cancel()
        waveformTask = nil
        waveformTaskURL = nil
        player?.stop()
        player = nil
        isLoaded = false
        isPlaying = false
        currentTime = 0
        setClockSeconds(0)
        duration = 0
        loadedURL = nil
        lastError = nil
        waveform = []
        isAnalyzingWaveform = false
    }

    /// File mà sóng âm đang phân tích. KHÁC `loadedURL`: `swapSource` (bật/tắt karaoke)
    /// đổi `loadedURL` nhưng KHÔNG đổi cái này → kết quả sóng vẫn về đúng, không bị bỏ.
    private var waveformTaskURL: URL?

    private func startWaveformAnalysis(for url: URL) {
        waveformTask?.cancel()
        waveformTaskURL = url
        waveform = []
        isAnalyzingWaveform = true
        waveformTask = Task { [weak self] in
            let peaks = await WaveformLoader.load(url: url)
            guard let self, !Task.isCancelled, self.waveformTaskURL == url else { return }
            self.waveform = peaks
            self.isAnalyzingWaveform = false
        }
    }

    // MARK: - Điều khiển

    func play() {
        if player != nil, leadOffset > 0.0001 {
            // Bước 2c — clip ★ có mốc trễ: transport ẢO làm chủ đồng hồ (giờ-timeline),
            // AVAudioPlayer phát THEO — bật khi vạch đỏ vào vùng bài, tắt khi ra ngoài.
            let hi = max(virtualDuration, leadOffset + duration)
            if currentTime >= hi - 0.05 { currentTime = 0; setClockSeconds(0) }
            virtualPlaying = true
            isPlaying = true
            virtualAnchorHost = CACurrentMediaTime()
            virtualAnchorTime = currentTime
            startVirtualTicker()
            syncSlavedAudio(force: true)
            return
        }
        if let player {
            // M-D — CHỈ khi có cắt bài mới nhảy vào vùng cắt.
            if hasAudioTrim, currentTime < playLo - 0.01 || currentTime >= playHi - 0.02 {
                let t = playLo
                player.currentTime = t; currentTime = t; setClockSeconds(t); clock.bumpSeek()
            }
            player.volume = effectiveVolume
            player.play()
            isPlaying = true
            reanchor()
            startTicker()
            return
        }
        // Chưa có nhạc → chạy transport ẢO để xem trước dòng thời gian.
        let hi = max(virtualDuration, 0)
        guard hi > 0.1 else { return }
        if currentTime >= hi - 0.05 { currentTime = 0; setClockSeconds(0) }
        virtualPlaying = true
        isPlaying = true
        virtualAnchorHost = CACurrentMediaTime()
        virtualAnchorTime = currentTime
        startVirtualTicker()
    }

    func pause() {
        if virtualPlaying {
            let hi = leadOffset > 0.0001 ? max(virtualDuration, leadOffset + duration)
                                         : max(virtualDuration, 0)
            currentTime = min(virtualAnchorTime + (CACurrentMediaTime() - virtualAnchorHost), hi)
            virtualPlaying = false
            stopVirtualTicker()
            player?.pause()                 // audio nô lệ (nếu đang phát theo)
            isPlaying = false
            setClockSeconds(currentTime)
            clock.bumpSeek()
            return
        }
        player?.pause()
        isPlaying = false
        stopTicker()
        if let player { currentTime = player.currentTime }   // chốt đúng vị trí
        setClockSeconds(currentTime)
        clock.bumpSeek()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Tua tới một mốc thời gian tuyệt đối (giây). Chạy được cả khi CHƯA có nhạc
    /// (vạch đỏ ảo trên timeline — để chọn chỗ cắt, xem trước…).
    func seek(to time: TimeInterval) {
        let ceil = seekCeiling
        let clamped = ceil > 0 ? min(max(0, time), ceil) : max(0, time)
        if leadOffset > 0.0001, let player {
            // `clamped` = giờ-timeline. Audio đứng ở `clamped − leadOffset` của bài (kẹp vùng cắt).
            let songT = clamped - leadOffset
            let lo = playLo, hi = playHi > 0 ? playHi : duration
            if songT >= lo - 0.03 && songT <= hi + 0.03 {
                player.currentTime = min(max(lo, songT), max(0, duration - 0.02))
            } else {
                player.currentTime = max(0, min(lo, duration - 0.02))
                if player.isPlaying { player.pause() }
            }
            currentTime = clamped
            setClockSeconds(clamped)
            clock.bumpSeek()
            if virtualPlaying {
                virtualAnchorHost = CACurrentMediaTime()
                virtualAnchorTime = clamped
                syncSlavedAudio(force: true)
            }
            reanchor()
            return
        }
        player?.currentTime = clamped
        currentTime = clamped
        setClockSeconds(clamped)
        clock.bumpSeek()
        if virtualPlaying {
            virtualAnchorHost = CACurrentMediaTime()
            virtualAnchorTime = clamped
        }
        reanchor()
    }

    /// Bật / tắt AVAudioPlayer nô lệ theo `currentTime` (giờ-timeline) khi `leadOffset > 0`.
    /// Không "nắn" liên tục lúc đang phát — bật 1 lần đúng chỗ rồi để chạy tự do.
    private func syncSlavedAudio(force: Bool = false) {
        guard leadOffset > 0.0001, let player, virtualPlaying else { return }
        let songNow = currentTime - leadOffset
        let lo = playLo, hi = playHi > 0 ? playHi : duration
        let inSong = songNow >= lo - 0.03 && songNow < hi - 0.03
        if inSong {
            if force || !player.isPlaying {
                player.currentTime = min(max(lo, songNow), max(lo, duration - 0.02))
                player.volume = effectiveVolume
                if !player.isPlaying { player.play() }
            }
        } else if player.isPlaying {
            player.pause()
        }
    }

    /// Tua tương đối (ví dụ -5 hoặc +5 giây).
    func seekBy(_ delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    /// Đổi FILE đang phát mà GIỮ vị trí + trạng thái phát. Dùng cho nút bật/tắt karaoke
    /// (đổi qua lại giữa bài gốc và beat). KHÔNG phân tích lại sóng âm.
    func swapSource(to url: URL) {
        guard url != loadedURL else { return }
        let wasPlaying = isPlaying
        let tl = wasPlaying ? renderTime : currentTime      // giờ-timeline
        do {
            let np = try AVAudioPlayer(contentsOf: url)
            np.delegate = self
            np.prepareToPlay()
            player?.stop()
            player = np
            duration = np.duration
            loadedURL = url
            let songT = min(max(0, tl - leadOffset), np.duration)
            np.currentTime = songT
            currentTime = tl
            setClockSeconds(tl)
            clock.bumpSeek()
            if wasPlaying {
                if leadOffset > 0.0001 { syncSlavedAudio(force: true) }
                else { np.play() }
            }
            reanchor()
        } catch {
            lastError = "Không đổi được nguồn phát: \(error.localizedDescription)"
        }
    }

    // MARK: - Cập nhật thời gian

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.syncTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: Transport ẢO (không audio)

    private func startVirtualTicker() {
        stopVirtualTicker()
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.virtualSync() }
        }
        RunLoop.main.add(timer, forMode: .common)
        virtualTicker = timer
    }

    private func stopVirtualTicker() {
        virtualTicker?.invalidate()
        virtualTicker = nil
    }

    private func virtualSync() {
        guard virtualPlaying else { return }
        let hi = leadOffset > 0.0001 ? max(virtualDuration, leadOffset + duration, 0.01)
                                     : max(virtualDuration, 0.01)
        let t = virtualAnchorTime + (CACurrentMediaTime() - virtualAnchorHost)
        if t >= hi {
            currentTime = hi
            setClockSeconds(hi)
            virtualPlaying = false
            isPlaying = false
            stopVirtualTicker()
            player?.pause()
            clock.bumpSeek()
            return
        }
        currentTime = t
        syncSlavedAudio()                 // bật/tắt audio nô lệ khi vào/ra vùng bài (leadOffset > 0)
        if Int(t * 2) != Int(clock.seconds * 2) { setClockSeconds(t) }
    }

    private func syncTime() {
        guard leadOffset < 0.0001 else { return }   // leadOffset > 0 dùng virtualSync
        guard let player else { return }
        let t = player.currentTime
        currentTime = t                          // biến thường, không phát tín hiệu
        // `clock` (chỉ vài ô nhỏ theo dõi) cập nhật ~2 lần/giây cho nhãn giờ + thanh tua.
        if Int(t * 2) != Int(clock.seconds * 2) {
            setClockSeconds(t)
        }
        // M-D — CHỈ khi có cắt bài: chạm cuối vùng đã cắt → dừng. Bài đủ để `didFinishPlaying` lo.
        if isPlaying, hasAudioTrim, audioTrimEnd > 0.05, duration > 0,
           t >= min(audioTrimEnd, duration) - 0.03 {
            player.pause()
            currentTime = min(audioTrimEnd, duration); setClockSeconds(currentTime)
            isPlaying = false
            stopTicker()
            clock.bumpSeek()
            return
        }
        if isPlaying && !player.isPlaying {
            isPlaying = false
            stopTicker()
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension PlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // leadOffset > 0: audio hết nhưng transport ẢO còn chạy (có thể còn lớp đè phía sau).
            if self.leadOffset > 0.0001, self.virtualPlaying { return }
            self.isPlaying = false
            self.stopTicker()
            self.currentTime = self.leadOffset + self.duration
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.stopTicker()
            self?.lastError = "Lỗi giải mã audio: \(error?.localizedDescription ?? "không rõ")"
        }
    }
}
