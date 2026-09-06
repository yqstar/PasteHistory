import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private lazy var updateController = UpdateWindowController()
    private var historyHotKeyID: UInt32?
    private var snippetSummonHotKeyID: UInt32?
    private let snippetHotKeys = SnippetHotKeyRegistry()
    private var reportedDataIssues = Set<String>()
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
        monitor.start()

        windowController = HistoryWindowController(store: store, monitor: monitor)
        snippetEditor = SnippetEditorWindowController(store: snippetStore)
        windowController.onSaveAsSnippet = { [weak self] content in
            self?.snippetEditor.showNew(content: content)
        }
        snippetPicker = SnippetPickerWindowController(store: snippetStore, monitor: monitor)
        snippetPicker.onCreate = { [weak self] in self?.snippetEditor.showNew() }
        snippetPicker.onEdit = { [weak self] snip in self?.snippetEditor.showEdit(snip) }
        snippetPicker.onError = { [weak self] message in self?.presentDataIssue(message) }

        store.onPersistenceError = { [weak self] message in self?.presentDataIssue(message) }
        snippetStore.onPersistenceError = { [weak self] message in self?.presentDataIssue(message) }

        NotificationCenter.default.addObserver(forName: .historyDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.windowController.refreshIfVisible()
        }
        NotificationCenter.default.addObserver(forName: .snippetsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadSnippetHotKeys()
        }

        settingsController = SettingsWindowController()
        settingsController.historyStore = store
        settingsController.snippetStore = snippetStore
        settingsController.onShowVersions = { [weak self] in self?.updateController.show() }
        settingsController.onCheckUpdates = { [weak self] in self?.updateController.show(checkForUpdates: true) }
        settingsController.onApply = { [weak self] cfg in
            guard let self else { return false }
            let applied = self.applyHotKey(cfg)
            self.reloadSnippetHotKeys()
            return applied
        }
        settingsController.onApplySnippetSummon = { [weak self] cfg in
            guard let self else { return false }
            let applied = self.applySnippetSummonHotKey(cfg)
            self.reloadSnippetHotKeys()
            return applied
        }
        applyHotKey(currentConfig)
        applySnippetSummonHotKey(currentSnippetSummonConfig)
        reloadSnippetHotKeys()

        let startupIssues = [store.startupWarning, snippetStore.startupWarning].compactMap { $0 }
        if !startupIssues.isEmpty { presentDataIssue(startupIssues.joined(separator: "\n\n")) }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor = snippetEditor, editor.hasUnsavedChanges else { return .terminateNow }
        DispatchQueue.main.async {
            editor.confirmDiscardingChanges { allowed in
                sender.reply(toApplicationShouldTerminate: allowed)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        store.flush()
        snippetStore.flush()
    }

    @discardableResult
    private func applyHotKey(_ config: HotKeyConfig) -> Bool {
        let result = HotKeyCenter.shared.replace(historyHotKeyID, current: currentConfig, with: config) {
            [weak self] in self?.windowController.toggle()
        }
        historyHotKeyID = result.id
        if result.applied {
            currentConfig = config
            HotKeyConfig.history = config
        }
        return result.applied
    }

    @discardableResult
    private func applySnippetSummonHotKey(_ config: HotKeyConfig) -> Bool {
        let result = HotKeyCenter.shared.replace(snippetSummonHotKeyID, current: currentSnippetSummonConfig,
                                                 with: config) { [weak self] in self?.snippetPicker.toggle() }
        snippetSummonHotKeyID = result.id
        if result.applied {
            currentSnippetSummonConfig = config
            HotKeyConfig.snippet = config
        }
        return result.applied
    }

    private func reloadSnippetHotKeys() {
        snippetHotKeys.update(snippetStore.items) { [weak self] id in
            self?.pasteSnippet(id: id, after: 0.03)
        }
        snippetPicker?.updateHotKeyRegistration(activeIDs: snippetHotKeys.activeIDs)
    }

    private func presentDataIssue(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedDataIssues.insert(message).inserted else { return }
            let alert = NSAlert()
            alert.messageText = "数据处理提示"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
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

    private func menuHeaderTitle(primary: String, hotkey: String, count: Int) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: primary,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.labelColor]))
        s.append(NSAttributedString(string: "  \(count)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(NSAttributedString(string: "      \(hotkey)",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
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
        return NSImage(size: size, flipped: false) { bounds in
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
            return true
        }
    }

    private func makeSnippetItem(_ snip: Snippet) -> NSMenuItem {
        let name = snip.title.isEmpty ? "未命名" : snip.title
        let label: String
        if let hotKey = snip.hotKey {
            let status = snippetHotKeys.activeIDs.contains(snip.id) ? hotKey.display : "\(hotKey.display)（冲突）"
            label = "\(name)   \(status)"
        } else {
            label = name
        }
        let mi = NSMenuItem(title: label, action: #selector(pasteSnippet(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = snip.id
        if snip.hotKey != nil, !snippetHotKeys.activeIDs.contains(snip.id) {
            mi.toolTip = "快捷键注册失败，请修改与其他快捷键冲突的组合"
        }
        let kind = snippetKind(of: snip.content)
        mi.image = menuSymbol(kind.symbolName, tint: kind.color)
        return mi
    }

    private func makeHistoryItem(_ item: ClipItem, keyEquivalent: String) -> NSMenuItem {
        let mi = NSMenuItem(title: item.oneLine(18),
                            action: #selector(restoreItem(_:)),
                            keyEquivalent: keyEquivalent)
        mi.target = self
        mi.representedObject = item.id
        switch item.kind {
        case .image:
            if let file = item.imageFile {
                let key = file as NSString
                if let cached = menuThumbnailCache.object(forKey: key) {
                    mi.image = cached
                } else if let source = loadImageThumbnail(at: store.imageURL(file), maxSize: Self.menuThumbnailSize.width) {
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
                                                 count: store.items.count)
        header.image = menuSymbol("clock.arrow.circlepath", pointSize: 16, weight: .medium)
        header.target = self
        menu.addItem(header)
        menu.addItem(.separator())

        if store.items.isEmpty {
            menu.addItem(makeEmptyMenuItem("暂无历史记录"))
        } else {
            let recentItems = Array(store.items.prefix(Self.maxMenuHistoryItems))
            for (i, item) in recentItems.enumerated() {
                menu.addItem(makeHistoryItem(item, keyEquivalent: "\(i + 1)"))
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
                                                        count: snippetStore.items.count)
        snippetHeader.image = menuSymbol("square.stack",
                                         pointSize: 16, weight: .medium)
        snippetHeader.target = self
        menu.addItem(snippetHeader)
        menu.addItem(.separator())

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
        guard let id = sender.representedObject as? UUID,
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
        guard let id = sender.representedObject as? UUID else { return }
        pasteSnippet(id: id, after: 0.06)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
