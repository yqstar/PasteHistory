import Cocoa
import Carbon.HIToolbox
import ImageIO

// Shared, opaque surfaces keep text legible regardless of the desktop behind a window.
enum UIStyle {
    static let canvas = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.135, alpha: 1)
            : NSColor(calibratedRed: 0.97, green: 0.975, blue: 0.985, alpha: 1)
    }
    static let surface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)
            : .white
    }
    static var border: NSColor {
        .labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.4 : 0.1)
    }

    static func readableTint(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.blended(withFraction: 0.2, of: .labelColor) ?? color
            }
            return resolved
        }
    }

    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 16, color: NSColor = .secondaryLabelColor) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        view.symbolConfiguration = .init(pointSize: size, weight: .medium)
        view.contentTintColor = color
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }
}

class SurfaceView: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var border: NSColor { didSet { needsDisplay = true } }
    let radius: CGFloat

    init(fill: NSColor = UIStyle.surface, border: NSColor = .clear, radius: CGFloat = 10) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

func loadImageThumbnail(at url: URL, maxSize: CGFloat) -> NSImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(maxSize * 2),
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
}

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

final class PillView: SurfaceView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, font: NSFont, textColor: NSColor, fill: NSColor, stroke: NSColor) {
        super.init(fill: fill, border: stroke, radius: 5)
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

}

// MARK: - Palette data

struct PaletteRow {
    var id: UUID
    var icon: NSImage?
    var iconIsTemplate: Bool = true
    var iconTint: NSColor? = nil
    var title: String
    var subtitle: String
    var badge: String? = nil
    var badgeColor: NSColor? = nil
    var accessoryBadge: String? = nil
    var accessoryBadgeColor: NSColor? = nil
    var canSaveAsSnippet = false
}

// MARK: - Palette cell

private final class PaletteRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class PaletteCellView: NSTableCellView {
    private let icon = NSImageView()
    private let iconBackground = SurfaceView(radius: 9)
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let rowStack: NSStackView
    private var pills: [PillView] = []

    override init(frame frameRect: NSRect) {
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
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
        textStack.spacing = 4
        textStack.setContentHuggingPriority(.init(1), for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        subLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true

        rowStack = NSStackView(views: [iconBackground, textStack])
        rowStack.orientation = .horizontal
        rowStack.distribution = .fill
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.setVisibilityPriority(.mustHold, for: iconBackground)
        rowStack.setVisibilityPriority(.mustHold, for: textStack)

        super.init(frame: frameRect)

        iconBackground.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBackground.widthAnchor.constraint(equalToConstant: 36),
            iconBackground.heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])

        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ row: PaletteRow) {
        row.icon?.isTemplate = row.iconIsTemplate
        icon.image = row.icon
        icon.contentTintColor = row.iconIsTemplate ? row.iconTint.map(UIStyle.readableTint) ?? .secondaryLabelColor : nil
        icon.layer?.cornerRadius = row.iconIsTemplate ? 0 : 3
        iconBackground.fill = (row.iconTint ?? .secondaryLabelColor).withAlphaComponent(0.09)
        titleLabel.stringValue = row.title
        subLabel.stringValue = row.subtitle
        subLabel.isHidden = row.subtitle.isEmpty

        for pill in pills {
            rowStack.removeArrangedSubview(pill)
            pill.removeFromSuperview()
        }
        pills = [(row.badge, row.badgeColor), (row.accessoryBadge, row.accessoryBadgeColor)].compactMap { text, color in
            text.map { makePill(text: $0, color: color) }
        }
        pills.forEach {
            rowStack.addArrangedSubview($0)
            rowStack.setVisibilityPriority(.mustHold, for: $0)
        }
    }

    private func makePill(text: String, color: NSColor?) -> PillView {
        return PillView(text: text, font: .systemFont(ofSize: 10, weight: .medium),
                        textColor: color.map(UIStyle.readableTint) ?? .secondaryLabelColor,
                        fill: color?.withAlphaComponent(0.09) ?? UIStyle.surface,
                        stroke: color == nil ? UIStyle.border : .clear)
    }
}

// MARK: - Palette controller

final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                               NSTextFieldDelegate, NSWindowDelegate {
    var title = "粘贴历史"
    var symbolName = "clock.arrow.circlepath"
    var placeholder = "搜索…"
    var footerHints: [(cap: String, text: String)] = [("↩", "粘贴"), ("esc", "关闭")]
    var footerSeparatorIndex: Int?
    var emptyText = "暂无内容"
    var emptyDetail = "复制文本、图片或文件后，会自动出现在这里。"
    var createActionTitle = "新建"
    var onCreate: (() -> Void)?
    var provider: ((String) -> [PaletteRow])?
    var onActivate: ((Int) -> Bool)?
    var onDelete: ((Int) -> Void)?
    var onEditRow: ((Int) -> Void)?
    var onSaveRow: ((Int) -> Void)?

    private var window: NSWindow!
    private var searchField: NSTextField!
    private var searchSurface: SurfaceView!
    private var countLabel: NSTextField!
    private var tableView: NSTableView!
    private var scroll: NSScrollView!
    private var emptyLabel: NSTextField!
    private var emptyDetailLabel: NSTextField!
    private var emptyIcon: NSImageView!
    private var emptyState: NSStackView!
    private var footerGroups: [NSView] = []
    private var rows: [PaletteRow] = []
    private var query = ""
    private var deleteMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var isHiding = false

    var isVisible: Bool { window?.isVisible ?? false }

    deinit { removeDeleteMonitor() }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

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

    @discardableResult
    func hide(reactivatePreviousApplication: Bool = true) -> NSRunningApplication? {
        guard !isHiding else { return nil }
        isHiding = true
        defer { isHiding = false }

        removeDeleteMonitor()
        let prev = previousApp
        previousApp = nil
        window?.orderOut(nil)
        if reactivatePreviousApplication, let prev, !prev.isTerminated {
            prev.activate()
        } else if reactivatePreviousApplication {
            NSApp.hide(nil)
        }
        return prev
    }

    func reloadIfVisible() { if isVisible { reload(preserveSelection: true) } }

    private func reload(preserveSelection: Bool = false) {
        let previousIndex = preserveSelection ? (tableView?.selectedRow ?? 0) : 0
        let previousID: UUID? = {
            guard preserveSelection, rows.indices.contains(previousIndex) else { return nil }
            return rows[previousIndex].id
        }()
        rows = provider?(query) ?? []
        tableView?.reloadData()
        let empty = rows.isEmpty
        countLabel?.stringValue = query.isEmpty ? "\(rows.count) 条" : "\(rows.count) 条结果"
        emptyLabel?.stringValue = query.isEmpty ? emptyText : "没有找到相关内容"
        emptyDetailLabel?.stringValue = query.isEmpty ? emptyDetail : "试试其他关键词，或缩短搜索内容。"
        emptyIcon?.image = NSImage(systemSymbolName: query.isEmpty ? symbolName : "magnifyingglass",
                                  accessibilityDescription: nil)
        emptyState?.isHidden = !empty
        scroll?.isHidden = empty
        if let idx = restoredSelectionIndex(previousID: previousID,
                                            previousIndex: previousIndex,
                                            newIDs: rows.map(\.id)) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
        updateFooterState()
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = title
        window.backgroundColor = UIStyle.canvas
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 440, height: 320)
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let content = SurfaceView(fill: UIStyle.canvas, radius: 0)
        window.contentView = content

        let headingIcon = UIStyle.symbol(symbolName, size: 15, color: .controlAccentColor)
        let heading = UIStyle.label(title, size: 13, weight: .semibold)
        countLabel = UIStyle.label("", size: 11, color: .secondaryLabelColor)
        let headingStack = NSStackView(views: [headingIcon, heading, countLabel])
        headingStack.alignment = .centerY
        headingStack.spacing = 8
        headingStack.translatesAutoresizingMaskIntoConstraints = false
        headingIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true

        searchField = NSTextField()
        searchField.placeholderString = placeholder
        searchField.delegate = self
        searchField.font = .systemFont(ofSize: 15)
        searchField.isBordered = false
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel(placeholder)

        let glyph = UIStyle.symbol("magnifyingglass", size: 15)
        searchSurface = SurfaceView(border: UIStyle.border)
        searchSurface.addSubview(glyph)
        searchSurface.addSubview(searchField)
        let topDivider = UIStyle.separator()

        tableView = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 60
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.target = self
        tableView.doubleAction = #selector(activateDoubleClick)
        tableView.setAccessibilityLabel(title)

        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyIcon = UIStyle.symbol(symbolName, size: 28, color: .tertiaryLabelColor)
        emptyIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        emptyLabel = UIStyle.label(emptyText, size: 14, weight: .medium)
        emptyLabel.alignment = .center
        emptyDetailLabel = UIStyle.label(emptyDetail, size: 12, color: .secondaryLabelColor)
        emptyDetailLabel.alignment = .center
        emptyState = NSStackView(views: [emptyIcon, emptyLabel, emptyDetailLabel])
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        emptyState.setCustomSpacing(14, after: emptyIcon)
        emptyState.setCustomSpacing(18, after: emptyDetailLabel)
        emptyState.isHidden = true
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        if onCreate != nil { emptyState.addArrangedSubview(makeCreateButton()) }

        let bottomDivider = UIStyle.separator()

        let footer = buildFooter()
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(headingStack)
        content.addSubview(searchSurface)
        content.addSubview(topDivider)
        content.addSubview(scroll)
        content.addSubview(emptyState)
        content.addSubview(bottomDivider)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            headingStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            headingStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headingStack.heightAnchor.constraint(equalToConstant: 24),
            searchSurface.topAnchor.constraint(equalTo: headingStack.bottomAnchor, constant: 12),
            searchSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            searchSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            searchSurface.heightAnchor.constraint(equalToConstant: 40),
            glyph.leadingAnchor.constraint(equalTo: searchSurface.leadingAnchor, constant: 12),
            glyph.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            searchField.centerYAnchor.constraint(equalTo: searchSurface.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchSurface.trailingAnchor, constant: -12),

            topDivider.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 16),
            topDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -8),

            emptyState.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 12),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -12),

            bottomDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomDivider.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -46),

            footer.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            footer.centerYAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: 23),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
        ])
        if onCreate != nil {
            let createButton = makeCreateButton()
            content.addSubview(createButton)
            NSLayoutConstraint.activate([
                createButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                createButton.centerYAnchor.constraint(equalTo: headingStack.centerYAnchor),
                headingStack.trailingAnchor.constraint(lessThanOrEqualTo: createButton.leadingAnchor, constant: -12),
            ])
        } else {
            headingStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20).isActive = true
        }
    }

    private func makeCreateButton() -> NSButton {
        let button = NSButton(title: createActionTitle, target: self, action: #selector(createItem))
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .controlAccentColor
        button.toolTip = "\(createActionTitle)（⌘N）"
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    @objc private func createItem() { onCreate?() }

    private func buildFooter() -> NSView {
        var groups: [NSView] = []
        for (index, hint) in footerHints.enumerated() {
            if footerSeparatorIndex == index {
                let separator = UIStyle.separator()
                separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
                separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
                groups.append(separator)
            }
            let cap = PillView(text: hint.cap, font: .systemFont(ofSize: 11, weight: .medium),
                               textColor: .secondaryLabelColor, fill: UIStyle.surface, stroke: UIStyle.border)
            let lbl = NSTextField(labelWithString: hint.text)
            lbl.font = .systemFont(ofSize: 11)
            lbl.textColor = .secondaryLabelColor
            let s = NSStackView(views: [cap, lbl])
            s.orientation = .horizontal
            s.alignment = .centerY
            s.spacing = 5
            groups.append(s)
            footerGroups.append(s)
        }
        let footer = NSStackView(views: groups)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        return footer
    }

    private func updateFooterState() {
        let selected = tableView?.selectedRow ?? -1
        let row = rows.indices.contains(selected) ? rows[selected] : nil
        for (hint, group) in zip(footerHints, footerGroups) {
            let enabled: Bool
            switch hint.cap {
            case "↩", "⌘⌫", "⌘E": enabled = row != nil
            case "⌘S": enabled = row?.canSaveAsSnippet == true
            default: enabled = true
            }
            group.alphaValue = enabled ? 1 : 0.4
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        searchSurface.border = .controlAccentColor.withAlphaComponent(0.45)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        searchSurface.border = UIStyle.border
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooterState() }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    private func installDeleteMonitor() {
        guard deleteMonitor == nil,
              (onCreate != nil || onDelete != nil || onEditRow != nil || onSaveRow != nil) else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.window.isKeyWindow else { return e }
            let actionModifiers = e.modifierFlags.intersection([.command, .control, .option, .shift])
            if actionModifiers == .command, Int(e.keyCode) == kVK_ANSI_N, let onCreate = self.onCreate {
                onCreate()
                return nil
            }
            let row = self.tableView.selectedRow
            guard row >= 0, row < self.rows.count else { return e }
            if e.modifierFlags.contains(.command), Int(e.keyCode) == kVK_Delete {
                self.onDelete?(row)
                self.reload(preserveSelection: true)
                return nil
            }
            if actionModifiers == .command, e.charactersIgnoringModifiers == "e", let onEdit = self.onEditRow {
                onEdit(row)
                return nil
            }
            if actionModifiers == .command, Int(e.keyCode) == kVK_ANSI_S, let onSave = self.onSaveRow {
                onSave(row)
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
        let target = hide()
        AutoPaste.deliver(to: target)
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
        if isVisible, !isHiding { hide(reactivatePreviousApplication: false) }
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
