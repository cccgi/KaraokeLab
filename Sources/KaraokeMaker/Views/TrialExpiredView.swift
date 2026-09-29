import SwiftUI

/// Màn hình chặn khi bản DÙNG THỬ đã hết hạn (chỉ xuất hiện ở bản build `--demo`).
struct TrialExpiredView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "hourglass")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.5))
            Text("Bản dùng thử đã hết hạn")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text("Cảm ơn bạn đã thử KaraokeMaker. Liên hệ mình để có bản đầy đủ.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

/// Dải cảnh báo nhỏ, không chặn gì — hiện số ngày còn lại khi sắp hết hạn (bản `--demo`).
struct TrialBanner: View {
    let daysRemaining: Int

    var body: some View {
        if daysRemaining <= 7 {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                Text(daysRemaining > 0
                     ? "Bản dùng thử còn \(daysRemaining) ngày"
                     : "Bản dùng thử hết hạn hôm nay")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.orange)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(6)
        }
    }
}
