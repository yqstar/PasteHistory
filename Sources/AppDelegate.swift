import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let maxMenuHistoryItems = 5
    private static let maxMenuSnippetItems = 3
    private static let maxSubmenuItems = 100
    private static let menuIconSize = NSSize(width: 18, height: 18)
    private static let menuThumbnailSize = NSSize(width: 22, height: 22)
    private static let historySubmenuIdentifier = NSUserInterfaceItemIdentifier("PH.historySubmenu")
    private static let snippetSubmenuIdentifier = NSUserInterfaceItemIdentifier("PH.snippetSubmenu")

    private var statusItem: NSStatusItem!
    private let store = HistoryStore()
    private lazy var snippetStore = SnippetStore(baseDir: store.baseDir)
    private var monitor: ClipboardMonitor!
    private var windowController: HistoryWindowController!
    private var snippetPicker: SnippetPickerWindowController!
    private var snippetEditor: SnippetEditorWindowController!
    private var settingsController: SettingsWindowController!
    private var historyHotKeyID: UInt32?
    private var snippetSummonHotKeyID: UInt32?
    private var snippetHotKeyIDs: [UUID: UInt32] = [:]
    private var currentConfig = HotKeyConfig.history
    private var currentSnippetSummonConfig = HotKeyConfig.snippet
    private let menuThumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = menuSymbol("doc.on.clipboard", pointSize: 16, weight: .medium,
                                   accessibilityDescription: "粘贴历史")
            btn.image?.isTemplate = true
        }

        monitor = ClipboardMonitor(store: store)
        monitor.onCapture = { [weak self] item in
            self?.store.add(item)
        }
        monitor.start()

        windowController = HistoryWindowController(store: store, monitor: monitor)
        snippetEditor = SnippetEditorWindowController(store: snippetStore)
        snippetPicker = SnippetPickerWindowController(store: snippetStore, monitor: monitor)
        snippetPicker.onEdit = { [weak self] snip in self?.snippetEditor.showEdit(snip) }

        NotificationCenter.default.addObserver(forName: .historyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.windowController.refreshIfVisible()
        }
        NotificationCenter.default.addObserver(forName: .snippetsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.snippetPicker.refreshIfVisible()
            self?.reloadSnippetHotKeys()
        }

        settingsController = SettingsWindowController()
        settingsController.historyStore = store
        settingsController.snippetStore = snippetStore
        settingsController.onApply = { [weak self] cfg in self?.applyHotKey(cfg) ?? false }
        settingsController.onApplySnippetSummon = { [weak self] cfg in self?.applySnippetSummonHotKey(cfg) ?? false }
        settingsController.onSaveSnippet = { [weak self] in self?.snippetEditor.show() }

        applyHotKey(currentConfig)
        applySnippetSummonHotKey(currentSnippetSummonConfig)
        reloadSnippetHotKeys()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        store.flush()
        snippetStore.flush()
    }

    @discardableResult
    private func applyHotKey(_ config: HotKeyConfig) -> Bool {
        if let id = historyHotKeyID { HotKeyCenter.shared.unregister(id); historyHotKeyID = nil }
        if let id = HotKeyCenter.shared.register(keyCode: config.keyCode, modifiers: config.carbonModifiers,
                                                 callback: { [weak self] in self?.windowController.toggle() }) {
            historyHotKeyID = id
            currentConfig = config
            HotKeyConfig.history = config
            return true
        }
        historyHotKeyID = HotKeyCenter.shared.register(keyCode: currentConfig.keyCode,
                                                       modifiers: currentConfig.carbonModifiers,
                                                       callback: { [weak self] in self?.windowController.toggle() })
        return false
    }

    @discardableResult
    private func applySnippetSummonHotKey(_ config: HotKeyConfig) -> Bool {
        if let id = snippetSummonHotKeyID { HotKeyCenter.shared.unregister(id); snippetSummonHotKeyID = nil }
        if let id = HotKeyCenter.shared.register(keyCode: config.keyCode, modifiers: config.carbonModifiers,
                                                 callback: { [weak self] in self?.snippetPicker.toggle() }) {
            snippetSummonHotKeyID = id
            currentSnippetSummonConfig = config
            HotKeyConfig.snippet = config
            return true
        }
        snippetSummonHotKeyID = HotKeyCenter.shared.register(keyCode: currentSnippetSummonConfig.keyCode,
                                                             modifiers: currentSnippetSummonConfig.carbonModifiers,
                                                             callback: { [weak self] in self?.snippetPicker.toggle() })
        return false
    }

    private func reloadSnippetHotKeys() {
        for (_, id) in snippetHotKeyIDs { HotKeyCenter.shared.unregister(id) }
        snippetHotKeyIDs.removeAll()
        for snip in snippetStore.items {
            guard let hk = snip.hotKey else { continue }
            let sid = snip.id
            if let token = HotKeyCenter.shared.register(keyCode: hk.keyCode, modifiers: hk.carbonModifiers,
                                                        callback: { [weak self] in self?.emitSnippet(id: sid) }) {
                snippetHotKeyIDs[sid] = token
            }
        }
    }

    private func emitSnippet(id: UUID) {
        pasteSnippet(id: id, after: 0.03)
    }

    private func pasteSnippet(id: UUID, after delay: Double) {
        guard let snip = snippetStore.items.first(where: { $0.id == id }) else { return }
        guard monitor.writeText(snip.content) else {
            NSSound.beep()
            return
        }
        snippetStore.bump(id: id)
        AutoPaste.deliver(after: delay)
    }

    private func menuHeaderTitle(primary: String, hotkey: String, trailing: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: primary,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.labelColor]))
        s.append(NSAttributedString(string: "   \(hotkey)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(NSAttributedString(string: "       \(trailing)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.tertiaryLabelColor]))
        return s
    }

    private func makeMenuAction(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.image = menuSymbol(symbol)
        return mi
    }

    private func makeEmptyMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = menuSymbol("tray")
        item.indentationLevel = 0
        item.isEnabled = false
        return item
    }

    private func menuSymbol(_ name: String, tint: NSColor? = nil,
                            pointSize: CGFloat = 15, weight: NSFont.Weight = .regular,
                            accessibilityDescription: String? = nil) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name,
                                 accessibilityDescription: accessibilityDescription) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let tint {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        }
        guard let image = base.withSymbolConfiguration(config) else { return nil }
        image.size = Self.menuIconSize
        image.isTemplate = tint == nil
        return image
    }

    private func menuThumbnail(_ source: NSImage) -> NSImage {
        let size = Self.menuThumbnailSize
        let output = NSImage(size: size)
        output.lockFocus()
        defer { output.unlockFocus() }

        let bounds = NSRect(origin: .zero, size: size)
        let clip = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 3, yRadius: 3)
        clip.addClip()

        let sourceSize = NSSize(width: max(source.size.width, 1),
                                height: max(source.size.height, 1))
        let scale = max(size.width / sourceSize.width, size.height / sourceSize.height)
        let drawSize = NSSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let destination = NSRect(x: (size.width - drawSize.width) / 2,
                                 y: (size.height - drawSize.height) / 2,
                                 width: drawSize.width, height: drawSize.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)

        NSColor.separatorColor.setStroke()
        clip.lineWidth = 0.5
        clip.stroke()
        output.isTemplate = false
        return output
    }

    private func makeSnippetItem(_ snip: Snippet) -> NSMenuItem {
        let name = snip.title.isEmpty ? "未命名" : snip.title
        let label = snip.hotKey.map { "\(name)   \($0.display)" } ?? name
        let mi = NSMenuItem(title: label, action: #selector(pasteSnippet(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = snip.id.uuidString
        let kind = snippetKind(of: snip.content)
        mi.image = menuSymbol(kind.symbolName, tint: kind.color)
        return mi
    }

    private func makeHistoryItem(_ item: ClipItem, keyEquivalent: String) -> NSMenuItem {
        let mi = NSMenuItem(title: item.oneLine(18),
                            action: #selector(restoreItem(_:)),
                            keyEquivalent: keyEquivalent)
        mi.target = self
        mi.representedObject = item.id.uuidString
        switch item.kind {
        case .image:
            if let file = item.imageFile {
                let key = file as NSString
                if let cached = menuThumbnailCache.object(forKey: key) {
                    mi.image = cached
                } else if let source = NSImage(contentsOf: store.imageURL(file)) {
                    let thumbnail = menuThumbnail(source)
                    menuThumbnailCache.setObject(thumbnail, forKey: key)
                    mi.image = thumbnail
                }
            }
            if mi.image == nil { mi.image = menuSymbol("photo", tint: kindColor(.image)) }
        case .file:
            mi.image = menuSymbol("doc.fill", tint: kindColor(.file))
        case .text:
            mi.image = menuSymbol("text.alignleft", tint: kindColor(.text))
        }
        return mi
    }

    private func lazySubmenu(identifier: NSUserInterfaceItemIdentifier) -> NSMenu {
        let submenu = NSMenu()
        submenu.identifier = identifier
        submenu.delegate = self
        let placeholder = NSMenuItem(title: "载入中…", action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        submenu.addItem(placeholder)
        return submenu
    }

    private func updateHistorySubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let remaining = store.items.dropFirst(Self.maxMenuHistoryItems)
        for item in remaining.prefix(Self.maxSubmenuItems) {
            menu.addItem(makeHistoryItem(item, keyEquivalent: ""))
        }
        let hiddenCount = max(0, remaining.count - Self.maxSubmenuItems)
        if hiddenCount > 0 {
            menu.addItem(.separator())
            menu.addItem(makeMenuAction(title: "在历史选择器中查看其余 \(hiddenCount) 条…",
                                        symbol: "magnifyingglass",
                                        action: #selector(summonHistory)))
        }
    }

    private func updateSnippetSubmenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let remaining = snippetStore.items.dropFirst(Self.maxMenuSnippetItems)
        for snippet in remaining.prefix(Self.maxSubmenuItems) {
            menu.addItem(makeSnippetItem(snippet))
        }
        let hiddenCount = max(0, remaining.count - Self.maxSubmenuItems)
        if hiddenCount > 0 {
            menu.addItem(.separator())
            menu.addItem(makeMenuAction(title: "在片段选择器中查看其余 \(hiddenCount) 条…",
                                        symbol: "magnifyingglass",
                                        action: #selector(openSnippetPickerWindow)))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier == Self.historySubmenuIdentifier {
            updateHistorySubmenu(menu)
            return
        }
        if menu.identifier == Self.snippetSubmenuIdentifier {
            updateSnippetSubmenu(menu)
            return
        }

        menu.removeAllItems()

        let header = NSMenuItem(title: "", action: #selector(summonHistory), keyEquivalent: "")
        header.attributedTitle = menuHeaderTitle(primary: "历史选择器",
                                                 hotkey: HotKeyConfig.history.display,
                                                 trailing: "粘贴历史 · \(store.items.count) 条")
        header.image = menuSymbol("doc.on.clipboard", pointSize: 16, weight: .medium)
        header.target = self
        menu.addItem(header)
        menu.addItem(.separator())

        if store.items.isEmpty {
            menu.addItem(makeEmptyMenuItem("暂无历史记录"))
        } else {
            let recentItems = Array(store.items.prefix(Self.maxMenuHistoryItems))
            for (i, item) in recentItems.enumerated() {
                menu.addItem(makeHistoryItem(item, keyEquivalent: i < 9 ? "\(i + 1)" : ""))
            }
            let remainingCount = store.items.count - recentItems.count
            if remainingCount > 0 {
                let remaining = NSMenuItem(title: "其余历史（\(remainingCount)）",
                                           action: nil, keyEquivalent: "")
                remaining.image = menuSymbol("clock.arrow.circlepath")
                remaining.submenu = lazySubmenu(identifier: Self.historySubmenuIdentifier)
                menu.addItem(remaining)
            }
        }

        menu.addItem(.separator())

        let snippetHeader = NSMenuItem(title: "", action: #selector(openSnippetPickerWindow),
                                       keyEquivalent: "")
        snippetHeader.attributedTitle = menuHeaderTitle(primary: "片段选择器",
                                                        hotkey: HotKeyConfig.snippet.display,
                                                        trailing: "代码片段 · \(snippetStore.items.count) 条")
        snippetHeader.image = menuSymbol("chevron.left.forwardslash.chevron.right",
                                         pointSize: 16, weight: .medium)
        snippetHeader.target = self
        menu.addItem(snippetHeader)

        if snippetStore.items.isEmpty {
            menu.addItem(makeEmptyMenuItem("暂无代码片段"))
        } else {
            let recentSnippets = Array(snippetStore.items.prefix(Self.maxMenuSnippetItems))
            for snippet in recentSnippets {
                menu.addItem(makeSnippetItem(snippet))
            }

            let remainingCount = snippetStore.items.count - recentSnippets.count
            if remainingCount > 0 {
                let savedSnippets = NSMenuItem(title: "其余片段（\(remainingCount)）",
                                               action: nil, keyEquivalent: "")
                savedSnippets.image = menuSymbol("tray.full")
                savedSnippets.submenu = lazySubmenu(identifier: Self.snippetSubmenuIdentifier)
                menu.addItem(savedSnippets)
            }
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = menuSymbol("gearshape", pointSize: 15, weight: .medium)
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        quit.image = menuSymbol("power")
        menu.addItem(quit)
    }

    @objc private func restoreItem(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let item = store.items.first(where: { $0.id == id }) else { return }
        guard monitor.restore(item) else {
            NSSound.beep()
            return
        }
        store.bump(id: id)
        AutoPaste.deliver(after: 0.06)
    }

    @objc private func openSettings() { settingsController.show() }
    @objc private func summonHistory() { windowController.show() }
    @objc private func openSnippetPickerWindow() { snippetPicker.show() }

    @objc private func pasteSnippet(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        pasteSnippet(id: id, after: 0.06)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
