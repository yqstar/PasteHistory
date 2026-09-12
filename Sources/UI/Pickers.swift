import Cocoa

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
        let statistics = TextStatistics(content)
        var parts: [String] = []
        if statistics.lineCount > 1 { parts.append("\(statistics.lineCount) 行") }
        parts.append("\(statistics.characterCount) 字符")
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
