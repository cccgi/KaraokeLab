import SwiftUI

/// Nội dung đường "Không cần lời": 4 chặng THẬT (phân tích nhạc → nhận dạng lời → kiểm tra lời → tự canh giờ), mỗi chặng có trạng thái riêng,
/// KHÔNG phải 1 vòng quay chung. Lỗi → nói rõ chặng nào hỏng + "Thử lại" / "Nhập lời thủ công" (không phải nhập lại nhạc).
struct AutoKaraokePanel: View {
    @ObservedObject var flow: AutoKaraokeFlow
    /// 0…1 của bước phân tích nhạc sẵn có / bước canh giờ sẵn có (thật, do 2 bước đó báo).
    let analysisProgress: Double
    let timingProgress: Double
    var onStart: () -> Void
    var onRetryTiming: () -> Void
    var onCancel: () -> Void
    /// Chuyển sang đường "Có lời" mà KHÔNG nhập lại nhạc; `prefill` = lời máy đã nhận dạng (nếu có).
    var onManual: (_ prefill: String?) -> Void

    @State private var showDraft = false

    private enum Row: Int, CaseIterable { case analyze, recognize, check, time }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(L("Không cần nhập lời: máy nghe bài hát, viết ra lời, rồi tự canh giờ thành karaoke."))
                .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint).fixedSize(horizontal: false, vertical: true)
            switch flow.phase {
            case .idle:
                Button { onStart() } label: { Label(L("Bắt đầu tạo Karaoke"), systemImage: "wand.and.stars") }
                    .buttonStyle(.kmPrimaryLarge)
            case .analyzing, .recognizing, .timing, .done:
                progressRows
                if flow.isRunning {
                    Button(L("Huỷ"), action: onCancel).buttonStyle(.kmSecondarySmall)
                }
            case .failedAnalysis(let m):
                failure(title: L("Chưa phân tích được bài hát"), message: m, timing: false)
            case .failedRecognition(let m):
                failure(title: L("Chưa nhận dạng được lời"), message: m, timing: false)
            case .failedTiming(let m):
                failure(title: L("Không thể tự canh thời gian"), message: m, timing: true)
            }
        }
    }

    // MARK: - Các chặng

    private func state(of row: Row) -> (done: Bool, current: Bool) {
        let cur: Int?
        var allDone = false
        switch flow.phase {
        case .analyzing: cur = Row.analyze.rawValue
        case .recognizing(let p):
            switch p {
            case .preparing, .loadingModel, .recognizing: cur = Row.recognize.rawValue
            default: cur = Row.check.rawValue
            }
        case .timing: cur = Row.time.rawValue
        case .done: cur = nil; allDone = true
        default: cur = nil
        }
        if allDone { return (true, false) }
        guard let c = cur else { return (false, false) }
        return (row.rawValue < c, row.rawValue == c)
    }

    private func title(for row: Row) -> String {
        switch row {
        case .analyze: return L("Đang phân tích bài hát…")
        case .recognize:
            if case .recognizing(let p) = flow.phase, case .recognizing = p { return p.label }
            return L("Đang nhận dạng lời…")
        case .check:
            if case .recognizing(let p) = flow.phase {
                switch p { case .verifying, .rechecking, .checking: return p.label; default: break }
            }
            return L("Đang kiểm tra lời…")
        case .time: return L("Đang tự động canh thời gian…")
        }
    }

    private func doneTitle(for row: Row) -> String {
        switch row {
        case .analyze: return L("Đã phân tích bài hát")
        case .recognize: return L("Đã nhận dạng lời")
        case .check: return L("Đã kiểm tra lời")
        case .time: return L("Đã canh thời gian Karaoke")
        }
    }

    @ViewBuilder private var progressRows: some View {
        // Danh sách chặng gọn: icon trạng thái · tên chặng · thời gian đã chạy · thanh tiến độ thật (DESIGN_SYSTEM §15).
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ForEach(Row.allCases, id: \.rawValue) { row in
                let st = state(of: row)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.m) {
                        Group {
                            if st.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success) }
                            else if st.current { ProgressView().controlSize(.small) }
                            else { Image(systemName: "circle").foregroundStyle(Theme.inkDisabled) }
                        }
                        .frame(width: 16)
                        Text(st.done ? doneTitle(for: row) : (st.current ? title(for: row) : pendingTitle(row)))
                            .font(Theme.Typo.label).foregroundStyle(st.done ? Theme.inkDim : (st.current ? Theme.ink : Theme.inkFaint))
                        Spacer(minLength: 0)
                        if st.current { ElapsedLabel() }
                    }
                    if st.current, let f = fraction(for: row) { ProgressView(value: max(0, min(1, f))).controlSize(.small) }
                }
            }
            if case .done(let lines, let unc) = flow.phase {
                Text(String(format: L("Hoàn tất — %d dòng đã có mốc giờ."), lines) + (unc > 0 ? " " + String(format: L("%d từ máy chưa chắc, xem ở tab “Sửa lời”."), unc) : ""))
                    .font(Theme.Typo.label).foregroundColor(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pendingTitle(_ row: Row) -> String {
        switch row {
        case .analyze: return L("Phân tích bài hát")
        case .recognize: return L("Nhận dạng lời")
        case .check: return L("Kiểm tra lời")
        case .time: return L("Tự động canh thời gian")
        }
    }

    private func fraction(for row: Row) -> Double? {
        switch row {
        case .analyze: return analysisProgress
        case .recognize, .check:
            if case .recognizing(let p) = flow.phase { return p.fraction }
            return nil
        case .time: return timingProgress
        }
    }

    // MARK: - Lỗi

    @ViewBuilder private func failure(title: String, message: String, timing: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(Theme.Typo.labelStrong).foregroundColor(Theme.warning)
            Text(message).font(Theme.Typo.helper).foregroundStyle(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            if timing {
                Text(L("Lời đã nhận dạng được giữ lại — không cần nhận dạng lại."))
                    .font(Theme.Typo.helper).foregroundStyle(Theme.inkFaint)
                HStack(spacing: Theme.Space.s) {
                    Button(L("Thử lại canh giờ"), action: onRetryTiming).buttonStyle(.kmPrimary)
                    Button(showDraft ? L("Ẩn lời đã nhận dạng") : L("Xem lời đã nhận dạng")) { showDraft.toggle() }.buttonStyle(.kmSecondarySmall)
                }
                Button(L("Chuyển sang nhập lời thủ công")) { onManual(flow.draftText) }.buttonStyle(.kmSecondarySmall)
                if showDraft, let t = flow.draftText {
                    ScrollView { Text(t).font(Theme.Typo.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Theme.Space.s) }
                        .frame(maxHeight: 140)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.elevated.opacity(0.6)))
                }
            } else {
                HStack(spacing: Theme.Space.s) {
                    Button(L("Thử lại"), action: onStart).buttonStyle(.kmPrimary)
                    Button(L("Nhập lời thủ công")) { onManual(nil) }.buttonStyle(.kmSecondarySmall)
                }
            }
        }
    }
}
