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
