import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    func importAudio() {
        guard let url = FilePanels.chooseAudioToImport() else { return }
        loadAudio(from: url)
    }

    /// Nạp 1 file nhạc (từ nút Chọn HOẶC kéo–thả từ Finder).
    func loadAudio(from url: URL) {
        if beatSepProxy.usingUserStems {
            store.lastError = L("Đang dùng beat + vocal bạn đưa vào. Bấm \"Bỏ\" ở phần dưới trước nếu muốn dùng file nhạc thường.")
            return
        }
        let ok = ["mp3", "wav", "m4a", "aac", "aiff", "aif", "caf", "flac"]
        guard ok.contains(url.pathExtension.lowercased()) else {
            store.lastError = L("Chỉ nhận file nhạc (MP3, WAV, M4A…).")
            return
        }
        let reference = AudioLoader.makeReference(for: url)
        store.perform(L("Import nhạc")) {
            store.project.audio = reference
            if store.project.name == "Untitled" {
                store.project.name = url.deletingPathExtension().lastPathComponent
            }
        }
        playback.load(url: url)
        beatSep.refresh(for: url)
        SpectrumStore.ensure(for: url)          // sẵn phổ cho "sóng nhạc"
        karaokeInputChanged = true              // đổi file nhạc → được tạo lại karaoke
    }

    /// Nhận file nhạc thả từ Finder vào (dùng ở bước ①).
    func handleAudioDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { loadAudio(from: url) }
        }
        return true
    }

    func syncPlaybackWithProject() {
        guard let audio = store.project.audio else { playback.unload(); beatSep.refresh(for: nil); return }
        if let url = AudioLoader.resolveURL(from: audio) {
            playback.load(url: url)
            adoptOrRefreshBeatSep(for: url)
        } else {
            playback.unload()
            beatSep.refresh(for: nil)
        }
    }

    /// Ưu tiên vocal/beat GÓI SẴN trong project (`vocalStem`/`beatStem`, xem `ProjectPackage`) —
    /// mở ở máy chưa có cache tách nhạc riêng cho bài này vẫn dùng được ngay. Không có (project
    /// cũ, hoặc chưa tách bao giờ) → quét cache máy này như cũ.
    func adoptOrRefreshBeatSep(for source: URL?) {
        let v = store.project.vocalStem.flatMap(AudioLoader.resolveURL(from:))
        let b = store.project.beatStem.flatMap(AudioLoader.resolveURL(from:))
        if beatSep.adoptFromProject(vocal: v, beat: b) { return }
        beatSep.refresh(for: source)
    }

    // MARK: - Nhập lời

    func clearLyricsBox() {
        guard !store.project.rawLyrics.isEmpty else { return }
        clearedLyricsBackup = store.project.rawLyrics
        store.perform(L("Xoá ô lời")) { store.project.rawLyrics = "" }
        lyricsImportNote = nil
    }

    func importLyrics() {
        guard let url = FilePanels.chooseLyricsToImport() else { return }

        // .ass / .ssa — đọc riêng (có thể kèm mốc từng chữ \k).
        let ext = url.pathExtension.lowercased()
        if ext == "ass" || ext == "ssa" {
            guard let raw = (try? String(contentsOf: url, encoding: .utf8))
                    ?? (try? String(contentsOf: url)) else {
                store.lastError = L("Không đọc được file \(url.lastPathComponent).")
                return
            }
            let lines = AssParser.parse(raw)
            guard !lines.isEmpty else { store.lastError = L("File ASS không có dòng hợp lệ."); return }
            let joined = lines.map(\.text).joined(separator: "\n")
            if store.project.lines.contains(where: { $0.isTimed }) {
                pendingReplace = .srt(lines: lines, joined: joined)
                showReplaceLinesAlert = true
            } else {
                applySrt(lines: lines, joined: joined, source: url.lastPathComponent)
            }
            defocusTextEditing()
            return
        }

        do {
            let outcome = try TextImport.load(from: url)
            switch outcome {
            case .plainText(let text):
                store.perform(L("Nạp lời từ file")) { store.project.rawLyrics = text }
                clearedLyricsBackup = nil
                lyricsImportNote = String(format: L("Đã nạp lời từ %@. Bấm \"Tách thành dòng\"."), url.lastPathComponent)
            case .timedLines(let lines, let joined):
                guard !lines.isEmpty else {
                    store.lastError = L("File SRT không có dòng hợp lệ.")
                    return
                }
                if store.project.lines.contains(where: { $0.isTimed }) {
                    pendingReplace = .srt(lines: lines, joined: joined)
                    showReplaceLinesAlert = true
                } else {
                    applySrt(lines: lines, joined: joined, source: url.lastPathComponent)
                }
            }
        } catch {
            store.lastError = error.localizedDescription
        }
        defocusTextEditing()
    }

    func performPendingReplace() {
        switch pendingReplace {
        case .splitFromText: applyLyricsSplit()
        case .srt(let lines, let joined): applySrt(lines: lines, joined: joined, source: "SRT")
        case .none: break
        }
        pendingReplace = nil
    }

    func applyLyricsSplit() {
        let texts = LyricsParser.split(store.project.rawLyrics)
        store.perform(L("Tách thành dòng")) {
            store.project.lines = texts.map { LyricLine(text: $0) }
        }
        lyricsImportNote = nil
        currentLineIndex = 0
        defocusTextEditing()
    }

    func applySrt(lines: [LyricLine], joined: String, source: String) {
        var ls = lines
        TimingEditor.removeOverlaps(lines: &ls)
        // SRT không có mốc chữ → chia đều. ASS có sẵn \k → GIỮ.
        for i in ls.indices where ls[i].isTimed && ls[i].words.isEmpty {
            ls[i].words = WordTiming.distribute(ls[i])
        }
        TimingEditor.makeContiguous(lines: &ls)     // block khít nhau; words = khoảng hát thật

        store.perform(L("Nhập lời từ \(source)")) {
            store.project.lines = ls
            store.project.rawLyrics = joined
        }
        currentLineIndex = 0
        clearedLyricsBackup = nil
        lyricsImportNote = String(format: L("Đã nhập %d dòng kèm timing từ %@."), ls.count, source)
    }
}
