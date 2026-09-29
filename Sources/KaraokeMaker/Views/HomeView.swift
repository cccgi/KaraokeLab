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
            HStack {
                Text("KaraokeMaker").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                Spacer()
                LanguagePicker()
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .foregroundColor(.white.opacity(0.8))
                Button {
                    if let url = FilePanels.chooseProjectToOpen() { onOpen(url) }
                } label: {
                    Label(L("Mở project khác…"), systemImage: "folder")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.8))
                Button { showTrash = true } label: {
                    Label(L("Thùng rác"), systemImage: "trash")
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.8))
            }

            Button {
                onCreate()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22))
                    Text(L("Tạo project")).font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .foregroundColor(.white)
                .padding(.vertical, 28)
                .background(
                    LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(12)
            }
            .buttonStyle(.plain)

            if !entries.isEmpty {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.white.opacity(0.5))
                    TextField(L("Tìm project theo tên…"), text: $search)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.panelAlt)
                .cornerRadius(8)
            }
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note.list").font(.system(size: 40)).foregroundColor(.white.opacity(0.25))
            Text(L("Chưa có project nào")).foregroundColor(.white.opacity(0.6)).font(.system(size: 15, weight: .medium))
            Text(L("Bấm “Tạo project” ở trên để bắt đầu.")).foregroundColor(.white.opacity(0.4)).font(.system(size: 13))
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
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Theme.panelAlt, Theme.elevated], startPoint: .top, endPoint: .bottom))
                if let thumb = entry.thumbnailURL, let ns = NSImage(contentsOf: thumb) {
                    Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "music.mic").font(.system(size: 26)).foregroundColor(.white.opacity(0.22))
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))

            HStack(spacing: 5) {
                Text(entry.name).font(.system(size: 13, weight: .medium)).foregroundColor(.white).lineLimit(1)
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
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.42))
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
                Text(L("Thùng rác")).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Button(L("Đóng"), action: onClose).foregroundColor(.white.opacity(0.8))
            }
            .padding(16)
            Divider().overlay(Theme.stroke)
            if entries.isEmpty {
                Text(L("Thùng rác trống")).foregroundColor(.white.opacity(0.5)).padding(40)
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
                            Button(L("Xoá vĩnh viễn"), role: .destructive) { pendingForever = e }
                        }
                        .listRowBackground(Theme.panel)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(width: 480, height: 380)
        .background(Theme.bg)
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
