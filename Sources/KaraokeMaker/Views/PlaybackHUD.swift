import SwiftUI

/// Thanh phát — theo dõi `PlaybackClock` (nhẹ), KHÔNG làm `ContentView` dựng lại.
struct TransportBar: View {
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var clock: PlaybackClock
    var onSeek: (Double) -> Void
    /// Nút bật/tắt karaoke (đổi giữa bài gốc và beat). Ẩn nếu `nil`.
    var karaokeOn: Bool = false
    var karaokeAvailable: Bool = false
    var onKaraoke: () -> Void = {}

    /// Có gì để phát / tua? (nhạc thật hoặc dòng thời gian ảo khi chưa nạp nhạc)
    private var canTransport: Bool { playback.isLoaded || playback.virtualDuration > 0.1 }
    private var timelineTotal: TimeInterval {
        playback.isLoaded ? playback.duration : playback.virtualDuration
    }

    var body: some View {
        // (2026-09-15, sửa lại cùng ngày) `TimelineView(.periodic)` CHỈ khi đang phát — bản đầu
        // để TimelineView chạy VÔ ĐIỀU KIỆN (kể cả lúc KHÔNG phát) khiến nó tự polling MÃI MÃI hễ
        // thanh này còn hiện trên màn hình, tệ hơn cả bản cũ (bản cũ chỉ tick lúc `play()` gọi
        // `startTicker()`). Đo lại bằng `sample` thấy relayout CẢ CỬA SỔ vẫn chiếm ~67% luồng
        // chính dù KHÔNG phát nhạc — đúng nguyên nhân "lag cả lúc không phát" user báo. Giờ CHỈ
        // bọc `TimelineView` khi `playback.isPlaying`; lúc dừng, `body` là view TĨNH bình thường,
        // không có gì tự polling nữa.
        Group {
            if playback.isPlaying {
                TimelineView(.periodic(from: .now, by: 1.0 / 3.0)) { _ in transportContent }
            } else {
                transportContent
            }
        }
    }

    private var transportContent: some View {
        // Thanh phát PHẲNG ngay dưới preview (không thẻ) — DESIGN_SYSTEM §11.
        HStack(spacing: Theme.Space.l) {
            Button { playback.seekBy(-5) } label: { Image(systemName: "gobackward.5") }
                .buttonStyle(.kmIcon).disabled(!canTransport).help(L("Lùi 5 giây"))

            Button { playback.togglePlayPause() } label: {
                Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canTransport ? Theme.accent : Theme.inkDisabled)
            }
            .buttonStyle(.borderless).disabled(!canTransport)
            .help(playback.isPlaying ? L("Dừng (Space)") : L("Phát (Space)"))

            Button { playback.seekBy(5) } label: { Image(systemName: "goforward.5") }
                .buttonStyle(.kmIcon).disabled(!canTransport).help(L("Tới 5 giây"))

            karaokeToggle

            HStack(spacing: 0) {
                Text(TimeFormatting.clock(clock.seconds)).foregroundColor(Theme.ink)
                Text(" / \(TimeFormatting.clock(timelineTotal))").foregroundColor(Theme.inkFaint)
            }
            .font(Theme.Typo.mono)
            .layoutPriority(1)

            KMSlider(value: clock.seconds, range: 0...max(timelineTotal, 0.01),
                     accessibilityLabel: L("Vị trí phát"),
                     accessibilityText: TimeFormatting.clock(clock.seconds)) { onSeek($0) }
                .disabled(!canTransport)
        }
        .padding(.horizontal, Theme.Space.xs)
        .frame(height: 40)
    }

    private var karaokeToggle: some View {
        let on = karaokeOn && karaokeAvailable
        return Button(action: onKaraoke) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "music.mic").font(Theme.Typo.icon)
                Text("Karaoke").font(Theme.Typo.labelStrong)
                Text(on ? L("BẬT") : L("TẮT"))
                    .font(Theme.Typo.badge)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.xs)
                        .fill(on ? Color.white.opacity(0.25) : Color.white.opacity(0.10)))
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.ControlH.regular)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(on ? Theme.accent : Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(on ? Color.clear : Theme.stroke, lineWidth: 1))
            .foregroundStyle(on ? Color.white : (karaokeAvailable ? Theme.ink : Theme.inkDisabled))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!karaokeAvailable)
        .help(karaokeAvailable ? L("Đổi giữa bài gốc và beat (giữ nguyên vị trí)")
                               : L("Bấm “Tạo Karaoke” để tách beat trước"))
    }
}

/// Chữ "Đang hát: N" — theo dõi `PlaybackClock`.
struct NowPlayingBadge: View {
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var clock: PlaybackClock
    let lines: [LyricLine]

    var body: some View {
        // Xem comment ở `TransportBar.body` — CHỈ polling lúc đang phát, đứng yên thì là view tĩnh.
        Group {
            if playback.isPlaying {
                TimelineView(.periodic(from: .now, by: 1.0 / 3.0)) { _ in badgeContent }
            } else {
                badgeContent
            }
        }
    }

    @ViewBuilder private var badgeContent: some View {
        if let a = TimingEditor.activeIndex(lines, at: clock.seconds) {
            Text(String(format: L("Đang hát: %d"), a + 1)).font(.caption).foregroundStyle(.green)
        }
    }
}

/// View vô hình — theo dõi `PlaybackClock` để chạy các phản ứng phụ (con trỏ dòng
/// đi theo bài, tự reset câu bấm T dở) mà KHÔNG kéo `ContentView` dựng lại 2 lần/giây.
struct PlaybackTicks: View {
    @EnvironmentObject var clock: PlaybackClock
    let isPlaying: Bool
    let canFollow: Bool
    let lines: [LyricLine]
    @Binding var currentLineIndex: Int
    var onSecond: (TimeInterval) -> Void

    /// Bật lại con trỏ dòng đi theo bài? (tạm TẮT để phát KHÔNG dựng lại ContentView.)
    var followCurrentLine = false

    private var tickContent: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: clock.seconds) { t in
                onSecond(t)
                guard followCurrentLine, isPlaying, canFollow,
                      let a = TimingEditor.activeIndex(lines, at: t),
                      a >= currentLineIndex else { return }
                currentLineIndex = a
            }
    }

    var body: some View {
        // Xem comment ở `TransportBar.body` — CHỈ polling lúc đang phát (`isPlaying` truyền vào
        // sẵn). Đứng yên thì `clock.seconds` cũng không đổi (ticker đã dừng theo `pause()`), nên
        // không polling cũng không mất gì — chỉ là KHÔNG tự kéo cả cửa sổ relayout vô ích nữa.
        if isPlaying {
            TimelineView(.periodic(from: .now, by: 1.0 / 3.0)) { _ in tickContent }
        } else {
            tickContent
        }
    }
}
