#if KM_GUITEST
import AppKit
import SwiftUI

/// Bộ điều khiển kiểm thử GUI THẬT — CHỈ bật khi chạy app với biến môi trường `KM_GUITEST_DIR=<thư mục>` (mặc định TẮT, người dùng
/// không bao giờ gặp). App chạy BÌNH THƯỜNG (cửa sổ thật, SwiftUI thật, ContentView thật); bộ này chỉ thay "bàn tay" người dùng:
/// đọc lệnh từ `<dir>/cmd.json` mỗi 0,2 s, thực hiện bằng cách tạo sự kiện chuột/phím NSEvent gửi vào cửa sổ (hoặc `performClick`
/// lên nút hệ thống), rồi ghi kết quả ra `<dir>/resp.json`. Không cần quyền Accessibility của hệ điều hành vì chạy TRONG tiến trình app.
@MainActor
enum GUITestDriver {
    static var dir: String? { ProcessInfo.processInfo.environment["KM_GUITEST_DIR"] }
    private static var timer: Timer?
    private static var busy = false
    private static var napActivity: NSObjectProtocol?

    static func startIfRequested() {
        guard let dir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: dir + "/cmd.json")
        // App Nap gộp timer của app nền/bị che tới ~20 s → bộ kiểm thử tưởng app "đơ". Tắt App Nap khi chạy kiểm thử.
        napActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "KaraokeMaker GUI test")
        write(["event": "ready", "pid": ProcessInfo.processInfo.processIdentifier], to: dir + "/hello.json")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in Task { @MainActor in poll() } }
    }

    // MARK: - Kênh lệnh

    private static func poll() {
        guard let dir, !busy else { return }
        let cmdPath = dir + "/cmd.json"
        guard let data = FileManager.default.contents(atPath: cmdPath),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? FileManager.default.removeItem(atPath: cmdPath)
        busy = true
        var resp = execute(cmd)
        resp["id"] = cmd["id"] ?? 0
        write(resp, to: dir + "/resp.json")
        busy = false
    }

    private static func write(_ o: [String: Any], to path: String) {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? d.write(to: URL(fileURLWithPath: path + ".tmp")); try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: path + ".tmp", toPath: path)
    }

    // MARK: - Cửa sổ / view

    private static func window(_ which: String?) -> NSWindow? {
        let wins = NSApp.windows.filter { $0.isVisible }
        let main = wins.first { $0.styleMask.contains(.titled) && $0.sheetParent == nil && !($0 is NSPanel) }
        switch which ?? "key" {
        case "main": return main
        case "sheet": return main?.attachedSheet
        default: return main?.attachedSheet ?? NSApp.keyWindow ?? main
        }
    }

    private static func allViews(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }

    /// Khung theo toạ độ contentView, gốc TRÊN-TRÁI (khớp với ảnh chụp).
    private static func topLeftFrame(_ v: NSView, in win: NSWindow) -> [Double] {
        guard let cv = win.contentView else { return [] }
        let r = cv.convert(v.bounds, from: v)
        let y = cv.isFlipped ? r.minY : cv.bounds.height - r.maxY
        return [Double(r.minX).rounded(), Double(y).rounded(), Double(r.width).rounded(), Double(r.height).rounded()]
    }

    private static func visible(_ v: NSView) -> Bool {
        var x: NSView? = v
        while let c = x { if c.isHidden || c.alphaValue < 0.05 { return false }; x = c.superview }
        return true
    }

    // MARK: - Lệnh

    private static func execute(_ c: [String: Any]) -> [String: Any] {
        let op = c["op"] as? String ?? ""
        let which = c["window"] as? String
        switch op {
        case "windows":
            return ["ok": true, "windows": NSApp.windows.map { w in
                ["title": w.title, "visible": w.isVisible, "key": w.isKeyWindow, "sheet": w.sheetParent != nil, "hasSheet": w.attachedSheet != nil,
                 "frame": [Double(w.frame.minX), Double(w.frame.minY), Double(w.frame.width), Double(w.frame.height)],
                 "content": [Double(w.contentView?.bounds.width ?? 0), Double(w.contentView?.bounds.height ?? 0)], "number": w.windowNumber] as [String: Any] }]

        case "views":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let vs = allViews(cv).filter(visible)
            let buttons = vs.compactMap { $0 as? NSButton }.map { b in
                ["title": b.title.isEmpty ? b.alternateTitle : b.title, "label": b.accessibilityLabel() ?? "", "tip": b.toolTip ?? "", "enabled": b.isEnabled, "frame": topLeftFrame(b, in: w), "type": "\(type(of: b))"] as [String: Any] }
            let texts = vs.compactMap { $0 as? NSTextView }.map { t in
                ["editable": t.isEditable, "length": t.string.count, "text": String(t.string.prefix(4000)), "frame": topLeftFrame(t, in: w), "firstResponder": w.firstResponder === t] as [String: Any] }
            let scrolls = vs.compactMap { $0 as? NSScrollView }.map { sv in
                ["docHeight": Double(sv.documentView?.frame.height ?? 0), "visibleHeight": Double(sv.contentView.bounds.height), "offsetY": Double(sv.contentView.bounds.minY),
                 "frame": topLeftFrame(sv, in: w)] as [String: Any] }
            return ["ok": true, "window": w.title, "buttons": buttons, "textViews": texts, "scrollViews": scrolls]

        case "press":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let want = (c["title"] as? String ?? "").lowercased()
            let idx = c["index"] as? Int ?? 0
            let btns = allViews(cv).filter(visible).compactMap { $0 as? NSButton }
            func names(_ b: NSButton) -> String { [b.title, b.alternateTitle, b.accessibilityLabel() ?? "", b.accessibilityTitle() ?? "", b.toolTip ?? ""].joined(separator: " | ").lowercased() }
            var matches: [NSButton]
            if let at = c["at"] as? [Double], at.count == 2 {
                matches = btns.filter { let f = topLeftFrame($0, in: w); return f.count == 4 && at[0] >= f[0] && at[0] <= f[0] + f[2] && at[1] >= f[1] && at[1] <= f[1] + f[3] }
                    .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            } else { matches = btns.filter { names($0).contains(want) } }
            guard idx < matches.count else { return ["ok": false, "error": "button not found: \(want)", "window": w.title, "buttons": btns.count] }
            let b = matches[idx]
            guard b.isEnabled else { return ["ok": true, "pressed": false, "reason": "disabled", "title": names(b)] }
            b.performClick(nil)
            return ["ok": true, "pressed": true, "title": names(b)]

        case "click":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let x = c["x"] as? Double ?? Double(c["x"] as? Int ?? 0), y = c["y"] as? Double ?? Double(c["y"] as? Int ?? 0)
            let count = c["count"] as? Int ?? 1
            let p = NSPoint(x: x, y: cv.isFlipped ? y : cv.bounds.height - y)
            let wp = cv.convert(p, to: nil)
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            func ev(_ type: NSEvent.EventType, _ n: Int) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: n, clickCount: n, pressure: type == .leftMouseUp ? 0 : 1)
            }
            if let m = NSEvent.mouseEvent(with: .mouseMoved, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { NSApp.sendEvent(m) }
            pause(0.08)
            for i in 1...count {
                if let d = ev(.leftMouseDown, i) { NSApp.sendEvent(d) }
                pause(0.06)
                if let u = ev(.leftMouseUp, i) { NSApp.sendEvent(u) }
                pause(0.06)
            }
            return ["ok": true, "window": w.title]

        case "cgclick":
            // Sự kiện chuột "thật" (CGEvent) gửi RIÊNG cho tiến trình này — không động tới con trỏ thật của người dùng.
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let x = c["x"] as? Double ?? Double(c["x"] as? Int ?? 0), y = c["y"] as? Double ?? Double(c["y"] as? Int ?? 0)
            let count = c["count"] as? Int ?? 1
            let p = NSPoint(x: x, y: cv.isFlipped ? y : cv.bounds.height - y)
            let screenPt = w.convertPoint(toScreen: cv.convert(p, to: nil))                    // toạ độ Cocoa (gốc dưới-trái)
            let primaryH = NSScreen.screens.first?.frame.height ?? 0
            let cg = CGPoint(x: screenPt.x, y: primaryH - screenPt.y)                          // toạ độ Quartz (gốc trên-trái)
            NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
            let pid = ProcessInfo.processInfo.processIdentifier
            let src = CGEventSource(stateID: .privateState)
            func post(_ t: CGEventType, _ n: Int) {
                guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: cg, mouseButton: .left) else { return }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n)); e.postToPid(pid)
            }
            post(.mouseMoved, 0); pause(0.08)
            for i in 1...count { post(.leftMouseDown, i); pause(0.06); post(.leftMouseUp, i); pause(0.08) }
            return ["ok": true, "cg": [Double(cg.x), Double(cg.y)], "windowFrame": [Double(w.frame.minX), Double(w.frame.minY), Double(w.frame.width), Double(w.frame.height)]]

        case "key":
            guard let w = window(which) else { return ["ok": false, "error": "no window"] }
            let code = UInt16(c["keyCode"] as? Int ?? 53)
            let chars = c["chars"] as? String ?? (code == 53 ? "\u{1b}" : "")
            var mods: NSEvent.ModifierFlags = []
            if let m = c["mods"] as? [String] { if m.contains("cmd") { mods.insert(.command) }; if m.contains("shift") { mods.insert(.shift) }; if m.contains("opt") { mods.insert(.option) } }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
            }
            return ["ok": true]

        case "type":
            guard let w = window(which) else { return ["ok": false, "error": "no window"] }
            (w.firstResponder as? NSText)?.insertText(c["text"] as? String ?? "")
            return ["ok": true, "responder": "\(type(of: w.firstResponder as Any))"]

        case "scroll":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let x = c["x"] as? Double ?? Double(c["x"] as? Int ?? 0), y = c["y"] as? Double ?? Double(c["y"] as? Int ?? 0)
            let dy = c["dy"] as? Double ?? Double(c["dy"] as? Int ?? 0)
            let hit = allViews(cv).compactMap { $0 as? NSScrollView }.filter { sv in
                let f = topLeftFrame(sv, in: w); return f.count == 4 && x >= f[0] && x <= f[0] + f[2] && y >= f[1] && y <= f[1] + f[3] }
                .min { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
            guard let sv = hit, let doc = sv.documentView else { return ["ok": false, "error": "no scroll view at point"] }
            let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
            let cur = sv.contentView.bounds.minY
            let target = c["to"] != nil ? Double(c["to"] as? Int ?? 0) : Double(cur) + dy
            let ny = max(0, min(maxY, CGFloat(target)))
            sv.contentView.scroll(to: NSPoint(x: 0, y: ny)); sv.reflectScrolledClipView(sv.contentView)
            return ["ok": true, "offsetY": Double(ny), "maxOffsetY": Double(maxY), "docHeight": Double(doc.frame.height)]

        case "shot":
            guard let w = window(which), let cv = w.contentView, let dir else { return ["ok": false, "error": "no window"] }
            let name = c["name"] as? String ?? "shot"
            let path = "\(dir)/\(name).png"
            guard let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { return ["ok": false, "error": "no rep"] }
            cv.cacheDisplay(in: cv.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return ["ok": false, "error": "png"] }
            try? png.write(to: URL(fileURLWithPath: path))
            return ["ok": true, "path": path, "size": [Double(cv.bounds.width), Double(cv.bounds.height)], "window": w.title]

        case "resize":
            guard let w = window("main") else { return ["ok": false, "error": "no main window"] }
            let nw = c["w"] as? Double ?? Double(c["w"] as? Int ?? 1360), nh = c["h"] as? Double ?? Double(c["h"] as? Int ?? 780)
            var f = w.frame; f.size = NSSize(width: nw, height: nh); w.setFrame(f, display: true)
            return ["ok": true, "frame": [Double(w.frame.width), Double(w.frame.height)], "minSize": [Double(w.minSize.width), Double(w.minSize.height)]]

        case "state":
            var out: [String: Any] = ["ok": true]
            if let del = AppDelegate.current, let tabs = del.tabs {
                let st = tabs.active.store
                out["tabs"] = tabs.items.map { $0.store.project.name }
                out["activeTab"] = tabs.items.firstIndex { $0.id == tabs.activeID } ?? -1
                out["project"] = ["name": st.project.name, "file": st.fileURL?.path ?? "", "session": st.projectSessionID.uuidString.prefix(8).description,
                                  "hasAudio": st.project.audio != nil, "lines": st.project.lines.count, "timedLines": st.project.lines.filter { $0.isTimed }.count,
                                  "rawLyricsLength": st.project.rawLyrics.count, "rawLyricsHead": String(st.project.rawLyrics.prefix(60)),
                                  "firstLines": st.project.lines.prefix(3).map(\.text), "unsaved": st.hasUnsavedChanges,
                                  "firstLineTiming": st.project.lines.first.map { [$0.start ?? -1, $0.end ?? -1] } ?? []] as [String: Any]
            }
            out["autoLyrics"] = ["phase": AutoLyricsDebug.phase, "owner": AutoLyricsDebug.jobOwner, "draftWords": AutoLyricsDebug.draftWords, "gateBusy": AutoLyricsDebug.gateBusy, "lastAudio": AutoLyricsDebug.lastAudio, "lastVocal": AutoLyricsDebug.lastVocal]
            out["autoKaraoke"] = ["phase": AutoLyricsDebug.flowPhase, "timingCalls": AutoLyricsDebug.timingCalls, "helperLaunches": QwenHelperTranscriptionService.launchCount]
            out["helpers"] = shell("pgrep -f \"lyric_asr_helper[.]py --mix\" | wc -l").trimmingCharacters(in: .whitespacesAndNewlines)
            return out

        case "hit":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let x = c["x"] as? Double ?? Double(c["x"] as? Int ?? 0), y = c["y"] as? Double ?? Double(c["y"] as? Int ?? 0)
            let p = NSPoint(x: x, y: cv.isFlipped ? y : cv.bounds.height - y)
            var chain: [String] = []; var v = cv.hitTest(cv.convert(cv.convert(p, to: nil), from: nil))
            while let x = v, chain.count < 12 { chain.append("\(type(of: x))"); v = x.superview }
            return ["ok": true, "hit": chain, "isActive": NSApp.isActive, "isKey": w.isKeyWindow, "isMain": w.isMainWindow, "appHidden": NSApp.isHidden, "policy": NSApp.activationPolicy().rawValue]

        case "activate":
            NSApp.activate(ignoringOtherApps: true); window("main")?.makeKeyAndOrderFront(nil)
            return ["ok": true, "isActive": NSApp.isActive, "isKey": window("main")?.isKeyWindow ?? false]

        case "axenable":
            NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
            return ["ok": true]

        case "ax":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            var rows: [[String: Any]] = []
            let want = (c["contains"] as? String)?.lowercased()
            walkAX(cv, depth: 0, maxDepth: c["depth"] as? Int ?? 40) { node, depth in
                let d = axInfo(node)
                if d.role.isEmpty && d.label.isEmpty && d.value.isEmpty && d.title.isEmpty { return }
                if let want, !(d.label + d.value + d.title + d.role).lowercased().contains(want) { return }
                rows.append(["d": depth, "role": d.role, "title": d.title, "label": d.label, "value": String(d.value.prefix(300)), "enabled": d.enabled])
            }
            return ["ok": true, "count": rows.count, "nodes": Array(rows.prefix(c["limit"] as? Int ?? 400))]

        case "axpress":
            guard let w = window(which), let cv = w.contentView else { return ["ok": false, "error": "no window"] }
            let want = (c["title"] as? String ?? "").lowercased(); let role = c["role"] as? String
            var hits: [Any] = []
            walkAX(cv, depth: 0, maxDepth: 40) { node, _ in
                let d = axInfo(node)
                if (role == nil || d.role == role) && (d.label + " " + d.title).lowercased().contains(want) && !want.isEmpty { hits.append(node) }
            }
            let idx = c["index"] as? Int ?? 0
            guard idx < hits.count, let el = hits[idx] as? NSAccessibilityProtocol else { return ["ok": false, "error": "no AX element for '\(want)'", "matches": hits.count] }
            let info = axInfo(hits[idx])
            guard info.enabled else { return ["ok": true, "pressed": false, "reason": "disabled", "label": info.label] }
            let done = el.accessibilityPerformPress()
            return ["ok": true, "pressed": done, "label": info.label, "matches": hits.count]

        case "settext":
            // Gõ chữ vào ô nhập lời như người dùng (đặt firstResponder rồi chèn chữ qua NSTextView → SwiftUI nhận qua delegate).
            guard let w = window("main"), let cv = w.contentView else { return ["ok": false, "error": "no main window"] }
            let tvs = allViews(cv).filter(visible).compactMap { $0 as? NSTextView }.filter { $0.isEditable }
            guard let tv = tvs.max(by: { $0.frame.height < $1.frame.height }) else { return ["ok": false, "error": "no editable text view"] }
            w.makeFirstResponder(tv)
            tv.selectAll(nil); tv.insertText(c["text"] as? String ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
            return ["ok": true, "length": tv.string.count]

        case "focus":
            guard let w = window(which) else { return ["ok": false, "error": "no window"] }
            return ["ok": true, "firstResponder": "\(type(of: w.firstResponder as Any))", "isKey": w.isKeyWindow, "defaultButton": w.defaultButtonCell != nil]

        case "openproject":
            guard let path = c["path"] as? String else { return ["ok": false, "error": "path?"] }
            NotificationCenter.default.post(name: RootView.guiTestOpenProject, object: URL(fileURLWithPath: path))
            return ["ok": true]

        case "newtab":
            guard let tabs = AppDelegate.current?.tabs else { return ["ok": false, "error": "no tabs"] }
            tabs.openNewTab(); return ["ok": true, "tabs": tabs.items.count]

        case "switchtab":
            guard let tabs = AppDelegate.current?.tabs, let i = c["index"] as? Int, i < tabs.items.count else { return ["ok": false, "error": "no such tab"] }
            tabs.activeID = tabs.items[i].id; return ["ok": true, "active": i]

        case "failtiming":
            AutoLyricsDebug.failNextTiming = true; return ["ok": true]

        case "togglekaraoke":
            NotificationCenter.default.post(name: Notification.Name("KMGUITest.toggleKaraoke"), object: nil); return ["ok": true]

        case "toggleplay":
            // Phát / dừng ĐÚNG như nút Play (không qua phím Space — phím có thể rơi vào ô đang giữ focus bàn phím).
            NotificationCenter.default.post(name: Notification.Name("KMGUITest.togglePlay"), object: nil); return ["ok": true]

        case "ui":
            // Đổi trạng thái giao diện để chụp ảnh (tab trái: steps/background/lyrics/text/visualizer/files; export/closeexport).
            NotificationCenter.default.post(name: Notification.Name("KMGUITest.ui"), object: c["what"] as? String ?? ""); return ["ok": true]

        case "lines":
            guard let tabs = AppDelegate.current?.tabs else { return ["ok": false, "error": "no tabs"] }
            let ls = tabs.active.store.project.lines
            return ["ok": true, "count": ls.count, "rawLyrics": tabs.active.store.project.rawLyrics,
                    "lines": ls.map { l in ["text": l.text, "start": l.start ?? -1, "end": l.end ?? -1, "words": l.words.map { [$0.text, $0.start ?? -1, $0.end ?? -1] as [Any] }] as [String: Any] }]

        case "closewin":
            guard let w = window("main") else { return ["ok": false, "error": "no main window"] }
            w.performClose(nil); return ["ok": true]

        case "quit":
            // Gọi ngoài "job" của actor (như Cmd+Q thật từ menu) — nếu gọi thẳng trong Task này, câu trả lời `terminateLater` của AppDelegate
            // (cũng là 1 Task @MainActor) không bao giờ chạy được → treo giả.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0.2)
            return ["ok": true]

        case "willterminate":
            // Phát ĐÚNG thông báo mà hệ thống phát khi app sắp thoát (không thoát thật) → kiểm tra dịch vụ có dừng helper không.
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            return ["ok": true]

        case "ping": return ["ok": true, "pong": true]
        default: return ["ok": false, "error": "unknown op \(op)"]
        }
    }

    // MARK: - Accessibility TRONG tiến trình (đọc chữ trên màn hình + bấm nút SwiftUI như người dùng bấm)

    private static func axKids(_ o: Any) -> [Any] {
        if let e = o as? NSAccessibilityProtocol, let ch = e.accessibilityChildren(), !ch.isEmpty { return ch }
        if let v = o as? NSView { return v.subviews }
        return []
    }

    private static func walkAX(_ node: Any, depth: Int, maxDepth: Int, _ visit: (Any, Int) -> Void) {
        visit(node, depth)
        guard depth < maxDepth else { return }
        for k in axKids(node) { walkAX(k, depth: depth + 1, maxDepth: maxDepth, visit) }
    }

    private static func axInfo(_ node: Any) -> (role: String, title: String, label: String, value: String, enabled: Bool) {
        guard let e = node as? NSAccessibilityProtocol else { return ("", "", "", "", true) }
        func str(_ x: Any?) -> String { (x as? String) ?? (x as? NSNumber)?.stringValue ?? "" }
        return (e.accessibilityRole()?.rawValue ?? "", e.accessibilityTitle() ?? "", e.accessibilityLabel() ?? "", str(e.accessibilityValue()), e.isAccessibilityEnabled())
    }

    /// Chạy vòng lặp sự kiện một lúc để SwiftUI kịp xử lý (giống độ trễ của tay người).
    private static func pause(_ seconds: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

    private static func shell(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
#endif
