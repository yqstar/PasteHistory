import Cocoa

// Both menu headings share a trailing shortcut column, independent of count or key length.
func menuHeaderTitles(_ headers: [(title: String, count: Int, hotkey: String)]) -> [NSAttributedString] {
    let hotkeyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let labels = headers.map { header in
        let label = NSMutableAttributedString(string: header.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        label.append(NSAttributedString(string: "  \(header.count)", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return label
    }
    let shortcuts = headers.map { NSAttributedString(string: $0.hotkey, attributes: hotkeyAttributes) }
    let columnEnd = ceil((labels.map { $0.size().width }.max() ?? 0) + 28 +
                         (shortcuts.map { $0.size().width }.max() ?? 0))
    let paragraph = NSMutableParagraphStyle()
    paragraph.tabStops = [NSTextTab(textAlignment: .right, location: columnEnd)]

    return zip(labels, shortcuts).map { label, shortcut in
        label.append(NSAttributedString(string: "\t", attributes: hotkeyAttributes))
        label.append(shortcut)
        label.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: label.length))
        return label
    }
}
