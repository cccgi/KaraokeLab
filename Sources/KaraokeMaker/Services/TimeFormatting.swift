import Foundation

/// Định dạng thời gian dùng chung trong toàn app.
enum TimeFormatting {

    /// Dạng đồng hồ cho UI: `mm:ss.d` (ví dụ `03:12.5`).
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00.0" }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let tenths = Int((seconds - floor(seconds)) * 10)
        return String(format: "%02d:%02d.%d", minutes, secs, tenths)
    }

    /// Dạng chi tiết cho danh sách timing: `mm:ss.cc` (2 chữ số phần trăm giây).
    static func precise(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--.--" }
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remainder)
    }

    /// Đọc chuỗi người dùng gõ thành giây. Nhận `mm:ss.cc`, `ss.cc`, `h:mm:ss`,
    /// hoặc số giây thuần. Dấu phẩy được coi như dấu chấm.
    static func parse(_ string: String) -> TimeInterval? {
        let s = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":")
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        default:
            return nil
        }
    }
}
