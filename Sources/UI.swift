import Cocoa
import Carbon.HIToolbox

func centerWindowOnPointerScreen(_ window: NSWindow) {
    let mouseLocation = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
        window.center()
        return
    }
    let visible = screen.visibleFrame
    let size = window.frame.size
    window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                  y: visible.midY - size.height / 2))
}

// MARK: - Pill view

final class PillView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let fill: NSColor
    private let stroke: NSColor

    init(text: String, font: NSFont, textColor: NSColor, fill: NSColor, stroke: NSColor) {
        self.fill = fill
        self.stroke = stroke
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = stroke == .clear ? 0 : 1
        label.font = font
        label.textColor = textColor
        label.alignment = .center
        label.stringValue = text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = stroke.cgColor
        }
    }
}

// MARK: - Palette data

struct PaletteRow {
    var icon: NSImage?
    var iconIsTemplate: Bool = true
    var iconTint: NSColor? = nil
    var title: String
    var subtitle: String
    var badge: String? = nil
    var badgeColor: NSColor? = nil
    var accessoryBadge: String? = nil
    var accessoryBadgeColor: NSColor? = nil
}

// MARK: - Palette cell

final class PaletteCellView: NSTableCellView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let rowStack: NSStackView
    private var badgePill: PillView?
    private var accessoryPill: PillView?

    override init(frame frameRect: NSRect) {
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subLabel.font = .systemFont(ofSize: 11)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        subLabel.cell?.usesSingleLineMode = true
        subLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        rowStack = NSStackView(views: [icon, textStack, spacer])
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 11
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true

        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ row: PaletteRow) {
        if let img = row.icon {
            img.isTemplate = row.iconIsTemplate
            icon.image = img
            icon.contentTintColor = row.iconIsTemplate ? (row.iconTint ?? .secondaryLabelColor) : nil
            icon.layer?.cornerRadius = row.iconIsTemplate ? 0 : 5
        } else {
            icon.image = nil
        }
        titleLabel.stringValue = row.title
        subLabel.stringValue = row.subtitle
        subLabel.isHidden = row.subtitle.isEmpty

        if let p = accessoryPill {
            rowStack.removeArrangedSubview(p)
            p.removeFromSuperview()
            accessoryPill = nil
        }
        if let p = badgePill {
            rowStack.removeArrangedSubview(p)
            p.removeFromSuperview()
            badgePill = nil
        }
        if let text = row.badge {
            let pill = makePill(text: text, color: row.badgeColor)
            rowStack.addArrangedSubview(pill)
            badgePill = pill
        }
        if let text = row.accessoryBadge {
            let pill = makePill(text: text, color: row.accessoryBadgeColor)
            rowStack.addArrangedSubview(pill)
            accessoryPill = pill
        }
    }

    private func makePill(text: String, color: NSColor?) -> PillView {
        if let c = color {
            return PillView(text: text, font: .systemFont(ofSize: 10, weight: .medium),
                            textColor: c, fill: c.withAlphaComponent(0.16), stroke: .clear)
        }
        return PillView(text: text, font: .systemFont(ofSize: 10, weight: .medium),
                        textColor: .secondaryLabelColor, fill: .clear, stroke: .separatorColor)
    }
}

// MARK: - Palette controller

final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                               NSTextFieldDelegate, NSWindowDelegate {
    var placeholder = "搜索…"
    var footerHints: [(cap: String, text: String)] = [("↩", "粘贴"), ("esc", "关闭")]
    var emptyText = "暂无内容"
    var provider: ((String) -> [PaletteRow])?
    var onActivate: ((Int) -> Bool)?
    var onDelete: ((Int) -> Void)?
    var onEditRow: ((Int) -> Void)?

    private var window: NSWindow!
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scroll: NSScrollView!
    private var emptyLabel: NSTextField!
    private var rows: [PaletteRow] = []
    private var query = ""
    private var deleteMonitor: Any?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if window == nil { build() }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        searchField.placeholderString = placeholder
        searchField.stringValue = ""
        query = ""
        reload()
        NSApp.activate(ignoringOtherApps: true)
        centerWindowOnPointerScreen(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        installDeleteMonitor()
    }

    func hide() {
        removeDeleteMonitor()
        window?.orderOut(nil)
        let prev = previousApp
        previousApp = nil
        if let prev = prev {
            prev.activate(options: [])
        } else {
            NSApp.hide(nil)
        }
    }

    func reloadIfVisible() { if isVisible { reload(preserveSelection: true) } }

    private func reload(preserveSelection: Bool = false) {
        let prev = preserveSelection ? (tableView?.selectedRow ?? 0) : 0
        rows = provider?(query) ?? []
        tableView?.reloadData()
        let empty = rows.isEmpty
        emptyLabel?.isHidden = !empty
        scroll?.isHidden = empty
        if !empty {
            let idx = min(max(prev, 0), rows.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 440, height: 280)
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSVisualEffectView()
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content

        searchField = NSTextField()
        searchField.placeholderString = placeholder
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 20)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView()
        glyph.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        glyph.image?.isTemplate = true
        glyph.contentTintColor = .secondaryLabelColor
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let topDivider = NSBox()
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false

        tableView = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 48
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.doubleAction = #selector(activateDoubleClick)

        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(labelWithString: emptyText)
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false

        let footer = buildFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(glyph)
        content.addSubview(searchField)
        content.addSubview(topDivider)
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        content.addSubview(bottomDivider)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            glyph.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 20),

            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            topDivider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            topDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -11),
        ])
    }

    private func buildFooter() -> NSView {
        let groups: [NSView] = footerHints.map { hint in
            let cap = PillView(text: hint.cap, font: .systemFont(ofSize: 11, weight: .medium),
                               textColor: .secondaryLabelColor, fill: .clear, stroke: .separatorColor)
            let lbl = NSTextField(labelWithString: hint.text)
            lbl.font = .systemFont(ofSize: 11)
            lbl.textColor = .secondaryLabelColor
            let s = NSStackView(views: [cap, lbl])
            s.orientation = .horizontal
            s.alignment = .centerY
            s.spacing = 5
            return s
        }
        let footer = NSStackView(views: groups)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        return footer
    }

    private func installDeleteMonitor() {
        guard deleteMonitor == nil, (onDelete != nil || onEditRow != nil) else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            let row = self.tableView.selectedRow
            guard row >= 0, row < self.rows.count else { return e }
            if e.modifierFlags.contains(.command), Int(e.keyCode) == kVK_Delete {
                self.onDelete?(row)
                self.reload(preserveSelection: true)
                return nil
            }
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "e" {
                self.onEditRow?(row)
                return nil
            }
            return e
        }
    }
    private func removeDeleteMonitor() {
        if let m = deleteMonitor { NSEvent.removeMonitor(m); deleteMonitor = nil }
    }

    private func activate(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        guard onActivate?(row) == true else {
            NSSound.beep()
            return
        }
        hide()
        AutoPaste.deliver()
    }

    @objc private func activateDoubleClick() {
        let row = tableView.clickedRow
        if row >= 0 { activate(row) }
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        let cur = max(0, tableView.selectedRow)
        let next = min(max(cur + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            activate(tableView.selectedRow); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        query = searchField.stringValue
        reload()
    }

    func windowDidResignKey(_ notification: Notification) {
        if isVisible { hide() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("pcell")
        var cell = tableView.makeView(withIdentifier: id, owner: self) as? PaletteCellView
        if cell == nil {
            let c = PaletteCellView(frame: .zero)
            c.identifier = id
            cell = c
        }
        cell?.apply(rows[row])
        return cell
    }
}
