import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    @ViewBuilder
    var toolbar: some View {
        HStack(spacing: Theme.Space.m) {
            // ← về Thư viện (do RootView cấp)
            if let back = onExitToLibrary {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.kmIcon).help(L("Về Thư viện"))
                toolbarDivider
            }

            // (Thao tác Tệp: Dự án mới / Mở / Lưu / Lưu thành → cũng có ở menu bar "File".)
            Button { store.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.kmIcon).disabled(!store.undoManager.canUndo).help(L("Hoàn tác (⌘Z)"))
            Button { store.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.kmIcon).disabled(!store.undoManager.canRedo).help(L("Làm lại (⇧⌘Z)"))

            toolbarDivider

            TextField(L("Tên dự án"), text: Binding(
                get: { store.project.name },
                set: { store.project.name = $0; store.markDirty() }
            ))
            .textFieldStyle(.plain)
            .font(Theme.Typo.title)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: 240)
            .focused($isNameFieldFocused)
            .onSubmit { endNameEditing() }
            .onChange(of: isNameFieldFocused) { focused in
                if focused { settingSnapshot = store.project }
                else if let snapshot = settingSnapshot {
                    store.commit(from: snapshot, name: L("Đổi tên dự án")); settingSnapshot = nil
                }
            }

            if store.hasUnsavedChanges {
                Circle().fill(Theme.inkDim).frame(width: 6, height: 6)
                    .help(L("Có thay đổi chưa lưu"))
                    .accessibilityLabel(L("Có thay đổi chưa lưu"))
            }

            Spacer()

            if let days = trialDays { TrialBanner(daysRemaining: days) }

            // Nhóm tệp — vẫn để NGOÀI (chủ dự án muốn nút quan trọng luôn thấy) nhưng ở cấp PHỤ.
            HStack(spacing: Theme.Space.s) {
                if let newTab = onOpenNewTab {
                    Button(action: newTab) { Label(L("Dự án mới"), systemImage: "plus") }
                        .help(L("Mở project mới trong tab khác"))
                }
                Button { openProjectFromPanel() } label: { Label(L("Mở"), systemImage: "folder") }
                    .help(L("Mở project…"))
                Button { saveProject() } label: { Label(L("Lưu"), systemImage: "square.and.arrow.down.on.square") }
                    .help(L("Lưu (⌘S)"))
                Button { saveProjectAs() } label: { Label(L("Lưu thành"), systemImage: "square.and.arrow.down") }
                    .help(L("Lưu thành…"))
            }
            .buttonStyle(.kmSecondary)

            // Nút CHÍNH duy nhất của thanh trên.
            Button { showExportSheet = true } label: {
                HStack(spacing: Theme.Space.s) {
                    if videoExporter.isExporting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(videoExporter.isExporting ? L("Đang xuất…") : L("Xuất"))
                }
            }
            .buttonStyle(.kmPrimary)
            .help(L("Xuất video / SRT / ASS"))
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: Theme.Metric.topbarH)
        .background(Theme.panelAlt)
        // Đổi project TRONG CÙNG tab (Mở / Dự án mới) hoặc rời tab → huỷ luồng tự động, bỏ lời/mốc giờ đang dở:
        // kết quả của project A không bao giờ lọt vào project B.
        .onChange(of: store.projectSessionID) { _ in
            autoKaraoke.cancel(); createMode = nil; autoUncertain = []
        }
        .onDisappear { autoKaraoke.cancel() }
        #if KM_GUITEST
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("KMGUITest.toggleKaraoke"))) { _ in toggleKaraoke() }
        #endif
    }

    /// Vạch ngăn nhóm trên toolbar.
    var toolbarDivider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 16)
    }
}
