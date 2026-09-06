import Cocoa
import UniformTypeIdentifiers

// MARK: - Settings window

final class SettingsWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    var onApply: ((HotKeyConfig) -> Bool)?
    var onApplySnippetSummon: ((HotKeyConfig) -> Bool)?
    var onShowVersions: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
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
        let currentMax = historyStore?.maxItems ?? HistoryStore.defaultMaxItems
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
        let appDetail = UIStyle.label("版本 \(AppReleaseInfo.version) · 快捷访问与本地数据", size: 12, color: .secondaryLabelColor)
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
        maxItemsField.integerValue = historyStore?.maxItems ?? HistoryStore.defaultMaxItems
        maxItemsField.font = .systemFont(ofSize: 13)
        maxItemsField.alignment = .center
        maxItemsField.bezelStyle = .roundedBezel
        maxItemsField.delegate = self
        maxItemsField.setAccessibilityLabel("保留历史条数")
        maxItemsField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        maxItemsStepper = NSStepper()
        maxItemsStepper.minValue = Double(HistoryStore.maxItemsRange.lowerBound)
        maxItemsStepper.maxValue = Double(HistoryStore.maxItemsRange.upperBound)
        maxItemsStepper.increment = 10
        maxItemsStepper.integerValue = historyStore?.maxItems ?? HistoryStore.defaultMaxItems
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

        let versionActions = NSStackView(views: [
            smallButton("版本记录…", #selector(showVersions)),
            smallButton("检查更新…", #selector(checkUpdates)),
        ])
        versionActions.spacing = 8
        let versionGroup = makeGroup([
            formRow("版本与更新", detail: "手动检查 GitHub 上的正式版本", symbol: "arrow.down.circle", trailing: [versionActions]),
        ])

        let hkTitle = sectionLabel("快捷键")
        let genTitle = sectionLabel("通用")
        let dataTitle = sectionLabel("数据管理")

        let stack = NSStackView(views: [header, genTitle, genGroup,
                                        hkTitle, hkGroup, hkHelp,
                                        dataTitle, dataGroup, dataStatusLabel, versionGroup])
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
        stack.setCustomSpacing(16, after: dataGroup)

        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            hkGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            genGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dataGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            versionGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    @objc private func showVersions() { onShowVersions?() }
    @objc private func checkUpdates() { onCheckUpdates?() }

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
        let val = HistoryStore.clampedMaxItems(field.integerValue)
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
