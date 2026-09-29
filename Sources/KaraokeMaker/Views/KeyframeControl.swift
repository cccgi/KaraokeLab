import SwiftUI

/// Cụm nút keyframe kiểu CapCut: `‹  ◇  ›` — hình thoi ở giữa.
/// - ◆ đầy + xanh: vạch đỏ đang ĐÚNG 1 mốc (bấm = xoá mốc đó).
/// - ◇ rỗng + xanh mờ: track CÓ mốc nhưng vạch đỏ không ở mốc nào (bấm = thêm mốc tại đây).
/// - ◇ rỗng + xám: chưa có mốc nào (bấm = bắt đầu keyframe: thêm mốc đầu tiên).
/// `‹ ›` = nhảy vạch đỏ tới mốc trước / sau.
struct KeyframeControl: View {
    var hasAny: Bool
    var atKeyframe: Bool
    var canPrev: Bool = false
    var canNext: Bool = false
    var onPrev: () -> Void = {}
    var onToggle: () -> Void
    var onNext: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onPrev) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(!canPrev)
                .foregroundStyle(canPrev ? Color.secondary : Color.secondary.opacity(0.35))
            Button(action: onToggle) {
                Image(systemName: atKeyframe ? "diamond.fill" : "diamond")
                    .foregroundStyle(atKeyframe ? Theme.accent
                                     : (hasAny ? Theme.accent.opacity(0.55) : Color.secondary))
            }
            .buttonStyle(.plain)
            .help(atKeyframe ? L("Xoá mốc tại vạch đỏ")
                  : (hasAny ? L("Thêm mốc tại vạch đỏ") : L("Bắt đầu keyframe (thêm mốc tại vạch đỏ)")))
            Button(action: onNext) { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(!canNext)
                .foregroundStyle(canNext ? Color.secondary : Color.secondary.opacity(0.35))
        }
        .font(.system(size: 12))
    }
}
