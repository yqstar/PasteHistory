import Cocoa
import UniformTypeIdentifiers

// MARK: - History palette controller

final class HistoryWindowController {
    let store: HistoryStore
    let monitor: ClipboardMonitor

    private let palette = PaletteController()
    private var filtered: [ClipItem] = []
    private let thumbCache = NSCache<NSString, NSImage>()

    init(store: HistoryStore, monitor: ClipboardMonitor) {
        thumbCache.countLimit = 50
        self.store = store
        self.monitor = monitor
        palette.placeholder = "搜索粘贴历史…"
        palette.emptyText = "暂无历史，复制点东西试试"
        palette.footerHints = [("↩", "粘贴"), ("⌘⌫", "删除"), ("esc", "关闭")]
        palette.provider = { [weak self] q in self?.rows(for: q) ?? [] }
        palette.onActivate = { [weak self] i in self?.activate(i) ?? false }
        palette.onDelete = { [weak self] i in self?.deleteAt(i) }
    }

    func show() { palette.show() }
    func hide() { palette.hide() }
    func toggle() { palette.toggle() }
    func refreshIfVisible() { palette.reloadIfVisible() }

    private func rows(for query: String) -> [PaletteRow] {
        if query.isEmpty {
            filtered = store.items
        } else {
            filtered = store.items.filter {
                matchesQuery($0.oneLine(400), query) || matchesQuery(kindLabel($0.kind), query)
            }
        }
        return filtered.map { item in
            PaletteRow(icon: icon(for: item),
                       iconIsTemplate: item.kind != .image,
                       iconTint: kindColor(item.kind),
                       title: item.oneLine(120),
                       subtitle: relativeTime(item.date),
                       badge: kindLabel(item.kind),
                       badgeColor: kindColor(item.kind))
        }
    }

    private func icon(for item: ClipItem) -> NSImage? {
        if item.kind == .image, let f = item.imageFile {
            let key = f as NSString
            if let cached = thumbCache.object(forKey: key) { return cached }
            guard let img = NSImage(contentsOf: store.imageURL(f)) else { return nil }
            let thumbSize: CGFloat = 48
            let ratio = max(img.size.width, 1) / max(img.size.height, 1)
            let w = ratio >= 1 ? thumbSize : thumbSize * ratio
            let h = ratio >= 1 ? thumbSize / ratio : thumbSize
            let thumb = NSImage(size: NSSize(width: w, height: h))
            thumb.lockFocus()
            img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            thumb.unlockFocus()
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
}

// MARK: - Snippet picker controller

final class SnippetPickerWindowController {
    let store: SnippetStore
    let monitor: ClipboardMonitor
    var onEdit: ((Snippet) -> Void)?

    private let palette = PaletteController()
    private var filtered: [Snippet] = []

    init(store: SnippetStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        palette.placeholder = "搜索代码片段…"
        palette.emptyText = "暂无片段，可从设置 → 数据管理中保存或导入"
        palette.footerHints = [("↩", "粘贴"), ("⌘E", "编辑"), ("⌘⌫", "删除"), ("esc", "关闭")]
        palette.provider = { [weak self] q in self?.rows(for: q) ?? [] }
        palette.onActivate = { [weak self] i in self?.activate(i) ?? false }
        palette.onDelete = { [weak self] i in self?.deleteAt(i) }
        palette.onEditRow = { [weak self] i in self?.editAt(i) }
    }

    func show() { palette.show() }
    func hide() { palette.hide() }
    func toggle() { palette.toggle() }
    func refreshIfVisible() { palette.reloadIfVisible() }

    private func editAt(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        palette.hide()
        onEdit?(filtered[i])
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
            return PaletteRow(icon: NSImage(systemSymbolName: kind.symbolName,
                                            accessibilityDescription: nil),
                              iconIsTemplate: true,
                              iconTint: kind.color,
                              title: s.title.isEmpty ? "未命名" : s.title,
                              subtitle: subtitle(for: s.content),
                              badge: kind.label,
                              badgeColor: kind.color,
                              accessoryBadge: s.hotKey?.display,
                              accessoryBadgeColor: nil)
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
        parts.append(preview(of: stripped))
        return parts.joined(separator: " · ")
    }

    private func preview(of content: String) -> String {
        var s = content.replacingOccurrences(of: "\n", with: " ")
                       .replacingOccurrences(of: "\t", with: " ")
        if s.count > 80 { s = String(s.prefix(80)) + "…" }
        return s
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
        store.delete(id: filtered[i].id)
    }
}

// MARK: - Snippet editor

final class SnippetEditorWindowController: NSObject, NSWindowDelegate {
    let store: SnippetStore

    private var window: NSWindow!
    private var titleField: NSTextField!
    private var contentView: NSTextView!
    private var editing: Snippet?

    init(store: SnippetStore) {
        self.store = store
    }

    func show() {
        editing = nil
        showWindow(title: "保存片段", name: "", content: "")
    }

    func showEdit(_ snippet: Snippet) {
        editing = snippet
        showWindow(title: "编辑片段", name: snippet.title, content: snippet.content)
    }

    private func showWindow(title: String, name: String, content: String) {
        if window == nil { build() }
        window.title = title
        titleField.stringValue = name
        contentView.string = content
        NSApp.activate(ignoringOtherApps: true)
        centerWindowOnPointerScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(titleField)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "保存片段"
        window.subtitle = "保存后会出现在片段选择器"
        window.isReleasedWhenClosed = false
        window.delegate = self

        titleField = NSTextField()
        titleField.placeholderString = "为这段内容起个名字"
        titleField.font = .systemFont(ofSize: 15)
        titleField.bezelStyle = .roundedBezel

        contentView = NSTextView()
        contentView.isRichText = false
        contentView.isAutomaticQuoteSubstitutionEnabled = false
        contentView.isAutomaticDashSubstitutionEnabled = false
        contentView.isAutomaticTextReplacementEnabled = false
        contentView.isAutomaticSpellingCorrectionEnabled = false
        contentView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        contentView.allowsUndo = true
        contentView.autoresizingMask = [.width]
        contentView.textContainerInset = NSSize(width: 6, height: 6)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = contentView

        let cancelBtn = makeDialogButton("取消", action: #selector(cancel), keyEquivalent: "\u{1b}")
        let saveBtn = makeDialogButton("保存", action: #selector(save), keyEquivalent: "\r")

        let buttons = NSStackView(views: [cancelBtn, saveBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let v = NSView()
        let titleSection = labeledSection("标题", control: titleField)
        let contentSection = labeledSection("内容", control: scroll)

        let stack = NSStackView(views: [titleSection, contentSection, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -18),

            titleSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        window.contentView = v
    }

    private func labeledSection(_ title: String, control: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        let s = NSStackView(views: [lbl, control])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        return s
    }

    private func makeDialogButton(_ title: String, action: Selector, keyEquivalent: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = keyEquivalent
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return b
    }

    @objc private func cancel() {
        window.orderOut(nil)
    }

    @objc private func save() {
        let rawTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentView.string
        let bodyEmpty = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if rawTitle.isEmpty && bodyEmpty {
            window.orderOut(nil)
            return
        }
        let title = rawTitle.isEmpty ? "未命名" : rawTitle
        if var s = editing {
            s.title = title
            s.content = content
            store.update(s)
        } else {
            store.add(title: title, content: content)
        }
        window.orderOut(nil)
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onApply: ((HotKeyConfig) -> Bool)?
    var onApplySnippetSummon: ((HotKeyConfig) -> Bool)?
    var onSaveSnippet: (() -> Void)?
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildGeneralTab()
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
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

    private func buildGeneralTab() -> NSView {
        let v = NSView()

        recordButton = HotKeyRecorderButton()
        recordButton.config = HotKeyConfig.history
        recordButton.onChange = { [weak self] cfg in self?.onApply?(cfg) ?? false }
        recordButton.onStatus = { [weak self] msg in self?.setStatus(msg) }
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        snippetSummonButton = HotKeyRecorderButton()
        snippetSummonButton.config = HotKeyConfig.snippet
        snippetSummonButton.onChange = { [weak self] cfg in self?.onApplySnippetSummon?(cfg) ?? false }
        snippetSummonButton.onStatus = { [weak self] msg in self?.setStatus(msg) }
        snippetSummonButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let hkGroup = makeGroup([
            formRow("唤出历史选择器", trailing: [recordButton, smallButton("恢复默认", #selector(resetHistoryDefault))]),
            hSeparator(),
            formRow("唤出片段选择器", trailing: [snippetSummonButton, smallButton("恢复默认", #selector(resetSnippetSummonDefault))]),
        ])

        let hkHint = footnote("点击按钮录制新快捷键。组合键需包含 ⌘、⌥ 或 ⌃；按 Esc 取消，若组合已被占用则保留当前设置。")
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
        maxItemsField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        maxItemsStepper = NSStepper()
        maxItemsStepper.minValue = 10
        maxItemsStepper.maxValue = 10000
        maxItemsStepper.increment = 10
        maxItemsStepper.integerValue = historyStore?.maxItems ?? 100
        maxItemsStepper.target = self
        maxItemsStepper.action = #selector(stepperChanged)

        let maxItemsHint = footnote("范围 10 – 10000")

        let genGroup = makeGroup([
            formRow("保留历史条数", trailing: [maxItemsField, maxItemsStepper, maxItemsHint]),
            hSeparator(),
            formRow("开机自启动", trailing: [autostartSwitch]),
        ])

        let clearHistoryButton = smallButton("清空历史…", #selector(clearHistory))
        clearHistoryButton.contentTintColor = .systemRed

        let snippetActions = NSStackView(views: [
            smallButton("保存片段…", #selector(saveSnippet)),
            smallButton("导入…", #selector(importSnippets)),
            smallButton("导出…", #selector(exportSnippets)),
        ])
        snippetActions.orientation = .horizontal
        snippetActions.spacing = 8

        let dataGroup = makeGroup([
            formRow("历史记录", trailing: [clearHistoryButton]),
            hSeparator(),
            formRow("代码片段", trailing: [snippetActions]),
        ])
        dataStatusLabel = footnote("")
        dataStatusLabel.isHidden = true

        let hkTitle = sectionLabel("快捷键")
        let genTitle = sectionLabel("通用")
        let dataTitle = sectionLabel("数据管理")

        let stack = NSStackView(views: [genTitle, genGroup,
                                        hkTitle, hkGroup, hkHelp,
                                        dataTitle, dataGroup, dataStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: genTitle)
        stack.setCustomSpacing(20, after: genGroup)
        stack.setCustomSpacing(8, after: hkTitle)
        stack.setCustomSpacing(10, after: hkGroup)
        stack.setCustomSpacing(20, after: hkHelp)
        stack.setCustomSpacing(8, after: dataTitle)
        stack.setCustomSpacing(4, after: dataGroup)

        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
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

    private func formRow(_ title: String, trailing: [NSView]) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        return row
    }

    private func makeGroup(_ rows: [NSView]) -> NSBox {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = container
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func hSeparator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
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

    @objc private func saveSnippet() {
        setDataStatus(nil)
        onSaveSnippet?()
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
                let snippets = try store.decodeImportData(data)
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

            let summary = store.importItems(snippets, mode: mode)
            switch mode {
            case .merge:
                var message = "导入完成：新增 \(summary.added) 条，更新 \(summary.updated) 条"
                if summary.skipped > 0 { message += "，忽略重复 UUID \(summary.skipped) 条" }
                self?.setDataStatus(message)
            case .replace:
                var message = "已用 \(summary.total) 条片段替换原有 \(summary.replaced) 条"
                if summary.skipped > 0 { message += "，忽略重复 UUID \(summary.skipped) 条" }
                self?.setDataStatus(message)
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
        let val = max(10, min(field.integerValue, 10000))
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
}
