import Foundation
import CoreFoundation

// MARK: - Notifications

extension Notification.Name {
    static let historyDidChange = Notification.Name("PH.historyDidChange")
    static let snippetsDidChange = Notification.Name("PH.snippetsDidChange")
}

// MARK: - Model

enum ClipKind: String, Codable {
    case text
    case image
    case file
}

struct ClipItem: Codable, Equatable {
    var id: UUID
    var kind: ClipKind
    var text: String?
    var imageFile: String?
    var date: Date

    func contentMatches(_ other: ClipItem) -> Bool {
        if kind != other.kind { return false }
        if kind == .image { return false }
        return text == other.text
    }

    func oneLine(_ max: Int = 200) -> String {
        switch kind {
        case .image:
            return "图片"
        case .file:
            let parts = (text ?? "").components(separatedBy: "\n")
            let base = parts.first.map { ($0 as NSString).lastPathComponent } ?? "文件"
            return parts.count > 1 ? "\(base) 等 \(parts.count) 项" : base
        case .text:
            return oneLinePreview(text ?? "", limit: max)
        }
    }
}

struct Snippet: Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var hotKey: HotKeyConfig?
}

enum SnippetKind {
    case url, code, text

    var label: String {
        switch self {
        case .url: return "链接"
        case .code: return "代码"
        case .text: return "文本"
        }
    }
}

func snippetKind(of content: String) -> SnippetKind {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .text }
    let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? trimmed
    let lower = firstLine.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") {
        return .url
    }
    let codeMarkers: [Character] = ["{", "}", ";", "<", ">"]
    if trimmed.contains(where: { codeMarkers.contains($0) }) { return .code }
    let kws = ["func ", "def ", "class ", "import ", "#include", "function ", "=>", "var ", "let ",
               "const ", "return ", "public ", "private ", "if (", "for (", "while ("]
    if kws.contains(where: { lower.contains($0) }) { return .code }
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count >= 2 && lines.contains(where: { $0.first == " " || $0.first == "\t" }) {
        return .code
    }
    return .text
}

// MARK: - Helpers

struct TextStatistics {
    let lineCount: Int
    let characterCount: Int

    init(_ text: String) {
        var lines = 1
        var characters = 0
        for character in text {
            characters += 1
            if character.isNewline { lines += 1 }
        }
        lineCount = characters == 0 ? 0 : lines
        characterCount = characters
    }
}

func oneLinePreview(_ text: String, limit: Int) -> String {
    let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit + 1)
    let line = String(prefix.prefix(limit).map { $0.isNewline || $0 == "\t" ? Character(" ") : $0 })
    return prefix.count > limit ? line + "…" : line
}

private let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f
}()

private let hourMinFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

func relativeTime(_ d: Date) -> String {
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(Int(s / 60)) 分钟前" }
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "\(Int(s / 3600)) 小时前" }
    if cal.isDateInYesterday(d) { return "昨天 " + hourMinFmt.string(from: d) }
    return timeFmt.string(from: d)
}

func kindLabel(_ k: ClipKind) -> String {
    switch k {
    case .text: return "文本"
    case .image: return "图片"
    case .file: return "文件"
    }
}

private let transliterationCache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 1_024
    cache.totalCostLimit = 8 * 1_024 * 1_024
    return cache
}()

func matchesQuery(_ text: String, _ query: String) -> Bool {
    if text.localizedCaseInsensitiveContains(query) { return true }
    guard text.unicodeScalars.contains(where: { !$0.isASCII }) else { return false }
    let key = text as NSString
    if let cached = transliterationCache.object(forKey: key) {
        return (cached as String).localizedCaseInsensitiveContains(query)
    }
    let mutable = NSMutableString(string: text) as CFMutableString
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    let transformed = mutable as String
    transliterationCache.setObject(transformed as NSString, forKey: key,
                                   cost: (text.utf16.count + transformed.utf16.count) * 2)
    return transformed.localizedCaseInsensitiveContains(query)
}

func restoredSelectionIndex(previousID: UUID?, previousIndex: Int,
                            newIDs: [UUID]) -> Int? {
    guard !newIDs.isEmpty else { return nil }
    if let previousID, let index = newIDs.firstIndex(of: previousID) {
        return index
    }
    return min(max(previousIndex, 0), newIDs.count - 1)
}
