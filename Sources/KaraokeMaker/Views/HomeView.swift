import SwiftUI

/// (U1) Màn hình mở đầu — thư viện project, kiểu CapCut: banner "Tạo project" +
/// lưới các project đã lưu. Đứng TRƯỚC màn làm việc (`ContentView`), không đổi
/// gì bên trong màn làm việc đó.
struct HomeView: View {
    /// Bấm "Tạo project" — RootView tạo dự án mới (chưa ghi file cho tới khi lưu thật).
    var onCreate: () -> Void
    /// Bấm vào 1 project trong lưới, hoặc "Mở project khác…" — trả về URL đã CHỌN.
    var onOpen: (URL) -> Void

    @State private var entries: [ProjectLibrary.Entry] = []
    @State private var search = ""
    @State private var showTrash = false
    @State private var pendingDelete: ProjectLibrary.Entry?

    private var filtered: [ProjectLibrary.Entry] {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 220), spacing: 28)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.stroke)
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 30) {
                        ForEach(filtered) { entry in
                            ProjectCard(entry: entry)
                                .onTapGesture { onOpen(entry.url) }
                                .contextMenu {
                                    Button(L("Hiện trong Finder")) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                                    if entry.isExternal {
                                        Button(L("Bỏ khỏi Gần đây")) { RecentProjects.forget(entry.url); reload() }
                                    } else {
                                        Button(L("Xoá"), role: .destructive) { pendingDelete = entry }
                                    }
                                }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 680)
        .background(Theme.bg)
        .onAppear(perform: reload)
        .sheet(isPresented: $showTrash) {
            TrashView(onRestored: reload) { showTrash = false }
        }
        .alert(L("Xoá project?"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { entry in
            Button(L("Xoá"), role: .destructive) {
                ProjectLibrary.moveToTrash(entry.url)
                pendingDelete = nil
                reload()
            }
            Button(L("Huỷ"), role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(String(format: L("“%@” sẽ chuyển vào Thùng rác — khôi phục lại được bất cứ lúc nào."), entry.name))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: Theme.Space.s) {
                Text("KaraokeMaker").font(Theme.Typo.homeTitle).foregroundColor(Theme.ink)
                Spacer()
                LanguagePicker()
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundColor(Theme.inkDim)
                Button {
                    if let url = FilePanels.chooseProjectToOpen() { onOpen(url) }
                } label: {
                    Label(L("Mở project khác…"), systemImage: "folder")
                }
                .buttonStyle(.kmSecondary)
                Button { showTrash = true } label: {
                    Label(L("Thùng rác"), systemImage: "trash")
                }
                .buttonStyle(.kmSecondary)
            }

            // Hành động chính của Home — ô nhấn ĐẶC (không gradient), cao vừa phải.
            Button {
                onCreate()
            } label: {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                    Text(L("Tạo project")).font(Theme.Typo.sheetTitle)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
            }
            .buttonStyle(.kmPrimaryLarge)

            if !entries.isEmpty {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(Theme.inkFaint)
                    TextField(L("Tìm project theo tên…"), text: $search)
                        .textFieldStyle(.plain)
                        .font(Theme.Typo.body)
                        .foregroundColor(Theme.ink)
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.ControlH.regular)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.elevated.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.stroke))
            }
        }
        .padding(Theme.Space.xxl)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 28)).foregroundColor(Theme.inkFaint)
            Text(L("Chưa có project nào")).foregroundColor(Theme.ink).font(Theme.Typo.title)
            Text(L("Bấm “Tạo project” ở trên để bắt đầu.")).foregroundColor(Theme.inkFaint).font(Theme.Typo.helper)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        entries = ProjectLibrary.listAll()
        // Project cũ chưa có thumbnail "v2" (hoặc chưa từng có) → tự vẽ lại nền, rồi nạp lại 1 lần.
        ProjectLibrary.regenerateMissingThumbnails(entries) { reload() }
    }
}

/// 1 thẻ project trong lưới Home.
private struct ProjectCard: View {
    let entry: ProjectLibrary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.panelAlt)
                // Ảnh bìa qua cache (thu nhỏ 1 lần) — trước giải mã nguyên file mỗi lần lưới vẽ lại (vd. mỗi phím gõ ô tìm).
                if let thumb = entry.thumbnailURL, let ns = MediaThumbCache.image(for: thumb, maxPixel: 480) {
                    Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                } else {
                    Image(systemName: "music.mic").font(.system(size: 24)).foregroundColor(Theme.inkFaint)
                }
                if let d = entry.duration {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(formatDuration(d))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.black.opacity(0.55))
                                .cornerRadius(4)
                                .padding(6)
                        }
                    }
                }
            }
            .aspectRatio(16.0/10.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).stroke(Theme.stroke, lineWidth: 1))

            HStack(spacing: Theme.Space.xs) {
                Text(entry.name).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
                if entry.isExternal {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                        .help(L("Nằm ngoài thư mục thư viện — mở gần đây"))
                }
            }
            HStack(spacing: 6) {
                Text(formatSize(entry.fileSize))
                if entry.duration != nil {
                    Text("·")
                    Text(formatDuration(entry.duration ?? 0))
                }
                Spacer()
                Text(relativeDate(entry.modifiedAt))
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(Theme.inkFaint)
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
    private func formatDuration(_ d: TimeInterval) -> String {
        let s = Int(d.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Sheet Thùng rác — khôi phục hoặc xoá vĩnh viễn.
private struct TrashView: View {
    var onRestored: () -> Void
    var onClose: () -> Void

    @State private var entries: [ProjectLibrary.Entry] = []
    @State private var pendingForever: ProjectLibrary.Entry?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Thùng rác")).font(Theme.Typo.sheetTitle).foregroundColor(Theme.ink)
                Spacer()
                Button(L("Đóng"), action: onClose).buttonStyle(.kmSecondarySmall).keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.xl)
            Divider().overlay(Theme.stroke)
            if entries.isEmpty {
                Text(L("Thùng rác trống")).font(Theme.Typo.label).foregroundColor(Theme.inkFaint).padding(40)
            } else {
                List {
                    ForEach(entries) { e in
                        HStack {
                            Text(e.name).foregroundColor(.white)
                            Spacer()
                            Button(L("Khôi phục")) {
                                ProjectLibrary.restore(e.url)
                                reload(); onRestored()
                            }
                            .buttonStyle(.kmSecondarySmall)
                            Button(L("Xoá vĩnh viễn"), role: .destructive) { pendingForever = e }
                        }
                        .listRowBackground(Theme.panel)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 480, height: 380)
        .background(Theme.panel)
        .onAppear(perform: reload)
        .alert(L("Xoá vĩnh viễn?"), isPresented: Binding(
            get: { pendingForever != nil }, set: { if !$0 { pendingForever = nil } }
        ), presenting: pendingForever) { e in
            Button(L("Xoá vĩnh viễn"), role: .destructive) {
                ProjectLibrary.deleteForever(e.url); pendingForever = nil; reload()
            }
            Button(L("Huỷ"), role: .cancel) { pendingForever = nil }
        } message: { e in
            Text(String(format: L("“%@” sẽ mất hẳn, không khôi phục lại được nữa."), e.name))
        }
    }

    private func reload() { entries = ProjectLibrary.listTrash() }
}
