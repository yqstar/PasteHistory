import Cocoa
import ImageIO

// Platform-specific presentation stays out of the data models.
extension SnippetKind {
    var color: NSColor {
        switch self {
        case .url: return .systemTeal
        case .code: return .systemIndigo
        case .text: return .systemBlue
        }
    }

    var symbolName: String {
        switch self {
        case .url: return "link"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "text.alignleft"
        }
    }
}

func kindColor(_ kind: ClipKind) -> NSColor {
    switch kind {
    case .text: return .systemBlue
    case .image: return .systemPurple
    case .file: return .systemTeal
    }
}

// Keep reading surfaces opaque; reserve native materials for window chrome.
enum UIStyle {
    static let canvas = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.115, alpha: 1)
            : NSColor(white: 0.96, alpha: 1)
    }
    static let surface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.155, alpha: 1)
            : .white
    }
    static let border = NSColor(name: nil) { appearance in
        var color = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            color = .labelColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.45 : 0.08)
        }
        return color
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
    private var accessibilityObserver: NSObjectProtocol?

    init(fill: NSColor = UIStyle.surface, border: NSColor = .clear, radius: CGFloat = 12) {
        self.fill = fill
        self.border = border
        self.radius = radius
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

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

/// Native window material with an opaque fallback for accessibility preferences.
final class ChromeView: NSVisualEffectView {
    private var accessibilityObserver: NSObjectProtocol?
    private let backing = SurfaceView(radius: 0)

    init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(backing)
        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: topAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        updateAccessibility()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateAccessibility() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    private var usesOpaqueBackground: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ||
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    private func updateAccessibility() {
        // Explicit fallback also covers systems that keep vibrant text enabled.
        state = usesOpaqueBackground ? .inactive : .followsWindowActiveState
        if usesOpaqueBackground {
            backing.fill = UIStyle.canvas
        } else {
            // A light tint keeps the toolbar quiet while preserving the native backdrop.
            backing.fill = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? .clear : .white.withAlphaComponent(0.4)
            }
        }
    }
}

/// A single field-level focus ring, including its padding, for borderless editors.
final class InputSurfaceView: SurfaceView {
    weak var focusTarget: NSView?
    private var windowObserver: NSObjectProtocol?
    private var isFocused = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.updateFocus() }
        }
        updateFocus()
    }

    deinit {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    private func updateFocus() {
        let responder = window?.firstResponder
        let editor = (focusTarget as? NSTextField)?.currentEditor()
        let focused = window?.isKeyWindow == true && responder != nil &&
            (responder === focusTarget || (editor != nil && responder === editor))
        if focused != isFocused {
            isFocused = focused
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isFocused {
            NSColor.keyboardFocusIndicatorColor.withAlphaComponent(
                NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.4
            ).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            path.lineWidth = 2
            path.stroke()
        }
    }
}

final class SymbolTileView: SurfaceView {
    init(_ name: String, color: NSColor, size: CGFloat = 28) {
        super.init(fill: color.withAlphaComponent(0.1), radius: size * 0.26)
        let icon = UIStyle.symbol(name, size: size * 0.52, color: UIStyle.readableTint(color))
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: size * 0.65),
            icon.heightAnchor.constraint(equalToConstant: size * 0.65),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
