import Cocoa
import UniformTypeIdentifiers

// MARK: - History palette controller

final class HistoryWindowController {
    let store: HistoryStore
    let monitor: ClipboardMonitor
    var onSaveAsSnippet: ((String) -> Void)?

    private let palette = PaletteController()
    private var filtered: [ClipItem] = []
    private let thumbCache = NSCache<NSString, NSImage>()

    init(store: HistoryStore, monitor: ClipboardMonitor) {
        thumbCache.countLimit = 500
        self.store = store
        self.monitor = monitor
        palette.title = "粘贴历史"
        palette.symbolName = "clock.arrow.circlepath"
        palette.placeholder = "搜索粘贴历史…"
        palette.emptyText = "还没有粘贴历史"
        palette.footerHints = [("↩", "粘贴"), ("⌘⌫", "删除"), ("esc", "关闭"), ("⌘S", "保存片段")]
        palette.footerSeparatorIndex = 3
        palette.provider = { [weak self] q in self?.rows(for: q) ?? [] }
        palette.onActivate = { [weak self] i in self?.activate(i) ?? false }
        palette.onDelete = { [weak self] i in self?.deleteAt(i) }
        palette.onSaveRow = { [weak self] i in self?.saveAsSnippetAt(i) }
    }

    func show() { palette.show() }
    func toggle() { palette.toggle() }
    func refreshIfVisible() { palette.reloadIfVisible() }

    private func rows(for query: String) -> [PaletteRow] {
        if query.isEmpty {
            filtered = store.items
        } else {
            filtered = store.items.filter {
                matchesQuery($0.text ?? "", query) || matchesQuery(kindLabel($0.kind), query)
            }
        }
        return filtered.map { item in
            PaletteRow(id: item.id,
                       icon: icon(for: item),
                       iconIsTemplate: item.kind != .image,
                       iconTint: kindColor(item.kind),
                       title: item.oneLine(120),
                       subtitle: relativeTime(item.date),
                       badge: kindLabel(item.kind),
                       badgeColor: kindColor(item.kind),
                       canSaveAsSnippet: item.kind == .text && !(item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func icon(for item: ClipItem) -> NSImage? {
        if item.kind == .image, let f = item.imageFile {
            let key = f as NSString
            if let cached = thumbCache.object(forKey: key) { return cached }
            guard let thumb = loadImageThumbnail(at: store.imageURL(f), maxSize: 48) else { return nil }
            thumbCache.setObject(thumb, forKey: key)
            return thumb
        }
        let sym = item.kind == .file ? "doc" : "text.alignleft"
        return NSImage(systemSymbolName: sym, accessibilityDescription: nil)
    }

    private func activate(_ i: Int) -> Bool {
        guard i >= 0, i < filtered.count else { return false }
        let item = filtered[i]
        guard monitor.restore(item) else { return false }
        store.bump(id: item.id)
        return true
    }

    private func deleteAt(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        store.delete(id: filtered[i].id)
    }

    private func saveAsSnippetAt(_ i: Int) {
        guard i >= 0, i < filtered.count,
              filtered[i].kind == .text,
              let content = filtered[i].text,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let onSaveAsSnippet else {
            NSSound.beep()
            return
        }
        palette.hide(reactivatePreviousApplication: false)
        onSaveAsSnippet(content)
    }
}

// MARK: - Snippet picker controller

final class SnippetPickerWindowController {
    let store: SnippetStore
    let monitor: ClipboardMonitor
    var onEdit: ((Snippet) -> Void)?
    var onCreate: (() -> Void)?
    var onError: ((String) -> Void)?

    private let palette = PaletteController()
    private var filtered: [Snippet] = []
    private var activeHotKeyIDs = Set<UUID>()

    init(store: SnippetStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        palette.title = "代码片段"
        palette.symbolName = "square.stack"
        palette.placeholder = "搜索代码片段…"
        palette.emptyText = "把常用内容存为片段"
        palette.emptyDetail = "代码、链接或文本，保存一次，随时粘贴。"
        palette.createActionTitle = "新建片段"
        palette.footerHints = [("↩", "粘贴"), ("⌘⌫", "删除"), ("esc", "关闭"), ("⌘N", "新建"), ("⌘E", "编辑")]
        palette.footerSeparatorIndex = 3
        palette.onCreate = { [weak self] in self?.create() }
        palette.provider = { [weak self] q in self?.rows(for: q) ?? [] }
        palette.onActivate = { [weak self] i in self?.activate(i) ?? false }
        palette.onDelete = { [weak self] i in self?.deleteAt(i) }
        palette.onEditRow = { [weak self] i in self?.editAt(i) }
    }

    func show() { palette.show() }
    func hide() { palette.hide() }
    func toggle() { palette.toggle() }
    func updateHotKeyRegistration(activeIDs: Set<UUID>) {
        activeHotKeyIDs = activeIDs
        palette.reloadIfVisible()
    }

    private func editAt(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        palette.hide(reactivatePreviousApplication: false)
        onEdit?(filtered[i])
    }

    private func create() {
        palette.hide(reactivatePreviousApplication: false)
        onCreate?()
    }

    private func rows(for query: String) -> [PaletteRow] {
        if query.isEmpty {
            filtered = store.items
        } else {
            filtered = store.items.filter {
                matchesQuery($0.title, query) || matchesQuery($0.content, query)
            }
        }
        return filtered.map { s in
            let kind = snippetKind(of: s.content)
            let hotKeyActive = s.hotKey == nil || activeHotKeyIDs.contains(s.id)
            return PaletteRow(id: s.id,
                              icon: NSImage(systemSymbolName: kind.symbolName,
                                            accessibilityDescription: nil),
                              iconIsTemplate: true,
                              iconTint: kind.color,
                              title: s.title.isEmpty ? "未命名" : s.title,
                              subtitle: subtitle(for: s.content),
                              badge: kind.label,
                              badgeColor: kind.color,
                              accessoryBadge: s.hotKey.map {
                                  hotKeyActive ? $0.display : "\($0.display) 冲突"
                              },
                              accessoryBadgeColor: hotKeyActive ? nil : .systemRed)
        }
    }

    private func subtitle(for content: String) -> String {
        let stripped = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "（空）" }
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let charCount = content.count
        var parts: [String] = []
        if lineCount > 1 { parts.append("\(lineCount) 行") }
        parts.append("\(charCount) 字符")
        parts.append(oneLinePreview(stripped, limit: 80))
        return parts.joined(separator: " · ")
    }

    private func activate(_ i: Int) -> Bool {
        guard i >= 0, i < filtered.count else { return false }
        let snippet = filtered[i]
        guard monitor.writeText(snippet.content) else { return false }
        store.bump(id: snippet.id)
        return true
    }

    private func deleteAt(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        do {
            try store.delete(id: filtered[i].id)
        } catch {
            onError?(error.localizedDescription)
        }
    }
}

// MARK: - Snippet editor

final class SnippetEditorWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let store: SnippetStore

    private var window: NSWindow!
    private var titleField: NSTextField!
    private var contentView: NSTextView!
    private var contentStats: NSTextField!
    private var editing: Snippet?
    private var isEditingSessionOpen = false

    init(store: SnippetStore) {
        self.store = store
    }

    var hasUnsavedChanges: Bool {
        guard isEditingSessionOpen else { return false }
        return titleField.stringValue != (editing?.title ?? "") ||
            contentView.string != (editing?.content ?? "")
    }

    func showNew(content: String = "") {
        confirmDiscardingChanges { [weak self] allowed in
            guard let self, allowed else { return }
            self.editing = nil
            self.showWindow(title: content.isEmpty ? "新建片段" : "保存片段", name: "", content: content)
        }
    }

    func showEdit(_ snippet: Snippet) {
        if isEditingSessionOpen, editing?.id == snippet.id {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        confirmDiscardingChanges { [weak self] allowed in
            guard let self, allowed else { return }
            self.editing = snippet
            self.showWindow(title: "编辑片段", name: snippet.title, content: snippet.content)
        }
    }

    private func showWindow(title: String, name: String, content: String) {
        if window == nil { build() }
        window.title = title
        titleField.stringValue = name
        contentView.string = content
        updateContentStats()
        isEditingSessionOpen = true
        contentView.undoManager?.removeAllActions()
        window.undoManager?.removeAllActions()
        NSApp.activate(ignoringOtherApps: true)
        centerWindowOnPointerScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(titleField)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "保存片段"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = UIStyle.canvas
        window.minSize = NSSize(width: 480, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self

        titleField = NSTextField()
        titleField.placeholderString = "为这段内容起个名字"
        titleField.font = .systemFont(ofSize: 14)
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .exterior
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setAccessibilityLabel("片段标题")
        let titleSurface = SurfaceView(border: UIStyle.border, radius: 8)
        titleSurface.addSubview(titleField)
        NSLayoutConstraint.activate([
            titleSurface.heightAnchor.constraint(equalToConstant: 40),
            titleField.leadingAnchor.constraint(equalTo: titleSurface.leadingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: titleSurface.trailingAnchor, constant: -12),
            titleField.centerYAnchor.constraint(equalTo: titleSurface.centerYAnchor),
        ])

        contentView = NSTextView()
        contentView.isRichText = false
        contentView.isAutomaticQuoteSubstitutionEnabled = false
        contentView.isAutomaticDashSubstitutionEnabled = false
        contentView.isAutomaticTextReplacementEnabled = false
        contentView.isAutomaticSpellingCorrectionEnabled = false
        contentView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        contentView.textColor = .labelColor
        contentView.backgroundColor = UIStyle.surface
        contentView.delegate = self
        contentView.setAccessibilityLabel("片段正文")
        contentView.allowsUndo = true
        contentView.autoresizingMask = [.width]
        contentView.textContainerInset = NSSize(width: 12, height: 12)
        contentView.isHorizontallyResizable = false
        contentView.isVerticallyResizable = true
        contentView.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        contentView.defaultParagraphStyle = paragraph

        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = contentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let contentSurface = SurfaceView(border: UIStyle.border, radius: 8)
        contentSurface.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentSurface.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: contentSurface.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: contentSurface.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: contentSurface.trailingAnchor, constant: -4),
        ])

        let cancelBtn = makeDialogButton("取消", action: #selector(cancel), keyEquivalent: "\u{1b}")
        let saveBtn = makeDialogButton("保存", action: #selector(save), keyEquivalent: "\r")

        let buttons = NSStackView(views: [cancelBtn, saveBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let v = SurfaceView(fill: UIStyle.canvas, radius: 0)
        let titleSection = labeledSection("标题", detail: "可选 · 留空时自动命名", control: titleSurface)
        let contentSection = labeledSection("内容", detail: "纯文本", control: contentSurface)
        contentStats = UIStyle.label("", size: 11, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [contentStats, spacer, buttons])
        footer.alignment = .centerY
        footer.spacing = 12
        let divider = UIStyle.separator()

        let stack = NSStackView(views: [titleSection, contentSection, divider, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -20),

            titleSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.contentView = v
    }

    private func labeledSection(_ title: String, detail: String, control: NSView) -> NSView {
        let lbl = UIStyle.label(title, size: 12, weight: .semibold)
        let hint = UIStyle.label(detail, size: 11, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let heading = NSStackView(views: [lbl, spacer, hint])
        heading.alignment = .centerY
        let s = NSStackView(views: [heading, control])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 8
        heading.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        control.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        return s
    }

    func textDidChange(_ notification: Notification) { updateContentStats() }

    private func updateContentStats() {
        let text = contentView.string
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        contentStats.stringValue = "\(lines) 行 · \(text.count) 字符"
    }

    private func makeDialogButton(_ title: String, action: Selector, keyEquivalent: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = keyEquivalent
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return b
    }

    @objc private func cancel() {
        confirmDiscardingChanges { [weak self] allowed in
            if allowed { self?.closeEditor() }
        }
    }

    private func closeEditor() {
        isEditingSessionOpen = false
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    func confirmDiscardingChanges(_ completion: @escaping (Bool) -> Void) {
        guard window?.attachedSheet == nil else {
            window.makeKeyAndOrderFront(nil)
            completion(false)
            return
        }
        guard hasUnsavedChanges else { completion(true); return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let name = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = NSAlert()
        alert.messageText = "保存对“\(name.isEmpty ? "新片段" : name)”的修改？"
        alert.informativeText = "选择“放弃”将丢失当前未保存的内容。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            switch response {
            case .alertFirstButtonReturn: completion(self.saveDraft())
            case .alertSecondButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    @objc private func save() {
        if saveDraft() { closeEditor() }
    }

    private func saveDraft() -> Bool {
        let rawTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentView.string
        let bodyEmpty = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !bodyEmpty else {
            showEditorError(title: "无法保存片段", message: "片段正文不能为空")
            window.makeFirstResponder(contentView)
            return false
        }
        let title = rawTitle.isEmpty ? defaultTitle(for: content) : rawTitle
        do {
            if var snippet = editing {
                snippet.title = title
                snippet.content = content
                try store.update(snippet)
                editing = snippet
                titleField.stringValue = snippet.title
                return true
            } else {
                switch try store.add(title: title, content: content) {
                case .added(let snippet):
                    editing = snippet
                    titleField.stringValue = snippet.title
                    return true
                case .duplicate(let existing):
                    showDuplicateError(existing)
                }
            }
        } catch SnippetStore.StoreError.duplicateContent(let existing) {
            showDuplicateError(existing)
        } catch SnippetStore.StoreError.snippetNotFound {
            editing = nil
            window.title = "新建片段"
            showEditorError(title: "原片段已不存在",
                            message: "该片段已被删除或替换，当前内容已保留。再次点击“保存”可将其另存为新片段。")
        } catch {
            showEditorError(title: "无法保存片段", message: error.localizedDescription)
        }
        return false
    }

    private func defaultTitle(for content: String) -> String {
        let first = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "未命名"
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    private func showDuplicateError(_ snippet: Snippet) {
        showEditorError(title: "片段已存在",
                        message: "相同正文已存在于片段“\(snippet.title)”。当前修改已保留，请修改正文后再保存。")
    }

    private func showEditorError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onApply: ((HotKeyConfig) -> Bool)?
    var onApplySnippetSummon: ((HotKeyConfig) -> Bool)?
    var historyStore: HistoryStore?
    var snippetStore: SnippetStore?

    private var window: NSWindow!
    private var recordButton: HotKeyRecorderButton!
    private var snippetSummonButton: HotKeyRecorderButton!
    private var statusLabel: NSTextField!
    private var dataStatusLabel: NSTextField!
    private var autostartSwitch: NSSwitch!
    private var maxItemsField: NSTextField!
    private var maxItemsStepper: NSStepper!

    func show() {
        if window == nil { build() }
        recordButton.stop()
        recordButton.config = HotKeyConfig.history
        snippetSummonButton.stop()
        snippetSummonButton.config = HotKeyConfig.snippet
        setStatus(nil)
        setDataStatus(nil)
        autostartSwitch.state = LaunchAgent.isEnabled ? .on : .off
        let currentMax = historyStore?.maxItems ?? 100
        maxItemsField.integerValue = currentMax
        maxItemsStepper.integerValue = currentMax
        NSApp.activate(ignoringOtherApps: true)
        centerWindowOnPointerScreen(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "设置"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = UIStyle.canvas
        window.minSize = NSSize(width: 540, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContentView()
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        UIStyle.label(s, size: 12, weight: .semibold, color: .secondaryLabelColor)
    }
    private func footnote(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.maximumNumberOfLines = 0
        l.lineBreakMode = .byWordWrapping
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func buildContentView() -> NSView {
        let v = SurfaceView(fill: UIStyle.canvas, radius: 0)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        v.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: v.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let appIcon = UIStyle.symbol("doc.on.clipboard", size: 28, color: .controlAccentColor)
        appIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let appTitle = UIStyle.label("PasteHistory", size: 18, weight: .semibold)
        let appDetail = UIStyle.label("快捷访问与本地数据", size: 12, color: .secondaryLabelColor)
        let appText = NSStackView(views: [appTitle, appDetail])
        appText.orientation = .vertical
        appText.alignment = .leading
        appText.spacing = 4
        let header = NSStackView(views: [appIcon, appText])
        header.alignment = .centerY
        header.spacing = 12

        recordButton = HotKeyRecorderButton()
        recordButton.config = HotKeyConfig.history
        recordButton.onChange = { [weak self] cfg in self?.onApply?(cfg) ?? false }
        recordButton.onStatus = { [weak self] msg in self?.setStatus(msg) }
        recordButton.widthAnchor.constraint(equalToConstant: 116).isActive = true

        snippetSummonButton = HotKeyRecorderButton()
        snippetSummonButton.config = HotKeyConfig.snippet
        snippetSummonButton.onChange = { [weak self] cfg in self?.onApplySnippetSummon?(cfg) ?? false }
        snippetSummonButton.onStatus = { [weak self] msg in self?.setStatus(msg) }
        snippetSummonButton.widthAnchor.constraint(equalToConstant: 116).isActive = true

        let hkGroup = makeGroup([
            formRow("历史选择器", symbol: "clock.arrow.circlepath", trailing: [recordButton, smallButton("恢复默认", #selector(resetHistoryDefault))]),
            hSeparator(),
            formRow("片段选择器", symbol: "square.stack", trailing: [snippetSummonButton, smallButton("恢复默认", #selector(resetSnippetSummonDefault))]),
        ])

        let hkHint = footnote("点击快捷键开始录制，按 Esc 取消。组合键需包含 ⌘、⌥ 或 ⌃。")
        statusLabel = footnote("")
        statusLabel.isHidden = true
        let hkHelp = NSStackView(views: [hkHint, statusLabel])
        hkHelp.orientation = .vertical
        hkHelp.alignment = .leading
        hkHelp.spacing = 4

        autostartSwitch = NSSwitch()
        autostartSwitch.target = self
        autostartSwitch.action = #selector(toggleAutostart)

        maxItemsField = NSTextField()
        maxItemsField.integerValue = historyStore?.maxItems ?? 100
        maxItemsField.font = .systemFont(ofSize: 13)
        maxItemsField.alignment = .center
        maxItemsField.bezelStyle = .roundedBezel
        maxItemsField.delegate = self
        maxItemsField.setAccessibilityLabel("保留历史条数")
        maxItemsField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        maxItemsStepper = NSStepper()
        maxItemsStepper.minValue = 10
        maxItemsStepper.maxValue = 500
        maxItemsStepper.increment = 10
        maxItemsStepper.integerValue = historyStore?.maxItems ?? 100
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(stepperChanged)

        let genGroup = makeGroup([
            formRow("保留历史条数", detail: "保留最近 10–500 条记录", symbol: "clock", trailing: [maxItemsField, maxItemsStepper]),
            hSeparator(),
            formRow("开机自启动", detail: "登录后在菜单栏自动运行", symbol: "power", trailing: [autostartSwitch]),
        ])

        let clearHistoryButton = smallButton("清空历史…", #selector(clearHistory))
        clearHistoryButton.contentTintColor = .systemRed

        let snippetActions = NSStackView(views: [
            smallButton("导入…", #selector(importSnippets)),
            smallButton("导出…", #selector(exportSnippets)),
        ])
        snippetActions.orientation = .horizontal
        snippetActions.spacing = 8

        let dataGroup = makeGroup([
            formRow("历史管理", detail: "清空已记录的文本、图片和文件", symbol: "tray", trailing: [clearHistoryButton]),
            hSeparator(),
            formRow("片段管理", detail: "通过 JSON 备份或迁移常用片段", symbol: "square.stack", trailing: [snippetActions]),
        ])
        dataStatusLabel = footnote("")
        dataStatusLabel.isHidden = true

        let hkTitle = sectionLabel("快捷键")
        let genTitle = sectionLabel("通用")
        let dataTitle = sectionLabel("数据管理")

        let stack = NSStackView(views: [header, genTitle, genGroup,
                                        hkTitle, hkGroup, hkHelp,
                                        dataTitle, dataGroup, dataStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(24, after: header)
        stack.setCustomSpacing(8, after: genTitle)
        stack.setCustomSpacing(20, after: genGroup)
        stack.setCustomSpacing(8, after: hkTitle)
        stack.setCustomSpacing(10, after: hkGroup)
        stack.setCustomSpacing(20, after: hkHelp)
        stack.setCustomSpacing(8, after: dataTitle)
        stack.setCustomSpacing(4, after: dataGroup)

        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            hkGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            genGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dataGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hkHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hkHint.widthAnchor.constraint(equalTo: hkHelp.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: hkHelp.widthAnchor),
            dataStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return v
    }

    private func formRow(_ title: String, detail: String? = nil, symbol: String, trailing: [NSView]) -> NSView {
        let l = UIStyle.label(title, size: 13)
        let text = NSStackView(views: [l])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        if let detail { text.addArrangedSubview(UIStyle.label(detail, size: 11, color: .secondaryLabelColor)) }
        let icon = UIStyle.symbol(symbol, size: 15)
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: detail == nil ? 48 : 60).isActive = true
        return row
    }

    private func makeGroup(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = SurfaceView(border: UIStyle.border)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -1),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 1),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -1),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        return container
    }

    private func hSeparator() -> NSView {
        let container = NSView()
        let line = UIStyle.separator()
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 42),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    @objc private func resetHistoryDefault() {
        recordButton.stop()
        if onApply?(.historyDefault) == true {
            recordButton.config = .historyDefault
            setStatus("已恢复默认 \(HotKeyConfig.historyDefault.display)")
        } else {
            setStatus("默认组合 \(HotKeyConfig.historyDefault.display) 当前被占用")
        }
    }

    @objc private func resetSnippetSummonDefault() {
        snippetSummonButton.stop()
        if onApplySnippetSummon?(.snippetDefault) == true {
            snippetSummonButton.config = .snippetDefault
            setStatus("已恢复默认 \(HotKeyConfig.snippetDefault.display)")
        } else {
            setStatus("默认组合 \(HotKeyConfig.snippetDefault.display) 当前被占用")
        }
    }

    @objc private func toggleAutostart() {
        if autostartSwitch.state == .on {
            LaunchAgent.enable()
        } else {
            LaunchAgent.disable()
        }
        autostartSwitch.state = LaunchAgent.isEnabled ? .on : .off
    }

    @objc private func stepperChanged() {
        let val = maxItemsStepper.integerValue
        maxItemsField.integerValue = val
        historyStore?.maxItems = val
    }

    private func setStatus(_ message: String?) {
        let text = message ?? ""
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
    }

    private func setDataStatus(_ message: String?) {
        let text = message ?? ""
        dataStatusLabel.stringValue = text
        dataStatusLabel.isHidden = text.isEmpty
    }

    @objc private func clearHistory() {
        guard let store = historyStore else { return }
        guard !store.items.isEmpty else {
            setDataStatus("当前没有历史记录")
            return
        }

        let count = store.items.count
        let alert = NSAlert()
        alert.messageText = "清空所有粘贴历史？"
        alert.informativeText = "将永久删除 \(count) 条记录及其图片文件，此操作不可撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            store.clear()
            self?.setDataStatus("已清空 \(count) 条历史记录")
        }
    }

    @objc private func importSnippets() {
        guard let store = snippetStore else { return }
        let panel = NSOpenPanel()
        panel.title = "导入代码片段"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let snippets = try JSONDecoder().decode([Snippet].self, from: data)
                self?.confirmImport(snippets, into: store)
            } catch {
                self?.showDataError(title: "无法导入片段", error: error)
            }
        }
    }

    private func confirmImport(_ snippets: [Snippet], into store: SnippetStore) {
        let alert = NSAlert()
        alert.messageText = "导入 \(snippets.count) 条代码片段"
        alert.informativeText = "“合并导入”会按 UUID 更新同一片段并保留其他数据；“替换全部”会先移除现有片段。独立快捷键也会一并导入。"
        alert.addButton(withTitle: "合并导入")
        alert.addButton(withTitle: "替换全部")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window) { [weak self] response in
            let mode: SnippetStore.ImportMode
            switch response {
            case .alertFirstButtonReturn: mode = .merge
            case .alertSecondButtonReturn: mode = .replace
            default: return
            }

            do {
                let summary = try store.importItems(snippets, mode: mode)
                switch mode {
                case .merge:
                    var message = "导入完成：新增 \(summary.added) 条，更新 \(summary.updated) 条"
                    if summary.skipped > 0 { message += "，忽略重复项 \(summary.skipped) 条" }
                    self?.setDataStatus(message)
                case .replace:
                    var message = "已用 \(summary.total) 条片段替换原有 \(summary.replaced) 条"
                    if summary.skipped > 0 { message += "，忽略重复项 \(summary.skipped) 条" }
                    self?.setDataStatus(message)
                }
            } catch {
                self?.showDataError(title: "无法导入片段", error: error)
            }
        }
    }

    @objc private func exportSnippets() {
        guard let store = snippetStore else { return }
        let panel = NSSavePanel()
        panel.title = "导出代码片段"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "PasteHistory-snippets.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try store.exportData().write(to: url, options: .atomic)
                self?.setDataStatus("已导出 \(store.items.count) 条片段")
            } catch {
                self?.showDataError(title: "无法导出片段", error: error)
            }
        }
    }

    private func showDataError(title: String, error: Error) {
        setDataStatus(nil)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === maxItemsField else { return }
        let val = max(10, min(field.integerValue, 500))
        maxItemsField.integerValue = val
        maxItemsStepper.integerValue = val
        historyStore?.maxItems = val
    }

    func windowWillClose(_ notification: Notification) {
        recordButton.stop()
        snippetSummonButton.stop()
        setStatus(nil)
        setDataStatus(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        recordButton.stop()
        snippetSummonButton.stop()
    }
}
