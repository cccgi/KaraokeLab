import SwiftUI
import AVFoundation
import AppKit
import CoreImage

/// Chất lượng khung video nền khi xem thử (giảm tải giải mã cho máy yếu).
enum PreviewQuality: String, CaseIterable, Identifiable {
    case low = "Thấp"
    case medium = "Vừa"
    case high = "Cao"
    var id: String { rawValue }

    /// Giới hạn cạnh dài khung video khi giải mã. `nil` = không giới hạn.
    var maxDimension: CGFloat? {
        switch self {
        case .low: return 480
        case .medium: return 854
        case .high: return nil
        }
    }
}

/// Lớp video nền chạy sau chữ karaoke trong Preview.
/// Đồng bộ thời gian với playhead của bài hát (AVAudioPlayer), tự tua khi lệch.
struct VideoBackgroundView: NSViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let currentTime: TimeInterval
    let quality: PreviewQuality
    let scale: Double
    let offsetX: Double
    let offsetY: Double
    let opacity: Double
    var colorAdjust: ColorAdjust = ColorAdjust()   // C6 — chỉnh màu nền video (preview)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerContainerView {
        PlayerContainerView()
    }

    func updateNSView(_ view: PlayerContainerView, context: Context) {
        let coord = context.coordinator

        if coord.currentURL != url {
            coord.currentURL = url
            let item = AVPlayerItem(url: url)
            apply(quality, to: item)
            coord.appliedQuality = quality
            coord.appliedColorKey = nil
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.actionAtItemEnd = .pause
            coord.player = player
            view.playerLayer.player = player
        }

        if coord.appliedQuality != quality, let item = coord.player?.currentItem {
            apply(quality, to: item)
            coord.appliedQuality = quality
        }

        // C6 — chỉnh màu qua videoComposition (cùng ColorPipeline như export).
        let colorKey = colorAdjust.isIdentity ? "" : colorAdjust.key
        if coord.appliedColorKey != colorKey, let item = coord.player?.currentItem {
            coord.appliedColorKey = colorKey
            if colorAdjust.isIdentity {
                item.videoComposition = nil
            } else {
                let adj = colorAdjust
                item.videoComposition = AVMutableVideoComposition(
                    asset: item.asset,
                    applyingCIFiltersWithHandler: { req in
                        let out = ColorPipeline.process(req.sourceImage.clampedToExtent(), adj)
                            .cropped(to: req.sourceImage.extent)
                        req.finish(with: out, context: ColorPipeline.context)
                    })
            }
        }

        view.userScale = scale
        view.userOffset = CGPoint(x: offsetX, y: offsetY)
        view.bgOpacity = opacity

        guard let player = coord.player else { return }
        let target = CMTime(seconds: max(0, currentTime), preferredTimescale: 600)
        let drift = abs(player.currentTime().seconds - currentTime)

        if isPlaying {
            if player.rate == 0 {
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    player.playImmediately(atRate: 1)
                }
            } else if drift > 0.35 {
                let tol = CMTime(seconds: 0.2, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: tol, toleranceAfter: tol)
            }
        } else {
            if player.rate != 0 { player.pause() }
            if drift > 0.04 {
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func apply(_ q: PreviewQuality, to item: AVPlayerItem) {
        if let d = q.maxDimension {
            item.preferredMaximumResolution = CGSize(width: d, height: d)
        } else {
            item.preferredMaximumResolution = .zero
        }
    }

    final class Coordinator {
        var player: AVPlayer?
        var currentURL: URL?
        var appliedQuality: PreviewQuality?
        var appliedColorKey: String?
    }
}

/// NSView layer-backed chứa AVPlayerLayer; áp phóng to / lệch / độ mờ theo ý người dùng.
final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    // `updateNSView` gọi lại nhiều lần/giây lúc phát (theo `currentTime`) và LUÔN gán lại cả 3
    // giá trị này dù không đổi — `didSet` thường sẽ vẫn bắn `needsLayout` mỗi lần gán, ép AppKit
    // tính lại layout CẢ CỬA SỔ liên tục dù chẳng có gì thay đổi (đo được qua `sample` lúc máy
    // Intel cũ bị lag nặng 2026-09-13). Chỉ set `needsLayout` khi giá trị THỰC SỰ đổi.
    var userScale: Double = 1 { didSet { if oldValue != userScale { needsLayout = true } } }
    var userOffset: CGPoint = .zero { didSet { if oldValue != userOffset { needsLayout = true } } }
    var bgOpacity: Double = 1 { didSet { if oldValue != bgOpacity { needsLayout = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        let s = CGFloat(max(0.05, userScale))
        let tx = CGFloat(userOffset.x) * bounds.width
        let ty = -CGFloat(userOffset.y) * bounds.height   // layer y-up: offsetY dương = xuống
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, tx, ty, 0)
        t = CATransform3DScale(t, s, s, 1)
        playerLayer.transform = t
        playerLayer.opacity = Float(max(0, min(1, bgOpacity)))
        CATransaction.commit()
    }
}
