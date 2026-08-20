import Cocoa

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
            var s = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.replacingOccurrences(of: "\n", with: " ")
                 .replacingOccurrences(of: "\t", with: " ")
            if s.count > max { s = String(s.prefix(max)) + "…" }
            return s
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

let timeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f
}()
func timeStr(_ d: Date) -> String { timeFmt.string(from: d) }

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
    return timeStr(d)
}

func kindLabel(_ k: ClipKind) -> String {
    switch k {
    case .text: return "文本"
    case .image: return "图片"
    case .file: return "文件"
    }
}

func kindColor(_ k: ClipKind) -> NSColor {
    switch k {
    case .text: return .systemBlue
    case .image: return .systemPurple
    case .file: return .systemTeal
    }
}

func matchesQuery(_ text: String, _ query: String) -> Bool {
    if text.localizedCaseInsensitiveContains(query) { return true }
    let mutable = NSMutableString(string: text) as CFMutableString
    CFStringTransform(mutable, nil, kCFStringTransformToLatin, false)
    CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
    return (mutable as String).localizedCaseInsensitiveContains(query)
}
