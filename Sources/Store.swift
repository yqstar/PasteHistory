import Foundation

// MARK: - History store

final class HistoryStore {
    private(set) var items: [ClipItem] = []

    private static let maxItemsKey = "maxHistoryItems"
    private static let defaultMaxItems = 100
    private static let saveDelay: TimeInterval = 1.0

    var maxItems: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.maxItemsKey)
            return v > 0 ? v : Self.defaultMaxItems
        }
        set {
            let clamped = max(10, min(newValue, 10000))
            guard clamped != maxItems else { return }
            UserDefaults.standard.set(clamped, forKey: Self.maxItemsKey)
            if trim() {
                scheduleSave()
                notifyChange()
            }
        }
    }

    let baseDir: URL
    let imagesDir: URL
    let dbURL: URL
    private var pendingSave: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.local.pastehistory.history-store",
                                        qos: .utility)

    init() {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = appSup.appendingPathComponent("PasteHistory", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        dbURL = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: dbURL)
            items = try dec.decode([ClipItem].self, from: data)
            if trim() { save() }
        } catch {
            NSLog("[PasteHistory] history load failed: %@", error.localizedDescription)
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let destination = dbURL
        ioQueue.async {
            Self.write(snapshot, to: destination, label: "history")
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let destination = dbURL
        ioQueue.sync {
            Self.write(snapshot, to: destination, label: "history")
        }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL, label: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            let data = try enc.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[PasteHistory] %@ save failed: %@", label, error.localizedDescription)
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    func add(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0.contentMatches(item) }) {
            var existing = items.remove(at: idx)
            existing.date = item.date
            items.insert(existing, at: 0)
            if let f = item.imageFile, f != existing.imageFile {
                try? FileManager.default.removeItem(at: imageURL(f))
            }
        } else {
            items.insert(item, at: 0)
        }
        _ = trim()
        scheduleSave()
        notifyChange()
    }

    func bump(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        var it = items.remove(at: idx)
        it.date = Date()
        items.insert(it, at: 0)
        scheduleSave()
        notifyChange()
    }

    func delete(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: idx)
        if let f = removed.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        save()
        notifyChange()
    }

    func clear() {
        for it in items where it.imageFile != nil {
            try? FileManager.default.removeItem(at: imageURL(it.imageFile!))
        }
        items.removeAll()
        save()
        notifyChange()
    }

    @discardableResult
    private func trim() -> Bool {
        let limit = maxItems
        guard items.count > limit else { return false }
        while items.count > limit {
            let removed = items.removeLast()
            if let f = removed.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        }
        return true
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .historyDidChange, object: self)
    }
}

// MARK: - Snippet store

final class SnippetStore {
    enum ImportMode {
        case merge
        case replace
    }

    struct ImportSummary {
        let total: Int
        let added: Int
        let updated: Int
        let skipped: Int
        let replaced: Int
    }

    private(set) var items: [Snippet] = []
    private static let saveDelay: TimeInterval = 0.5
    private let url: URL
    private var pendingSave: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "com.local.pastehistory.snippet-store",
                                        qos: .utility)

    init(baseDir: URL) {
        url = baseDir.appendingPathComponent("snippets.json")
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            items = try JSONDecoder().decode([Snippet].self, from: data)
        } catch {
            NSLog("[PasteHistory] snippet load failed: %@", error.localizedDescription)
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let destination = url
        ioQueue.async {
            Self.write(snapshot, to: destination)
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = items
        let destination = url
        ioQueue.sync {
            Self.write(snapshot, to: destination)
        }
    }

    private static func write(_ snippets: [Snippet], to url: URL) {
        do {
            let data = try encoder().encode(snippets)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[PasteHistory] snippet save failed: %@", error.localizedDescription)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    func decodeImportData(_ data: Data) throws -> [Snippet] {
        try JSONDecoder().decode([Snippet].self, from: data)
    }

    func exportData() throws -> Data {
        try Self.encoder().encode(items)
    }

    @discardableResult
    func importItems(_ imported: [Snippet], mode: ImportMode) -> ImportSummary {
        var seen = Set<UUID>()
        let unique = imported.filter { seen.insert($0.id).inserted }
        let skipped = imported.count - unique.count
        let previousCount = items.count

        let summary: ImportSummary
        switch mode {
        case .merge:
            let existingIDs = Set(items.map(\.id))
            let importedIDs = Set(unique.map(\.id))
            let added = unique.lazy.filter { !existingIDs.contains($0.id) }.count
            let updated = unique.count - added
            items = unique + items.filter { !importedIDs.contains($0.id) }
            summary = ImportSummary(total: items.count, added: added, updated: updated,
                                    skipped: skipped, replaced: 0)
        case .replace:
            items = unique
            summary = ImportSummary(total: items.count, added: items.count, updated: 0,
                                    skipped: skipped, replaced: previousCount)
        }

        save()
        NotificationCenter.default.post(name: .snippetsDidChange, object: self)
        return summary
    }

    @discardableResult
    func add(title: String = "新片段", content: String = "") -> Snippet {
        let s = Snippet(id: UUID(), title: title, content: content)
        items.insert(s, at: 0)
        save()
        NotificationCenter.default.post(name: .snippetsDidChange, object: self)
        return s
    }

    func update(_ snippet: Snippet) {
        guard let i = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        items.remove(at: i)
        items.insert(snippet, at: 0)
        save()
        NotificationCenter.default.post(name: .snippetsDidChange, object: self)
    }

    func bump(id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), i != 0 else { return }
        let snippet = items.remove(at: i)
        items.insert(snippet, at: 0)
        scheduleSave()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        save()
        NotificationCenter.default.post(name: .snippetsDidChange, object: self)
    }
}
