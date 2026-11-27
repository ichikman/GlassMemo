import Cocoa
import Carbon

final class MemoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSWindowDelegate {
    var panel: MemoPanel!
    var editor: NSTextView!
    var status: NSStatusItem!
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var editing = false
    var previousApp: NSRunningApplication?
    let defaults = UserDefaults.standard
    var backgroundOpacity: Double { defaults.object(forKey: "backgroundOpacity") as? Double ?? defaults.object(forKey: "opacity") as? Double ?? 0.38 }
    var textOpacity: Double { defaults.object(forKey: "textOpacity") as? Double ?? 0.9 }
    var opacityLabels: [Int: NSTextField] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        panel = MemoPanel(contentRect: NSRect(x: visible.maxX - 380, y: visible.maxY - 340, width: 340, height: 280), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Glass Memo · ⌥Mで編集"
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.82, alpha: 1)
        panel.isOpaque = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 230, height: 150)
        panel.setFrameAutosaveName("MemoPosition")
        panel.delegate = self

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        editor.insertionPointColor = .black
        editor.font = .systemFont(ofSize: 16)
        editor.textContainerInset = NSSize(width: 14, height: 14)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = defaults.string(forKey: "memo") ?? "ここにメモを書けます。\n\n⌥M：編集を開始／終了\nEsc：編集を終了\n\n普段はクリックが背後のアプリに届きます。"
        editor.delegate = self
        scroll.documentView = editor
        let content = panel.contentView!
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        setEditing(false)
        panel.orderFrontRegardless()
        if CommandLine.arguments.contains("--smoke-test") {
            setEditing(true)
            precondition(editing && !panel.ignoresMouseEvents && editor.isEditable)
            setEditing(false)
            precondition(!editing && panel.ignoresMouseEvents && !editor.isEditable)
            precondition(panel.level == .floating)
            let testFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let testText = "日本語のメモ\n2行目 📝"
            do {
                let date = Date()
                let url = try writeMemo(testText, to: testFolder, date: date)
                let firstRead = try String(contentsOf: url, encoding: .utf8)
                precondition(firstRead == testText)
                let secondURL = try writeMemo("更新済み", to: testFolder, date: date)
                let secondRead = try String(contentsOf: secondURL, encoding: .utf8)
                let originalRead = try String(contentsOf: url, encoding: .utf8)
                precondition(secondRead == "更新済み" && originalRead == testText)
                precondition(url != secondURL && secondURL.lastPathComponent.hasSuffix("_メモ_2.txt"))
                try FileManager.default.removeItem(at: testFolder)
            } catch { fatalError("TXT save test failed: \(error)") }
            print("PASS: timestamped UTF-8 TXT, same-second collision, original preserved;")
            print("PASS: edit / passive transitions, click-through, floating level")
            NSApp.terminate(nil)
            return
        }
        installHotKey()
    }

    func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem(title: "ファイル", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "ファイル")
        let saveItem = fileMenu.addItem(withTitle: "TXTを保存", action: #selector(saveText), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command]
        saveItem.target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem(title: "編集", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "編集")
        for (title, action, key) in [("元に戻す", "undo:", "z"), ("切り取り", "cut:", "x"), ("コピー", "copy:", "c"), ("貼り付け", "paste:", "v"), ("すべて選択", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Glass Memo")
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "編集を切り替え（⌥M）", action: #selector(toggleEditing), keyEquivalent: "")
        toggle.target = self
        let save = menu.addItem(withTitle: "TXTを保存（⌘S）", action: #selector(saveText), keyEquivalent: "")
        save.target = self
        menu.addItem(.separator())
        let controls = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 128))
        for (tag, title, value, y) in [(0, "背景の濃さ", backgroundOpacity, 75.0), (1, "文字の濃さ", textOpacity, 17.0)] {
            let label = NSTextField(labelWithString: "\(title)  \(Int((value * 100).rounded()))%")
            label.frame = NSRect(x: 18, y: y + 24, width: 235, height: 20)
            label.font = .systemFont(ofSize: 12)
            controls.addSubview(label)
            opacityLabels[tag] = label
            let slider = NSSlider(value: value * 100, minValue: tag == 0 ? 0 : 10, maxValue: 100, target: self, action: #selector(changeOpacity(_:)))
            slider.tag = tag
            slider.isContinuous = true
            slider.frame = NSRect(x: 18, y: y, width: 234, height: 22)
            slider.setAccessibilityLabel(title)
            controls.addSubview(slider)
        }
        let controlsItem = NSMenuItem()
        controlsItem.view = controls
        menu.addItem(controlsItem)
        menu.addItem(.separator())
        let reset = menu.addItem(withTitle: "メモを画面中央に戻す", action: #selector(recenter), keyEquivalent: "")
        reset.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Glass Memoを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu
    }

    func installHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.toggleEditing()
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(optionKey), EventHotKeyID(signature: 0x474D454D, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr || registered != noErr {
            let alert = NSAlert()
            alert.messageText = "ショートカットを登録できませんでした"
            alert.informativeText = "ほかのアプリとの競合が考えられます。メニューバーのメモアイコンから編集できます。"
            alert.runModal()
        }
    }

    func writeMemo(_ text: String, to directory: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = formatter.string(from: date) + "_メモ"
        var number = 1
        while true {
            let suffix = number == 1 ? "" : "_\(number)"
            let url = directory.appendingPathComponent(base + suffix + ".txt")
            do {
                try Data(text.utf8).write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                number += 1
            }
        }
    }

    @objc func saveText() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let savedURL = try writeMemo(editor.string, to: documents.appendingPathComponent("GlassMemo", isDirectory: true))
            defaults.set(editor.string, forKey: "memo")
            panel.title = "保存しました · \(savedURL.lastPathComponent)"
        } catch {
            let alert = NSAlert()
            alert.messageText = "TXTを保存できませんでした"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: panel)
        }
    }

    @objc func toggleEditing() { setEditing(!editing) }
    func setEditing(_ value: Bool) {
        if value && !editing { previousApp = NSWorkspace.shared.frontmostApplication }
        editing = value
        panel.ignoresMouseEvents = !value
        applyAppearance()
        panel.hasShadow = value
        editor.isEditable = value
        editor.isSelectable = value
        panel.title = value ? "編集中 · ⌘SでTXT保存 · Escで終了" : "Glass Memo · ⌥Mで編集"
        if value {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(editor)
        } else {
            defaults.set(editor.string, forKey: "memo")
            panel.resignKey()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                previousApp?.activate(options: [])
            }
            previousApp = nil
        }
    }
    func textDidChange(_ notification: Notification) { defaults.set(editor.string, forKey: "memo") }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { setEditing(false); return true }
        return false
    }
    func windowDidResignKey(_ notification: Notification) { if editing { setEditing(false) } }
    func applyAppearance() {
        panel.alphaValue = 1
        panel.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.82, alpha: backgroundOpacity)
        editor.textColor = NSColor(calibratedWhite: 0.12, alpha: textOpacity)
        editor.insertionPointColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        panel.contentView?.needsDisplay = true
    }
    @objc func changeOpacity(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        defaults.set(value / 100, forKey: sender.tag == 0 ? "backgroundOpacity" : "textOpacity")
        let title = sender.tag == 0 ? "背景の濃さ" : "文字の濃さ"
        opacityLabels[sender.tag]?.stringValue = "\(title)  \(Int(value))%"
        applyAppearance()
    }
    @objc func recenter() { panel.center(); panel.orderFrontRegardless() }
    func applicationWillTerminate(_ notification: Notification) {
        defaults.set(editor.string, forKey: "memo")
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
