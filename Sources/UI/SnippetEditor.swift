import Cocoa

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
        titleField.font = .systemFont(ofSize: 15, weight: .medium)
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.cell?.usesSingleLineMode = true
        titleField.cell?.isScrollable = true
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.setAccessibilityLabel("片段标题")
        let titleSurface = InputSurfaceView(border: UIStyle.border, radius: 10)
        titleSurface.focusTarget = titleField
        titleSurface.addSubview(titleField)
        NSLayoutConstraint.activate([
            titleSurface.heightAnchor.constraint(equalToConstant: 44),
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
        contentView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        contentView.textColor = .labelColor
        contentView.backgroundColor = UIStyle.surface
        contentView.delegate = self
        contentView.setAccessibilityLabel("片段正文")
        contentView.allowsUndo = true
        contentView.autoresizingMask = [.width]
        contentView.textContainerInset = NSSize(width: 14, height: 14)
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
        let contentSurface = InputSurfaceView(border: UIStyle.border)
        contentSurface.focusTarget = contentView
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
        contentStats.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [contentStats, spacer, buttons])
        footer.alignment = .centerY
        footer.spacing = 12
        let stack = NSStackView(views: [titleSection, contentSection, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
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
        let statistics = TextStatistics(contentView.string)
        contentStats.stringValue = "\(statistics.lineCount) 行 · \(statistics.characterCount) 字符"
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
