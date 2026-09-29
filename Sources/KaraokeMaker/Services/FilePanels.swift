import AppKit
import UniformTypeIdentifiers

/// Bọc các hộp thoại chọn / lưu file của macOS cho gọn.
enum FilePanels {

    /// Kiểu file project. Nếu hệ thống chưa biết đuôi `.kbproj` thì tạo type động.
    private static var projectType: UTType {
        UTType(filenameExtension: ProjectStore.fileExtension) ?? .json
    }

    /// Hộp thoại "Mở…". Trả về URL người dùng chọn, hoặc nil nếu bấm Cancel.
    /// `.kbproj` là 1 file ZIP THẬT (mang theo media, xem `ProjectPackage`) — chỉ chọn FILE.
    static func chooseProjectToOpen() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Mở dự án karaoke")
        panel.allowedContentTypes = [projectType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại "Lưu thành…". `defaultName` là tên gợi ý (chưa gồm đuôi).
    static func chooseProjectSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L("Lưu dự án karaoke")
        panel.allowedContentTypes = [projectType]
        panel.nameFieldStringValue = "\(defaultName).\(ProjectStore.fileExtension)"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại lưu video QuickTime .mov.
    static func chooseMOVSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L("Xuất video chữ karaoke")
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(defaultName).mov"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại lưu video xuất: `.mp4` khi nền đục, `.mov` khi nền trong suốt.
    /// Dùng `begin` (KHÔNG chặn luồng) để tránh treo trong app SwiftUI.
    static func chooseVideoSaveLocation(defaultName: String, opaque: Bool,
                                        preferMOV: Bool = false,
                                        completion: @escaping (URL?) -> Void) {
        let useMOV = !opaque || preferMOV
        let panel = NSSavePanel()
        panel.title = L("Xuất video karaoke")
        panel.allowedContentTypes = useMOV ? [.quickTimeMovie] : [.mpeg4Movie]
        panel.nameFieldStringValue = "\(defaultName).\(useMOV ? "mov" : "mp4")"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.url : nil) }
        } else {
            panel.begin { completion($0 == .OK ? panel.url : nil) }
        }
    }

    /// Hộp thoại lưu file phụ đề .srt.
    static func chooseSRTSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L("Xuất phụ đề SRT")
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = "\(defaultName).srt"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại lưu file phụ đề karaoke .ass.
    static func chooseASSSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L("Xuất phụ đề karaoke ASS")
        panel.allowedContentTypes = [UTType(filenameExtension: "ass") ?? .plainText]
        panel.nameFieldStringValue = "\(defaultName).ass"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại lưu file audio (dùng để tải về bản vocal đã tách kiểm tra).
    static func chooseAudioSaveLocation(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L("Lưu vocal đã tách")
        panel.allowedContentTypes = [.wav, .mp3]
        panel.nameFieldStringValue = "\(defaultName).wav"
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại chọn file lời bài hát. Nhận nhiều định dạng: txt, rtf/rtfd
    /// (TextEdit), doc/docx (Word), odt, html, và srt (phụ đề, có timing).
    static func chooseLyricsToImport() -> URL? {
        var types: [UTType] = [.plainText, .utf8PlainText, .text, .rtf, .html]
        let optional: [String] = [
            "com.apple.rtfd",                              // .rtfd
            "com.microsoft.word.doc",                      // .doc
            "org.openxmlformats.wordprocessingml.document",// .docx
            "org.oasis-open.opendocument.text",            // .odt
        ]
        for identifier in optional {
            if let type = UTType(identifier) { types.append(type) }
        }
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let ass = UTType(filenameExtension: "ass") { types.append(ass) }
        if let ssa = UTType(filenameExtension: "ssa") { types.append(ssa) }

        let panel = NSOpenPanel()
        panel.title = L("Chọn file lời bài hát")
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại chọn ảnh nền (Mode C).
    static func chooseBackgroundImage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Chọn ảnh nền")
        panel.allowedContentTypes = [.image, .png, .jpeg, .tiff, .heic, .gif, .bmp]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Chọn file LUT `.cube` (C10).
    static func chooseLUT() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L("Chọn LUT (.cube)")
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// (U6) Hộp thoại chọn NHIỀU file cùng lúc (ảnh / nhạc / video) — nhập vào "kho media".
    static func chooseImagesToImport() -> [URL] {
        var types: [UTType] = [.image, .png, .jpeg, .tiff, .heic, .gif, .bmp,
                               .mp3, .wav, .aiff, .mpeg4Audio, .audio,
                               .movie, .quickTimeMovie, .mpeg4Movie, .video]
        if let flac = UTType("org.xiph.flac") { types.append(flac) }
        let panel = NSOpenPanel()
        panel.title = L("Nhập file vào kho media")
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Hộp thoại chọn video nền (Mode C).
    static func chooseBackgroundVideo() -> URL? {
        var types: [UTType] = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        if let mkv = UTType("org.matroska.mkv") { types.append(mkv) }
        let panel = NSOpenPanel()
        panel.title = L("Chọn video nền")
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Hộp thoại chọn file nhạc để import.
    static func chooseAudioToImport() -> URL? {
        var types: [UTType] = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]
        if let flac = UTType("org.xiph.flac") { types.insert(flac, at: 3) }

        let panel = NSOpenPanel()
        panel.title = L("Chọn file nhạc")
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
