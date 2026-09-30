import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import Combine

extension ContentView {

    var autoLyricsVocalURL: URL? {
        let fm = FileManager.default
        if let v = store.project.vocalStem.flatMap(AudioLoader.resolveURL(from:)), fm.fileExists(atPath: v.path) { return v }
        guard projectAudioURL != nil, let v = beatSepProxy.vocalURL, fm.fileExists(atPath: v.path) else { return nil }
        return v
    }

    /// FULL MIX của CHÍNH project này (file gốc). KHÔNG dùng `playback.loadedURL`/`resolvedAudioURL`: nó có thể đang là bản BEAT
    /// (khi bật Karaoke) hoặc còn sót nhạc của project trước → sẽ nhận dạng nhầm bản nhạc không lời/bài khác.
    var autoLyricsAudioURL: URL? {
        guard let u = projectAudioURL, FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    /// Nối luồng tự động với project + các bước SẴN CÓ của app (tách giọng, canh giờ).
    func configureAutoKaraoke() {
        autoKaraoke.hooks = AutoKaraokeHooks(
            projectSession: { store.projectSessionID },
            sourceAudio: { autoLyricsAudioURL },
            vocalStem: { autoLyricsVocalURL },
            analyzeMusic: { await analyzeMusicForAutoKaraoke() },
            createKaraoke: { lyrics, shouldApply in
                guard let audio = autoLyricsAudioURL else { return .failure(L("Chưa có file nhạc.")) }
                // Cùng hàm, cùng tham số như đường "Có lời" (chất lượng nhanh mặc định của nút "Tạo nhanh Karaoke").
                return await runKaraokeTiming(audio: audio, lyrics: lyrics, quality: .fast, origin: .auto, shouldApply: shouldApply)
            },
            currentLines: { store.project.lines },
            karaokeCreated: { unc in autoUncertain = unc })
    }

    /// "Phân tích nhạc" = bước tách giọng SẴN CÓ (không thêm bộ tách mới). Chờ nếu đang có 1 lượt tách khác.
    func analyzeMusicForAutoKaraoke() async -> URL? {
        guard let src = autoLyricsAudioURL else { return nil }
        while beatSep.isRunning { try? await Task.sleep(nanoseconds: 300_000_000) }
        return await beatSep.separateLocal(source: src)?.vocal
    }

    func startAutoKaraoke() {
        configureAutoKaraoke()
        autoKaraoke.start()
    }

    /// Chuyển sang đường "Có lời" KHÔNG cần nhập lại nhạc; lời máy đã nhận dạng (nếu có) được điền sẵn vào ô lời khi ô đang trống.
    func switchToManualLyrics(prefill: String?) {
        autoKaraoke.cancel()
        if let p = prefill, alignLyricsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { alignLyricsInput = p }
        createMode = .hasLyrics
    }

    /// Từ chưa chắc còn hiệu lực: dòng còn tồn tại và từ ở vị trí đó vẫn là từ máy đã ghi (user chưa sửa).
    var validAutoUncertain: [AutoUncertainWord] {
        autoUncertain.filter { u in
            guard let line = store.project.lines.first(where: { $0.id == u.lineID }) else { return false }
            let t = UncertaintyMapper.tokens(line.text)
            return t.indices.contains(u.wordIndex) && UncertaintyMapper.norm(t[u.wordIndex]) == UncertaintyMapper.norm(u.original)
        }
    }

    /// Chọn phương án cho 1 từ chưa chắc: thay đúng từ đó (GIỮ mốc giờ của từ bị thay, 1 bước hoàn tác) rồi bỏ khỏi danh sách.
    func applyUncertainAlternative(_ u: AutoUncertainWord, _ alt: String) {
        guard let i = store.project.lines.firstIndex(where: { $0.id == u.lineID }),
              let newText = UncertaintyMapper.replacingWord(in: store.project.lines[i].text, at: u.wordIndex, with: alt) else { return }
        commitLyricEdit(u.lineID, newText)
        autoUncertain.removeAll { $0.id == u.id }
    }

    /// "Vừa khung" — đặt zoom sao cho TOÀN BỘ timeline lọt viewport (khớp ĐÚNG công thức
    /// `TimelineEditor.duration` để không thừa/thiếu) rồi kéo về đầu.
    func timelineFitToWindow() {
        let k = max(0, store.project.karaokeClipStart)
        let overlayEnd = (store.project.overlays.map(\.end).max() ?? 0) + 10
        let lineEnd = (store.project.lines.compactMap(\.end).max() ?? 0) + k + 10
        let dur = max(playback.duration + k, overlayEnd, lineEnd, 60)
        let vw = max(timelineViewportW, 200)
        // CHO PHÉP zoom xuống rất thấp — bài dài 4' vẫn phải LỌT TRỌN khung (min 8 cũ = luôn thiếu ~20s).
        timelineZoom = min(400, max(1.5, (vw - 6) / dur))
        timelineFitTick &+= 1          // canh cho canvas kéo scroll về x=0
    }

    func openProjectFromPanel() {
        if let url = FilePanels.chooseProjectToOpen() {
            store.open(from: url); syncPlaybackWithProject()
        }
    }
    func saveProject() {
        if store.save() == false,
           let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
            store.save(to: url)
        }
    }
    func saveProjectAs() {
        if let url = FilePanels.chooseProjectSaveLocation(defaultName: store.project.name) {
            store.save(to: url)
        }
    }

    // MARK: - Panel trái: Lời

    enum LeftPanelTab: Hashable { case steps, background, lyrics, text, visualizer, files }

    /// Nút tab cột trái — kiểu "rail" CapCut: icon trên, nhãn dưới, ô chọn có nền + gạch nhấn.
    /// `done` (chỉ "Tạo Karaoke") → chấm xanh lá báo bước đã xong.
    @ViewBuilder
    func leftTabButton(_ title: String, icon: String, tab: LeftPanelTab, done: Bool) -> some View {
        let selected = leftPanelTab == tab
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { leftPanelTab = tab }
        } label: {
            VStack(spacing: Theme.Space.xs) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon).font(.system(size: 15))
                    if done {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.success)
                            .background(Circle().fill(Theme.panel))
                            .offset(x: 7, y: -4)
                    }
                }
                Text(L(title)).font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.s)
            .foregroundStyle(selected ? Theme.accent : Theme.inkDim)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(selected ? Theme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(title))
        .accessibilityLabel(L(title) + (done ? " ✓" : ""))
    }

    @ViewBuilder
    var leftPanel: some View {
        VStack(spacing: 0) {
            // (U6) Kho media giờ là 1 KHU RIÊNG, chiếm hết chiều cao khi mở — không còn
            // nhét vừa trong 1 thẻ nhỏ của bước 3 (đúng góp ý: cần giống hẳn 1 "kho" thật,
            // không phải 1 mục cài đặt).
            HStack(spacing: 4) {
                // "Tạo Karaoke" chỉ còn khi CHƯA có dòng canh xong (hoặc đang đứng ở đó lúc vừa xong, tới
                // khi tự chuyển sang "Nền video") — xong bước này là hết quay lại; mở lại project cũng vậy.
                if showStepsTab {
                    leftTabButton("Tạo Karaoke", icon: "sparkles", tab: .steps, done: aiLinesTimed)
                }
                leftTabButton("Nền video", icon: "photo", tab: .background, done: false)
                if aiLinesTimed {
                    leftTabButton("Sửa lời", icon: "text.alignleft", tab: .lyrics, done: false)
                }
                leftTabButton("Thêm text", icon: "textformat", tab: .text, done: false)
                leftTabButton("Sóng nhạc", icon: "waveform", tab: .visualizer, done: false)
                leftTabButton("Media", icon: "folder", tab: .files, done: false)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)

            Divider().overlay(Theme.stroke)

            switch leftPanelTab {
            case .files:
                filesPanel
            case .steps:
                ScrollViewReader { proxy in
                    ScrollView {
                        aiStepsPanel
                            .padding(Theme.Metric.pad)
                    }
                    .onChange(of: aiAudioOK) { ok in
                        // Nhập audio xong → tự cuộn lên phần dán lời (thấy nút Tạo Karaoke).
                        guard ok else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo("lyricsStep", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: alignPhase) { phase in
                        switch phase {
                        case .separating, .aligning:
                            // Vừa bấm tạo karaoke → cuộn xuống cho thấy tiến trình đang chạy.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo("aiProgress", anchor: .center)
                                }
                            }
                        case .done:
                            // Xong → tự nhảy sang tab "Chỉnh sửa" + "Vừa khung" cho thấy trọn bài.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                // Karaoke tự động có từ máy chưa chắc → mở thẳng "Sửa lời" để xem/sửa; ngược lại như cũ.
                                withAnimation { leftPanelTab = validAutoUncertain.isEmpty ? .background : .lyrics }
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                timelineFitToWindow()
                            }
                        case .idle:
                            break
                        }
                    }
                }
            case .lyrics:
                LyricEditPanel(currentLineIndex: currentLineIndex,
                               onFocusLine: focusLyricLine,
                               onCommit: commitLyricEdit,
                               uncertain: validAutoUncertain,
                               onApplyAlternative: applyUncertainAlternative,
                               onDismissUncertain: { u in autoUncertain.removeAll { $0.id == u.id } })
            case .background:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                        subCard("Nền video") { backgroundSourceContent }
                    }
                    .padding(Theme.Metric.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                        subCard("Thêm text") { textLayerPanel }
                    }
                    .padding(Theme.Metric.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .visualizer:
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                        subCard("Sóng nhạc") { visualizerPanel }
                    }
                    .padding(Theme.Metric.pad).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .onChange(of: aiLinesTimed) { timed in
            if timed {
                // Có dòng canh xong mà đang đứng ở "Tạo Karaoke" NGOÀI luồng tạo karaoke (luồng đó tự
                // chuyển sau 0.3s để kịp thấy dấu "xong"): nhập SRT/ASS, làm lại ⇧⌘Z… → rời sang "Nền video".
                if leftPanelTab == .steps, alignPhase == .idle { leftPanelTab = .background }
            } else if leftPanelTab == .lyrics {
                leftPanelTab = .steps                       // ⌘Z lùi về trước lúc tạo → tab "Sửa lời" biến mất
            }
        }
        .onChange(of: store.fileURL) { _ in
            if leftPanelTab == .steps, aiLinesTimed { leftPanelTab = .background }   // mở project khác ngay trong editor
        }
        .alert(L("Thay toàn bộ dòng lời?"), isPresented: $showReplaceLinesAlert) {
            Button(L("Huỷ"), role: .cancel) { pendingReplace = nil }
            Button(L("Thay & xoá timing"), role: .destructive) { performPendingReplace() }
        } message: {
            Text(L("Một số dòng đã có timing. Thao tác này tạo danh sách dòng mới và xoá timing hiện có."))
        }
    }

    /// Tab "Chỉnh sửa" — nền video + sóng nhạc. (Kho file tách sang tab "File của bạn".)
    @ViewBuilder
    var mediaLibraryPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.pad) {
                subCard("Nền video") { backgroundSourceContent }
                subCard("Chữ / Text") { textLayerPanel }
                subCard("Sóng nhạc") { visualizerPanel }
            }
            .padding(Theme.Metric.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ô "Chữ / Text" ở panel trái — thêm lớp chữ (như lớp ảnh).
    var textLayerPanel: some View {
        let textClips = store.project.overlays.filter { $0.kind == .text }
        return VStack(alignment: .leading, spacing: 7) {
            Button { addTextOverlay() } label: {
                Label(L("Thêm 1 lớp chữ"), systemImage: "textformat")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.kmPrimary)
            .onDrag { NSItemProvider(object: Self.newTextDragToken as NSString) }

            Text(L("Bấm để thêm ở vạch đỏ, hoặc KÉO nút này thả xuống làn lớp đè trên timeline. Lớp chữ hoạt động như lớp ảnh: kéo–giãn–xoay trên màn hình xem trước, chỉnh bên phải."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !textClips.isEmpty {
                Divider()
                ForEach(textClips) { clip in
                    Button { selectedOverlayID = clip.id } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "textformat").font(.caption2).foregroundStyle(Theme.accent)
                            Text(clip.text.isEmpty ? L("(trống)") : clip.text)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if selectedOverlayID == clip.id {
                                Image(systemName: "checkmark").font(.caption2).foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Tab "Media" — kho ảnh / video / nhạc, kéo xuống timeline. Chỉ 1 ô "+ Nhập file" —
    /// bấm hay thả file vào bất kỳ đâu trong ô đều nhập được (đúng kiểu user tham khảo).
    @ViewBuilder
    var filesPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.gap) {
                mediaImportBox
                if !store.project.mediaPool.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 12)], spacing: 14) {
                        ForEach(store.project.mediaPool) { item in
                            mediaPoolThumb(item, size: 96)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(Theme.Metric.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Ô "+ Nhập file" — khi kho TRỐNG thì chiếm cả khu (giống ảnh tham khảo), khi đã có
    /// file thì co lại thành 1 thanh gọn phía trên lưới. Bấm HOẶC thả file (ảnh/video/nhạc)
    /// vào bất kỳ đâu trong ô đều nhập được.
    var mediaImportBox: some View {
        let empty = store.project.mediaPool.isEmpty
        return Button { importMediaPoolImages() } label: {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                    Text(L("Nhập file")).font(.system(size: 15, weight: .bold))
                }
                Text(L("Kéo và thả video, ảnh, nhạc vào đây"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, empty ? 90 : 26)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Theme.Metric.radius)
            .fill(mediaPoolDropTargeted ? Theme.accent.opacity(0.10) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metric.radius)
            .strokeBorder(mediaPoolDropTargeted ? Theme.accent : Theme.stroke,
                          style: StrokeStyle(lineWidth: 1.5, dash: mediaPoolDropTargeted ? [] : [5, 4])))
        .onDrop(of: ["public.file-url"], isTargeted: $mediaPoolDropTargeted) { handleMediaPoolFileDrop($0) }
    }

    var linesList: some View {
        LyricLinesList(
            currentLineIndex: currentLineIndex,
            onSelect: { currentLineIndex = $0 },
            onSeekToLineStart: seekToLineStart,
            onClearLine: clearLine,
            onClearAll: clearAllTiming,
            canUndoClearAll: clearedTimingBackup != nil,
            onUndoClearAll: restoreClearedTiming,
            onSetText: setLineText,
            onSetStart: { setLineStartTime($0, $1) },
            onSetEnd: { setLineEndTime($0, $1) },
            onNudgeStart: { nudgeStart($0, $1) },
            onNudgeEnd: { nudgeEnd($0, $1) },
            onStartToPlayhead: { setStartToPlayhead($0) },
            onEndToPlayhead: { setEndToPlayhead($0) }
        )
    }

    // MARK: - Cột trái: các bước

    var aiAudioOK: Bool { playback.isLoaded }
    var aiLyricsOK: Bool { !store.project.rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var aiLinesOK: Bool { !store.project.lines.isEmpty }
    var aiLinesTimed: Bool { store.project.lines.contains { $0.isTimed } }
    /// Chỉ cần bước "Tách dòng" khi gõ lời tay (chưa có dòng có sẵn mốc từ SRT).
    var aiNeedsSplit: Bool { !aiLinesTimed }

    enum StemSlot { case beat, vocal }
    enum AudioInputMode: String, CaseIterable, Identifiable {
        case whole = "Cả bài nhạc", stems = "Beat + Vocal riêng"
        var id: String { rawValue }
    }

    @ViewBuilder
    var stepAudioContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if aiAudioOK {
                HStack(spacing: 8) {
                    Image(systemName: beatSepProxy.usingUserStems ? "waveform.path.badge.plus" : "music.note")
                        .foregroundStyle(.secondary)
                    Text(beatSepProxy.usingUserStems
                         ? L("Beat + Vocal của bạn")
                         : (playback.loadedURL?.lastPathComponent ?? store.project.audio?.fileName ?? "—"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L("Đổi")) { resetAudioInput() }.controlSize(.small)
                }
            } else if store.project.audio != nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(L("Không tìm thấy file nhạc")).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(L("Chọn lại…")) { importAudio() }.controlSize(.small)
                }
            } else {
                Text(L("Bạn có bài nhạc, hay có sẵn Beat + Vocal riêng?"))
                    .font(.caption2).foregroundStyle(.secondary)
                Picker("", selection: $audioInputMode) {
                    ForEach(AudioInputMode.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch audioInputMode {
                case .whole: wholeAudioInput
                case .stems: stemsInput
                }
            }
        }
    }

    @ViewBuilder
    var wholeAudioInput: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down").font(.title2).foregroundStyle(.secondary)
            Button(L("Chọn file nhạc (MP3 / WAV)…")) { importAudio() }
                .buttonStyle(.kmPrimary)
            Text(L("…hoặc kéo file nhạc từ Finder thả vào đây."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(audioDropTargeted ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(audioDropTargeted ? Theme.accent : Theme.strokeStrong))
        .onDrop(of: ["public.file-url"], isTargeted: $audioDropTargeted) { handleAudioDrop($0) }
    }

    @ViewBuilder
    var stemsInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            stemDropRow("Beat (không lời)", icon: "music.note.list", url: $userBeatURL,
                        targeted: $beatDropTargeted, slot: .beat)
            stemDropRow("Vocal (chỉ giọng)", icon: "music.mic", url: $userVocalURL,
                        targeted: $vocalDropTargeted, slot: .vocal)
            if userBeatURL != nil, userVocalURL != nil {
                Button(beatSepProxy.isRunning ? L("Đang xử lý…") : L("Dùng 2 file này")) { adoptStems() }
                    .buttonStyle(.kmPrimary)
                    .frame(maxWidth: .infinity)
                    .disabled(beatSepProxy.isRunning)
            }
        }
    }

    /// Xoá nguồn nhạc hiện tại → quay lại màn hình chọn "Cả bài / Beat + Vocal".
    func resetAudioInput() {
        audioInputMode = beatSepProxy.usingUserStems ? .stems : .whole
        beatSep.clearUserStems()
        userBeatURL = nil; userVocalURL = nil
        playback.unload()
        if store.project.audio != nil {
            store.perform(L("Bỏ nhạc")) { store.project.audio = nil }
        }
        karaokeOn = false
    }

    @ViewBuilder
    func stemDropRow(_ title: String, icon: String, url: Binding<URL?>,
                             targeted: Binding<Bool>, slot: StemSlot) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: icon).font(Theme.Typo.iconSmall).foregroundStyle(Theme.inkDim).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(Theme.Typo.labelStrong)
                Text(url.wrappedValue?.lastPathComponent ?? L("kéo file vào, hoặc bấm Chọn"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if url.wrappedValue != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            }
            Button(L("Chọn…")) {
                if let u = FilePanels.chooseAudioToImport() { url.wrappedValue = u }
            }.controlSize(.small).disabled(beatSepProxy.usingUserStems)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(targeted.wrappedValue ? Theme.accent.opacity(0.12) : Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(targeted.wrappedValue ? Theme.accent : Theme.stroke))
        .onDrop(of: ["public.file-url"], isTargeted: targeted) { handleStemDrop($0, into: slot) }
    }

    func handleStemDrop(_ providers: [NSItemProvider], into slot: StemSlot) -> Bool {
        guard !beatSepProxy.usingUserStems,
              let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") })
        else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                switch slot {
                case .beat:  userBeatURL = url
                case .vocal: userVocalURL = url
                }
            }
        }
        return true
    }

    func adoptStems() {
        guard let b = userBeatURL, let v = userVocalURL else { return }
        Task {
            guard let mix = await beatSep.adoptUserStems(beat: b, vocal: v) else { return }
            let ref = AudioLoader.makeReference(for: mix)
            store.perform(L("Dùng beat + vocal")) {
                store.project.audio = ref
                if store.project.name == "Untitled" {
                    store.project.name = v.deletingPathExtension().lastPathComponent
                }
            }
            playback.load(url: mix)
        }
    }

    // MARK: Cột trái — các bước tạo karaoke

    var aiStepsPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(L("Tạo Karaoke bằng AI")).sectionHeaderStyle()

            stepBlock(1, "Nhập file audio", done: aiAudioOK) { stepAudioContent }

            // ② Dán lời → tách nhạc + canh giờ → timeline.
            // ② Chọn cách tạo Karaoke: CÓ LỜI (dán/nhập lời → canh giờ) hoặc KHÔNG CẦN LỜI (máy tự nhận dạng + tự canh giờ).
            if aiAudioOK {
                Divider().overlay(Theme.stroke)
                stepBlock(2, createMode == nil ? "Chọn cách tạo Karaoke" : (createMode == .hasLyrics ? "Dán lời & tạo karaoke" : "Tự động tạo Karaoke"),
                          done: aiLinesOK) {
                    createModeContent
                }
                .id("lyricsStep")
            }
            // Bước 3 "chọn nền" đã bỏ — nền / sóng nhạc / ảnh đè giờ ở tab "Kho media".
        }
    }

    /// Tiến trình 2 chặng của bước "Dán lời & tạo karaoke".
    enum AlignPhase { case idle, separating, aligning, done }

    /// Mục sổ xuống theo đúng kiểu các nhóm trong panel "Kiểu chữ"
    /// (bấm vào cả hàng tiêu đề để mở/đóng, không chỉ mũi tên).
    @ViewBuilder
    func collapsibleSection<C: View>(
        _ title: String, expanded: Binding<Bool>, @ViewBuilder _ content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkFaint).frame(width: 10)
                    Text(title).font(Theme.Typo.labelStrong).foregroundStyle(Theme.ink)
                    Spacer()
                }
                .frame(height: Theme.ControlH.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue { content() }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    /// Nội dung bước ②: 2 lựa chọn RÕ RÀNG rồi mới tới đường đã chọn (không gộp chung 1 trang nhập lời).
    @ViewBuilder
    var createModeContent: some View {
        if createMode == nil {
            createModeChooser
        } else {
            Button { createMode = nil; autoKaraoke.reset() } label: { Label(L("Đổi cách tạo"), systemImage: "chevron.left") }
                .controlSize(.small).disabled(autoKaraoke.isRunning)
            if createMode == .hasLyrics {
                forcedAlignStep
            } else {
                AutoKaraokePanel(flow: autoKaraoke,
                                 analysisProgress: beatSepProxy.throttledProgress,
                                 timingProgress: advancedProxy.throttledListenProgress,
                                 onStart: { startAutoKaraoke() },
                                 onRetryTiming: { autoKaraoke.retryTiming() },
                                 onCancel: { autoKaraoke.cancel() },
                                 onManual: { switchToManualLyrics(prefill: $0) })
            }
        }
    }

    var createModeChooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Bạn muốn tạo Karaoke theo cách nào?")).font(.caption2).foregroundStyle(.secondary)
            // Nút 1 dòng (nút hệ thống) + mô tả ngay dưới — không nhồi 2 dòng vào nút (bị cắt chữ).
            Button { createMode = .hasLyrics } label: { choiceTitle(icon: "text.alignleft", L("Tôi có lời bài hát")) }
                .buttonStyle(.bordered).controlSize(.large)
            Text(L("Dán hoặc nhập lời — máy tự canh giờ.")).font(.caption2).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            Button { createMode = .noLyrics; startAutoKaraoke() } label: { choiceTitle(icon: "wand.and.stars", L("Không cần lời — Tự động tạo Karaoke")) }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
            Text(L("Máy tự nghe, viết lời rồi canh giờ.")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    func choiceTitle(icon: String, _ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    var forcedAlignStep: some View {
        Text(L("Dán lời theo thứ tự hát, mỗi câu 1 dòng. Cách các đoạn (phiên khúc, điệp khúc, đoạn cầu…) bằng MỘT dòng trống. Đoạn nào hát lại chỉ cần viết MỘT lần — máy tự tìm và nhân bản cho đủ."))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        TextEditor(text: $alignLyricsInput)
            .font(.body).frame(minHeight: 190, maxHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.strokeStrong))

        HStack(spacing: 8) {
            Button(L("Dán")) {
                if let s = NSPasteboard.general.string(forType: .string) { alignLyricsInput = s }
            }.controlSize(.small)
            if !alignLyricsInput.isEmpty {
                Button(L("Xoá")) { alignLyricsInput = "" }.controlSize(.small).buttonStyle(.link)
            }
            Spacer()
        }

        let noLyrics = alignLyricsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            Button {
                runForcedAlign(quality: .fast)
            } label: {
                Label(advancedProxy.isBusy ? L("Đang xử lý…") : L("Tạo nhanh Karaoke"), systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(advancedProxy.isBusy || noLyrics)

            Button {
                runForcedAlign(quality: .hq)
            } label: {
                Label(L("Tạo Karaoke Chất Lượng"), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(advancedProxy.isBusy || noLyrics)
        }
        Text(L("“Chất lượng” tách nhạc sạch hơn nhưng lâu hơn nhiều."))
            .font(.caption2).foregroundStyle(.secondary)

        if advancedProxy.phase != .idle {
            VStack(alignment: .leading, spacing: 10) {
                // Chặng 1 — PHÂN TÍCH NHẠC (tách beat/vocal). Xong → tick xanh, rồi mới sang chặng 2.
                phaseRow("phân tích nhạc",
                         running: advancedProxy.phase == .separating,
                         progress: beatSepProxy.throttledProgress)

                // Chặng 2 — TẠO KARAOKE (canh giờ). Chỉ hiện khi đã qua chặng 1.
                if advancedProxy.phase.rank >= 2 || advancedProxy.phase == .done {
                    phaseRow("tạo karaoke",
                             running: advancedProxy.phase.rank >= 2 && advancedProxy.phase.rank < 6,
                             progress: advancedProxy.throttledListenProgress)
                }

                if advancedProxy.phase == .done {
                    if !advancedProxy.resultNote.isEmpty {
                        Text(advancedProxy.resultNote).font(.caption).foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("Đang mở phần “Chỉnh sửa”…"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if case .failed(let m) = advancedProxy.phase {
                    Text(m).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .id("aiProgress")
        }

        HStack(spacing: 6) {
            Text(L("Hoặc")).font(.caption).foregroundStyle(.secondary)
            Button(L("Nhập SRT / ASS…")) { importLyrics() }.controlSize(.small)
        }
    }

    /// Đường "CÓ LỜI": lời người dùng dán → `runKaraokeTiming` (hàm CHUNG với đường "Không cần lời").
    func runForcedAlign(quality: BeatSeparation.Quality) {
        guard let audio = resolvedAudioURL else { store.lastError = L("Chưa có file nhạc."); return }
        let lyrics = alignLyricsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyrics.isEmpty else { return }
        let session = store.projectSessionID
        Task {
            _ = await runKaraokeTiming(audio: audio, lyrics: lyrics, quality: quality, origin: .manual,
                                       shouldApply: { session == store.projectSessionID })
        }
    }

    enum KaraokeOrigin { case manual, auto }

    /// ĐIỂM CHUNG của HAI ĐƯỜNG tạo Karaoke. Đường "Có lời" gọi với lời dán tay; đường "Không cần lời" gọi với lời máy nhận dạng.
    /// Từ đây trở xuống là MỘT bộ canh giờ duy nhất: `AdvancedKaraoke.run` (tách giọng → đi tìm từng đoạn lời → dựng dòng → làm sạch).
    /// `shouldApply` = false (huỷ / đã đổi project) → KHÔNG áp kết quả vào project.
    @MainActor
    func runKaraokeTiming(audio: URL, lyrics rawLyrics: String, quality: BeatSeparation.Quality, origin: KaraokeOrigin,
                                  shouldApply: @escaping @MainActor () -> Bool) async -> KaraokeTimingOutcome {
        let lyrics = rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lyrics.isEmpty else { return .failure(L("Chưa có lời.")) }
        AutoLyricsDebug.recordTiming(origin: origin == .manual ? "manual" : "auto", lyrics: lyrics)
        #if KM_GUITEST
        if origin == .auto, AutoLyricsDebug.failNextTiming {                    // chỉ bản dựng kiểm thử: giả lập lỗi canh giờ
            AutoLyricsDebug.failNextTiming = false
            return .failure("Canh giờ không ra kết quả (giả lập để kiểm thử)")
        }
        #endif
        alignPhase = .separating   // kích hoạt cuộn xuống bước ③ khi xong
        let outcome = await advanced.run(
            audio: audio, pastedLyrics: lyrics, lang: .vi, quality: quality,
            beatSep: beatSep, aligner: aligner
        )
        guard let outcome, !outcome.lines.isEmpty else {
            alignPhase = .idle
            var msg = L("Canh xong nhưng không ra dòng nào — kiểm tra lại lời / nhạc.")
            if case .failed(let m) = advancedProxy.phase { msg = m }
            if origin == .manual { store.lastError = msg }
            return .failure(msg)
        }
        guard shouldApply() else { alignPhase = .idle; return .discarded }
        store.perform(L("Tạo Karaoke")) {
            var ls = outcome.lines
            for i in ls.indices { applyLeadWait(&ls, i, 0.3) }
            store.project.lines = ls
            store.project.rawLyrics = outcome.fullLyrics ?? lyrics
        }
        currentLineIndex = 0
        alignPhase = .done
        aiLinesListExpanded = true
        return .success(lines: outcome.lines.count)
    }

    func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 1 chặng trong bước tạo karaoke: đang chạy = spinner + thanh %, xong = tick xanh.
    @ViewBuilder
    func phaseRow(_ title: String, running: Bool, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if running {
                    ProgressView().controlSize(.small)
                    Text(String(format: L("Đang %@…"), L(title).lowercased())).font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(String(format: L("Đã %@ xong"), L(title).lowercased())).font(.caption).foregroundStyle(.green)
                }
            }
            if running {
                ProgressView(value: max(0, min(1, progress)))
            }
        }
    }

    @ViewBuilder
    func stepBlock<C: View>(_ n: Int, _ title: String, done: Bool, @ViewBuilder _ content: () -> C) -> some View {
        // Mỗi bước 1 THẺ riêng — tách bạch, đỡ cảm giác "1 khối chữ dài" (giống CapCut chia panel rõ ràng).
        // DESIGN_SYSTEM §9: bước = tiêu đề đánh số + nội dung, PHẲNG (không thẻ); các bước ngăn nhau bằng đường kẻ.
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                ZStack {
                    Circle().fill(done ? Theme.success : Theme.accent).frame(width: 20, height: 20)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(n)").font(Theme.Typo.badge).foregroundStyle(.white)
                    }
                }
                Text(L(title)).font(Theme.Typo.title).foregroundStyle(Theme.ink)
                Spacer()
            }
            content().padding(.leading, 28)
        }
        .padding(.vertical, Theme.Space.s)
    }

    /// "Nhập lại" ở bước ② (thủ công) — xoá lời + dòng.
    func resetLyricsEntry() {
        store.perform(L("Nhập lại lời")) {
            store.project.rawLyrics = ""
            store.project.lines = []
        }
        aiLinesListExpanded = false
        currentLineIndex = 0
        clearedLyricsBackup = nil
        lyricsImportNote = nil
    }
}
