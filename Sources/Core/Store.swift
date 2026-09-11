import Foundation
import Carbon.HIToolbox

private enum JSONStorage {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("bak")
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL,
                                   decoder: JSONDecoder, label: String) -> (T?, String?) {
        let fm = FileManager.default
        let backup = backupURL(for: url)
        guard fm.fileExists(atPath: url.path) else {
            guard fm.fileExists(atPath: backup.path) else { return (nil, nil) }
            do {
                let data = try Data(contentsOf: backup)
                let recovered = try decoder.decode(type, from: data)
                try data.write(to: url, options: .atomic)
                return (recovered, "\(label)主文件缺失，已从备份恢复")
            } catch {
                return (nil, "\(label)主文件缺失，且无法读取备份：\(error.localizedDescription)")
            }
        }
        do {
            return (try decoder.decode(type, from: Data(contentsOf: url)), nil)
        } catch {
            let originalError = error.localizedDescription
            let quarantined = quarantine(url)
            if fm.fileExists(atPath: backup.path),
               let data = try? Data(contentsOf: backup),
               let recovered = try? decoder.decode(type, from: data) {
                do {
                    try data.write(to: url, options: .atomic)
                    let location = quarantined?.lastPathComponent ?? url.lastPathComponent
                    return (recovered, "\(label)数据损坏，已从备份恢复；原文件保留为 \(location)")
                } catch {
                    return (recovered, "\(label)数据损坏，已读取备份但无法恢复主文件：\(error.localizedDescription)")
                }
            }
            let location = quarantined?.lastPathComponent ?? url.lastPathComponent
            return (nil, "无法读取\(label)数据（\(originalError)）；原文件保留为 \(location)")
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL,
                                    encoder: JSONEncoder) throws {
        let fm = FileManager.default
        let data = try encoder.encode(value)
        if fm.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            try previous.write(to: backupURL(for: url), options: .atomic)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func quarantine(_ url: URL) -> URL? {
        let fm = FileManager.default
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let name = ext.isEmpty ? "\(stem).corrupt-\(suffix)" : "\(stem).corrupt-\(suffix).\(ext)"
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try fm.moveItem(at: url, to: destination)
            return destination
        } catch {
            NSLog("[PasteHistory] unable to quarantine %@: %@", url.lastPathComponent,
                  error.localizedDescription)
            return nil
        }
    }
}

// Serializes writes and coalesces pending snapshots for both stores.
private final class JSONFile<Value: Codable & Equatable> {
    var initialValue: Value?
    let startupWarning: String?
    var onError: ((String) -> Void)?

    private let url: URL
    private let label: String
    private let saveDelay: TimeInterval
    private let ioQueue: DispatchQueue
    private var pendingSave: DispatchWorkItem?
    // Accessed only on ioQueue after initialization.
    private var lastWrittenValue: Value?

    init(url: URL, label: String, saveDelay: TimeInterval) {
        self.url = url
        self.label = label
        self.saveDelay = saveDelay
        ioQueue = DispatchQueue(label: "com.local.pastehistory.\(url.lastPathComponent)", qos: .utility)
        var warnings: [String] = []
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            warnings.append("无法创建\(label)数据目录：\(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = JSONStorage.load(Value.self, from: url, decoder: decoder, label: label)
        initialValue = result.0
        if let warning = result.1 { warnings.append(warning) }
        startupWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        if let startupWarning { NSLog("[PasteHistory] %@", startupWarning) }
        // A failed recovery may have loaded a backup without repairing the main file.
        lastWrittenValue = result.1 == nil ? result.0 : nil
    }

    func scheduleSave(_ value: Value) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save(value) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    func save(_ value: Value) {
        cancelPendingSave()
        ioQueue.async { [self] in
            do { try write(value) }
            catch { report(error) }
        }
    }

    func commit(_ value: Value) throws {
        cancelPendingSave()
        try ioQueue.sync { try write(value) }
    }

    func flush(_ value: Value) {
        do { try commit(value) }
        catch { report(error) }
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func write(_ value: Value) throws {
        guard lastWrittenValue != value else { return }
        try JSONStorage.write(value, to: url, encoder: JSONStorage.encoder())
        lastWrittenValue = value
    }

    private func report(_ error: Error) {
        let message = "无法保存\(label)：\(error.localizedDescription)"
        NSLog("[PasteHistory] %@", message)
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }
}

// MARK: - History store

final class HistoryStore {
    private(set) var items: [ClipItem] = []
    private(set) var startupWarning: String?
    var onPersistenceError: ((String) -> Void)? {
        get { file.onError }
        set { file.onError = newValue }
    }

    private static let maxItemsKey = "maxHistoryItems"
    static let defaultMaxItems = 100
    static let maxItemsRange = 10...500
    private let defaults: UserDefaults

    var maxItems: Int {
        get {
            let value = defaults.integer(forKey: Self.maxItemsKey)
            guard value > 0 else { return Self.defaultMaxItems }
            return Self.clampedMaxItems(value)
        }
        set {
            let clamped = Self.clampedMaxItems(newValue)
            guard clamped != defaults.integer(forKey: Self.maxItemsKey) else { return }
            defaults.set(clamped, forKey: Self.maxItemsKey)
            if trim() {
                file.scheduleSave(items)
                notifyChange()
            }
        }
    }

    static func clampedMaxItems(_ value: Int) -> Int {
        min(max(value, maxItemsRange.lowerBound), maxItemsRange.upperBound)
    }

    let baseDir: URL
    private let imagesDir: URL
    private let file: JSONFile<[ClipItem]>

    init(baseDir customBaseDir: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = customBaseDir ?? appSup.appendingPathComponent("PasteHistory", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        file = JSONFile(url: baseDir.appendingPathComponent("history.json"), label: "历史记录", saveDelay: 1)
        startupWarning = file.startupWarning
        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        } catch {
            startupWarning = [startupWarning, "无法创建图片目录：\(error.localizedDescription)"]
                .compactMap { $0 }.joined(separator: "\n")
        }
        items = file.initialValue ?? []
        file.initialValue = nil
        if trim() { file.save(items) }
    }

    func flush() { file.flush(items) }

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    func add(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0.contentMatches(item) }) {
            var existing = items.remove(at: idx)
            existing.date = item.date
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        _ = trim()
        file.scheduleSave(items)
        notifyChange()
    }

    func bump(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        var it = items.remove(at: idx)
        it.date = Date()
        items.insert(it, at: 0)
        file.scheduleSave(items)
        notifyChange()
    }

    func delete(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: idx)
        if let f = removed.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        file.save(items)
        notifyChange()
    }

    func clear() {
        for name in items.compactMap(\.imageFile) {
            try? FileManager.default.removeItem(at: imageURL(name))
        }
        items.removeAll()
        file.save(items)
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

    enum AddResult {
        case added(Snippet)
        case duplicate(Snippet)
    }

    enum StoreError: LocalizedError {
        case emptyContent
        case snippetNotFound
        case duplicateContent(Snippet)
        case invalidHotKey(String)
        case duplicateHotKey(String)
        case emptyImport
        case persistence(String)

        var errorDescription: String? {
            switch self {
            case .emptyContent:
                return "片段正文不能为空"
            case .snippetNotFound:
                return "该片段已被删除或替换，当前修改尚未保存"
            case .duplicateContent(let existing):
                return "相同正文已存在于片段“\(existing.title)”"
            case .invalidHotKey(let title):
                return "片段“\(title)”包含无效快捷键"
            case .duplicateHotKey(let display):
                return "导入数据中存在重复快捷键 \(display)"
            case .emptyImport:
                return "导入文件中没有片段"
            case .persistence(let message):
                return message
            }
        }
    }

    struct ImportSummary {
        let total: Int
        let added: Int
        let updated: Int
        let skipped: Int
        let replaced: Int
    }

    private(set) var items: [Snippet] = []
    private(set) var startupWarning: String?
    var onPersistenceError: ((String) -> Void)? {
        get { file.onError }
        set { file.onError = newValue }
    }
    private let file: JSONFile<[Snippet]>

    init(baseDir: URL) {
        file = JSONFile(url: baseDir.appendingPathComponent("snippets.json"), label: "片段", saveDelay: 0.5)
        items = file.initialValue ?? []
        file.initialValue = nil
        startupWarning = file.startupWarning
    }

    func flush() { file.flush(items) }

    private func commit(_ newItems: [Snippet]) throws {
        do {
            try file.commit(newItems)
        } catch {
            throw StoreError.persistence("无法保存片段：\(error.localizedDescription)")
        }
        items = newItems
        NotificationCenter.default.post(name: .snippetsDidChange, object: self)
    }

    private static func normalized(_ snippet: Snippet, validateHotKey: Bool = false) throws -> Snippet {
        guard !snippet.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoreError.emptyContent
        }
        var result = snippet
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.title = title.isEmpty ? "未命名" : title
        if validateHotKey, let hotKey = result.hotKey {
            let required = UInt32(cmdKey | optionKey | controlKey)
            guard hotKey.keyCode <= 127,
                  hotKey.carbonModifiers & required != 0,
                  !hotKey.display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StoreError.invalidHotKey(result.title)
            }
        }
        return result
    }

    func exportData() throws -> Data {
        try JSONStorage.encoder().encode(items)
    }

    @discardableResult
    func importItems(_ imported: [Snippet], mode: ImportMode) throws -> ImportSummary {
        guard !imported.isEmpty else { throw StoreError.emptyImport }

        var seenIDs = Set<UUID>()
        var seenContents = Set<String>()
        var seenHotKeys = Set<String>()
        var unique: [Snippet] = []
        var skipped = 0

        for raw in imported {
            let snippet = try Self.normalized(raw, validateHotKey: true)
            guard seenIDs.insert(snippet.id).inserted,
                  seenContents.insert(snippet.content).inserted else {
                skipped += 1
                continue
            }
            if let hotKey = snippet.hotKey {
                let identity = "\(hotKey.keyCode):\(hotKey.carbonModifiers)"
                guard seenHotKeys.insert(identity).inserted else {
                    throw StoreError.duplicateHotKey(hotKey.display)
                }
            }
            unique.append(snippet)
        }

        let previousCount = items.count
        let newItems: [Snippet]
        let summary: ImportSummary
        switch mode {
        case .merge:
            let existingIDs = Set(items.map(\.id))
            let existingContentOwners = Dictionary(items.map { ($0.content, $0.id) },
                                                   uniquingKeysWith: { first, _ in first })
            var accepted: [Snippet] = []
            for snippet in unique {
                if let owner = existingContentOwners[snippet.content], owner != snippet.id {
                    skipped += 1
                } else {
                    accepted.append(snippet)
                }
            }
            let importedIDs = Set(accepted.map(\.id))
            let added = accepted.lazy.filter { !existingIDs.contains($0.id) }.count
            let updated = accepted.count - added
            newItems = accepted + items.filter { !importedIDs.contains($0.id) }
            summary = ImportSummary(total: newItems.count, added: added, updated: updated,
                                    skipped: skipped, replaced: 0)
        case .replace:
            newItems = unique
            summary = ImportSummary(total: newItems.count, added: newItems.count, updated: 0,
                                    skipped: skipped, replaced: previousCount)
        }

        if newItems != items { try commit(newItems) }
        return summary
    }

    @discardableResult
    func add(title: String = "新片段", content: String) throws -> AddResult {
        let snippet = try Self.normalized(Snippet(id: UUID(), title: title, content: content))
        if let existing = items.first(where: { $0.content == snippet.content }) {
            return .duplicate(existing)
        }
        try commit([snippet] + items)
        return .added(snippet)
    }

    func update(_ snippet: Snippet) throws {
        guard let index = items.firstIndex(where: { $0.id == snippet.id }) else {
            throw StoreError.snippetNotFound
        }
        let normalized = try Self.normalized(snippet)
        if let existing = items.first(where: { $0.id != normalized.id && $0.content == normalized.content }) {
            throw StoreError.duplicateContent(existing)
        }
        var newItems = items
        newItems.remove(at: index)
        newItems.insert(normalized, at: 0)
        try commit(newItems)
    }

    func bump(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let snippet = items.remove(at: index)
        items.insert(snippet, at: 0)
        file.scheduleSave(items)
    }

    func delete(id: UUID) throws {
        guard items.contains(where: { $0.id == id }) else { return }
        try commit(items.filter { $0.id != id })
    }

}
