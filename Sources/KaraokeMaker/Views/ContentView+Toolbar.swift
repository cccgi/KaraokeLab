import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    @ViewBuilder
    var toolbar: some View {
        HStack(spacing: Theme.Metric.gap) {
            // ← về Thư viện (do RootView cấp)
            if let back = onExitToLibrary {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkDim)
                .help(L("Về Thư viện"))
                Divider().frame(height: 16).overlay(Theme.stroke)
            }

            // (Thao tác Tệp: Dự án mới / Mở / Lưu / Lưu thành → nằm ở menu bar "File".)

            Button { store.undoManager.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain).foregroundStyle(store.undoManager.canUndo ? Theme.inkDim : Theme.inkDim.opacity(0.35))
                .disabled(!store.undoManager.canUndo).help(L("Hoàn tác (⌘Z)"))
            Button { store.undoManager.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain).foregroundStyle(store.undoManager.canRedo ? Theme.inkDim : Theme.inkDim.opacity(0.35))
                .disabled(!store.undoManager.canRedo).help(L("Làm lại (⇧⌘Z)"))

            Divider().frame(height: 16).overlay(Theme.stroke)

            TextField(L("Tên dự án"), text: Binding(
                get: { store.project.name },
                set: { store.project.name = $0; store.markDirty() }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
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
                Circle().fill(.orange).frame(width: 5, height: 5)
            }

            Spacer()

            if let days = trialDays { TrialBanner(daysRemaining: days) }

            // Cụm nút phải — cùng kiểu XANH nổi bật như "Xuất".
            Group {
                if let newTab = onOpenNewTab {
                    Button(action: newTab) {
                        Label(L("Dự án mới"), systemImage: "plus").font(.system(size: 13, weight: .semibold))
                    }
                    .help(L("Mở project mới trong tab khác"))
                }
                Button { openProjectFromPanel() } label: {
                    Label(L("Mở"), systemImage: "folder").font(.system(size: 13, weight: .semibold))
                }
                .help(L("Mở project…"))
                Button { saveProject() } label: {
                    Label(L("Lưu"), systemImage: "square.and.arrow.down.on.square").font(.system(size: 13, weight: .semibold))
                }
                .help(L("Lưu (⌘S)"))
                Button { saveProjectAs() } label: {
                    Label(L("Lưu thành"), systemImage: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                }
                .help(L("Lưu thành…"))
                Button { showExportSheet = true } label: {
                    HStack(spacing: 6) {
                        if videoExporter.isExporting {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Text(videoExporter.isExporting ? L("Đang xuất…") : L("Xuất"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .help(L("Xuất video / SRT / ASS"))
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.regular)
        }
        .padding(.horizontal, Theme.Metric.pad)
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
}
