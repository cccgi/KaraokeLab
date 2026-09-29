import SwiftUI

/// Ô nhập thời gian: gõ `mm:ss.cc` (hoặc số giây) rồi Enter / rời ô để áp dụng.
struct TimeField: View {
    let seconds: TimeInterval?
    let onCommit: (TimeInterval) -> Void

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("mm:ss.cc", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .frame(width: 96)
            .focused($focused)
            .onAppear { syncFromModel() }
            .onChange(of: seconds) { _ in if !focused { syncFromModel() } }
            .onChange(of: focused) { isFocused in if !isFocused { commit() } }
            .onSubmit { commit() }
    }

    private func syncFromModel() {
        text = seconds.map(TimeFormatting.precise) ?? ""
    }

    private func commit() {
        if let value = TimeFormatting.parse(text) {
            onCommit(max(0, value))
        } else {
            syncFromModel()
        }
    }
}
