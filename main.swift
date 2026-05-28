import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Global hotkey (Carbon — no Accessibility permission needed)

private func fourCharCode(_ s: String) -> OSType {
    var result: OSType = 0
    for ch in s.utf8.prefix(4) { result = (result << 8) + OSType(ch) }
    return result
}

/// Manages any number of global hotkeys via a single shared Carbon event handler,
/// dispatching by EventHotKeyID. (One handler per hotkey would make every handler
/// fire on every hotkey press.)
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var callbacks: [UInt32: () -> Void] = [:] // id -> action
    private var refs: [UInt32: EventHotKeyRef] = [:]   // id -> registration
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event = event else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if err == noErr { HotKeyCenter.shared.fire(id: hkID.id) }
            return noErr
        }, 1, &eventType, nil, nil)
        installed = true
    }

    fileprivate func fire(id: UInt32) {
        callbacks[id]?()
    }

    /// Registers a hotkey; returns a token to unregister it, or nil if the combo is taken.
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("PHTY"), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else { return nil }
        refs[id] = ref
        callbacks[id] = callback
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        callbacks[id] = nil
    }
}

/// A button that records a global-hotkey combo: click it, then press the combo.
final class HotKeyRecorderButton: NSButton {
    var placeholder = "未设置"
    var config: HotKeyConfig? { didSet { if !recording { updateTitle() } } }
    /// Called with a captured combo; return true to accept it. Not called for Esc/invalid.
    var onChange: ((HotKeyConfig) -> Bool)?
    /// Feedback messages during recording.
    var onStatus: ((String) -> Void)?

    private var recording = false
    private var monitor: Any?

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        translatesAutoresizingMaskIntoConstraints = false
        updateTitle()
    }

    private func updateTitle() {
        title = recording ? "按下组合键…" : (config?.display ?? placeholder)
    }

    @objc private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        updateTitle()
        onStatus?("正在录制：请按下组合键（Esc 取消）")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            self?.handle(e)
            return nil // swallow while recording
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        updateTitle()
    }

    private func handle(_ e: NSEvent) {
        if Int(e.keyCode) == kVK_Escape { stop(); onStatus?("已取消"); return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
            onStatus?("组合键需包含 ⌘ / ⌥ / ⌃ 之一")
            return
        }
        let cfg = HotKeyConfig(keyCode: UInt32(e.keyCode),
                               carbonModifiers: carbonModifiers(from: flags),
                               display: hotKeyDisplay(flags: flags, keyCode: e.keyCode,
                                                      characters: e.charactersIgnoringModifiers))
        if onChange?(cfg) == true {
            config = cfg
            stop()
            onStatus?("已设置为 \(cfg.display)")
        } else {
            onStatus?("「\(cfg.display)」被占用，换一个")
        }
    }
}

// MARK: - Hotkey configuration (persisted in UserDefaults)

struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32         // virtual key code
    var carbonModifiers: UInt32 // Carbon modifier mask
    var display: String         // human-readable, e.g. "⌘⇧V"

    /// Default for summoning the history palette.
    static let historyDefault = HotKeyConfig(keyCode: UInt32(kVK_ANSI_V),
                                             carbonModifiers: UInt32(cmdKey | shiftKey),
                                             display: "⌘⇧V")
    /// Default for summoning the snippet picker.
    static let snippetDefault = HotKeyConfig(keyCode: UInt32(kVK_ANSI_S),
                                             carbonModifiers: UInt32(cmdKey | shiftKey),
                                             display: "⌘⇧S")

    private static let historyKey = "hotKeyConfig"
    private static let snippetKey = "snippetSummonHotKey"

    /// Persisted summon hotkey for the history palette.
    static var history: HotKeyConfig {
        get { load(historyKey) ?? historyDefault }
        set { store(newValue, historyKey) }
    }
    /// Persisted summon hotkey for the snippet picker.
    static var snippet: HotKeyConfig {
        get { load(snippetKey) ?? snippetDefault }
        set { store(newValue, snippetKey) }
    }

    private static func load(_ key: String) -> HotKeyConfig? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotKeyConfig.self, from: data)
    }
    private static func store(_ value: HotKeyConfig, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    return m
}

private let specialKeyNames: [Int: String] = [
    kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
    kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
]

func hotKeyDisplay(flags: NSEvent.ModifierFlags, keyCode: UInt16, characters: String?) -> String {
    var s = ""
    if flags.contains(.control) { s += "⌃" }
    if flags.contains(.option)  { s += "⌥" }
    if flags.contains(.shift)   { s += "⇧" }
    if flags.contains(.command) { s += "⌘" }
    if let name = specialKeyNames[Int(keyCode)] {
        s += name
    } else if let c = characters, let first = c.first,
              first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol {
        s += c.uppercased()
    } else {
        s += "Key\(keyCode)"
    }
    return s
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

/// Human-friendly relative time: 刚刚 / N 分钟前 / N 小时前 / 昨天 HH:mm / MM-dd HH:mm.
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

/// Accent color per content kind, used for tinted icons and pill badges.
func kindColor(_ k: ClipKind) -> NSColor {
    switch k {
    case .text: return .systemBlue
    case .image: return .systemPurple
    case .file: return .systemTeal
    }
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
    var text: String?       // text content, or file paths joined by "\n"
    var imageFile: String?  // PNG filename in images dir
    var date: Date

    // Content-based equality (used for de-duplication). Images never dedupe.
    static func == (l: ClipItem, r: ClipItem) -> Bool {
        if l.kind != r.kind { return false }
        if l.kind == .image { return false }
        return l.text == r.text
    }

    /// Single-line preview, truncated.
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

// MARK: - Store

final class HistoryStore {
    private(set) var items: [ClipItem] = []
    let maxItems = 200

    let baseDir: URL
    let imagesDir: URL
    let dbURL: URL

    init() {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = appSup.appendingPathComponent("PasteHistory", isDirectory: true)
        imagesDir = baseDir.appendingPathComponent("images", isDirectory: true)
        dbURL = baseDir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: dbURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([ClipItem].self, from: data) {
            items = decoded
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(items) {
            try? data.write(to: dbURL, options: .atomic)
        }
    }

    func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    func add(_ item: ClipItem) {
        if let idx = items.firstIndex(where: { $0 == item }) {
            // duplicate content: move existing to front, refresh timestamp
            var existing = items.remove(at: idx)
            existing.date = item.date
            items.insert(existing, at: 0)
            // discard the freshly captured image file if any (not used)
            if let f = item.imageFile, f != existing.imageFile {
                try? FileManager.default.removeItem(at: imageURL(f))
            }
        } else {
            items.insert(item, at: 0)
        }
        trim()
        save()
    }

    func bump(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }), idx != 0 else { return }
        var it = items.remove(at: idx)
        it.date = Date()
        items.insert(it, at: 0)
        save()
    }

    func delete(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: idx)
        if let f = removed.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        save()
    }

    func clear() {
        for it in items where it.imageFile != nil {
            try? FileManager.default.removeItem(at: imageURL(it.imageFile!))
        }
        items.removeAll()
        save()
    }

    private func trim() {
        while items.count > maxItems {
            let removed = items.removeLast()
            if let f = removed.imageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        }
    }
}

// MARK: - Snippet store (reusable code/text fragments)

struct Snippet: Codable, Equatable {
    var id: UUID
    var title: String
    var content: String
    var hotKey: HotKeyConfig?   // optional per-snippet global hotkey (nil if unset)
}

final class SnippetStore {
    private(set) var items: [Snippet] = []
    private let url: URL

    init(baseDir: URL) {
        url = baseDir.appendingPathComponent("snippets.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Snippet].self, from: data) else { return }
        items = decoded
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    @discardableResult
    func add(title: String = "新片段", content: String = "") -> Snippet {
        let s = Snippet(id: UUID(), title: title, content: content)
        items.append(s)
        save()
        return s
    }

    func update(_ snippet: Snippet) {
        guard let i = items.firstIndex(where: { $0.id == snippet.id }) else { return }
        items[i] = snippet
        save()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }
}

// MARK: - Clipboard monitor

final class ClipboardMonitor {
    private let pb = NSPasteboard.general
    private var lastChange: Int
    private var timer: Timer?
    let store: HistoryStore
    var onCapture: ((ClipItem) -> Void)?

    init(store: HistoryStore) {
        self.store = store
        lastChange = pb.changeCount
    }

    func start() {
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Call right after we ourselves write to the pasteboard, so we don't re-capture our own write.
    func suppressNext() {
        lastChange = pb.changeCount
    }

    private func poll() {
        let c = pb.changeCount
        guard c != lastChange else { return }
        lastChange = c
        capture()
    }

    private func capture() {
        // 1. File URLs (Finder copy)
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: "\n")
            onCapture?(ClipItem(id: UUID(), kind: .file, text: paths, imageFile: nil, date: Date()))
            return
        }
        // 2. Image (screenshots, copied images) — read raw data directly (lossless, robust)
        if let fname = saveImageFromPasteboard() {
            onCapture?(ClipItem(id: UUID(), kind: .image, text: nil, imageFile: fname, date: Date()))
            return
        }
        // 3. Plain text
        if let str = pb.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCapture?(ClipItem(id: UUID(), kind: .text, text: str, imageFile: nil, date: Date()))
            return
        }
    }

    /// Pull image bytes straight off the pasteboard and persist as PNG.
    /// Prefers the native PNG data (no re-encode); falls back to converting TIFF.
    private func saveImageFromPasteboard() -> String? {
        let pngData: Data?
        if let png = pb.data(forType: .png) {
            pngData = png
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            pngData = png
        } else {
            pngData = nil
        }
        guard let data = pngData, !data.isEmpty else { return nil }
        let name = UUID().uuidString + ".png"
        do {
            try data.write(to: store.imageURL(name))
            return name
        } catch {
            return nil
        }
    }
}

// MARK: - Launch at login (LaunchAgent)

enum LaunchAgent {
    static let label = "com.local.pastehistory"

    static var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func executablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath()],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL)
            shell(["/bin/launchctl", "load", "-w", plistURL.path])
        }
    }

    static func disable() {
        shell(["/bin/launchctl", "unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func shell(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - Clipboard restore (shared)

func restoreToClipboard(_ item: ClipItem, store: HistoryStore) {
    let pb = NSPasteboard.general
    pb.clearContents()
    switch item.kind {
    case .text:
        pb.setString(item.text ?? "", forType: .string)
    case .file:
        let urls = (item.text ?? "").components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) as NSURL }
        if !urls.isEmpty { pb.writeObjects(urls) }
    case .image:
        if let f = item.imageFile, let img = NSImage(contentsOf: store.imageURL(f)) {
            pb.writeObjects([img])
        }
    }
}

// MARK: - Auto-paste (simulate ⌘V into the frontmost app)

/// Posts a synthetic ⌘V to whatever app is frontmost, so picking an item pastes it
/// directly instead of only landing on the clipboard. Requires Accessibility
/// permission (System Settings → Privacy & Security → Accessibility). When that
/// permission is missing we leave the content on the clipboard (manual ⌘V still
/// works) and prompt the user once to grant it.
enum AutoPaste {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    private static var didPrompt = false
    private static var didSecureAlert = false

    /// Caller must have already placed the content on the clipboard. After `delay`
    /// (time for our window to hide and the previous app to reactivate) this posts ⌘V.
    /// If we lack Accessibility permission, falls back to leaving content on the
    /// clipboard and shows a one-time alert explaining how to enable it.
    static func deliver(after delay: Double = 0.15) {
        if isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { postPaste() }
        } else {
            showPermissionAlertIfNeeded()
        }
    }

    private static func postPaste() {
        // Secure Keyboard Entry (Terminal/iTerm2 menu, or a focused password field
        // elsewhere) blocks ALL synthetic keystrokes system-wide. Detect it and
        // tell the user what's happening — otherwise the symptom is just "nothing
        // happens" with no clue why.
        if IsSecureEventInputEnabled() {
            showSecureInputAlertIfNeeded()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let cmd = CGKeyCode(kVK_Command)
        // Some apps (notably Terminal) don't react to a synthetic V with only
        // `flags = .maskCommand`; they want to see the modifier as an actual
        // ⌘ keydown/up around the V. Posting explicit modifier events is the
        // standard robust pattern and works universally (AppKit apps, Terminal,
        // Electron, etc.).
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: true)
        let vDown   = CGEvent(keyboardEventSource: src, virtualKey: v,   keyDown: true)
        let vUp     = CGEvent(keyboardEventSource: src, virtualKey: v,   keyDown: false)
        let cmdUp   = CGEvent(keyboardEventSource: src, virtualKey: cmd, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags   = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    /// Show our own alert at most once per launch — clearer than the cryptic system AX dialog,
    /// and offers a button that jumps straight to the right System Settings pane.
    private static func showPermissionAlertIfNeeded() {
        guard !didPrompt else { return }
        didPrompt = true
        // Defer so it doesn't run inside the current key event / hide animation.
        DispatchQueue.main.async { showPermissionAlert() }
    }

    /// Shown when Secure Keyboard Entry is on. Once per launch.
    private static func showSecureInputAlertIfNeeded() {
        guard !didSecureAlert else { return }
        didSecureAlert = true
        DispatchQueue.main.async {
            let a = NSAlert()
            a.messageText = "「安全键盘输入」开启中，无法自动粘贴"
            a.informativeText = """
                内容已写入剪贴板，可手动按 ⌘V 粘贴。

                Secure Keyboard Entry 会阻止任何 App 模拟按键，常见来源：
                  • iTerm2 顶部菜单 → 取消勾选「Secure Keyboard Entry」
                  • Terminal 顶部菜单 → 取消勾选「Secure Keyboard Entry」
                  • 当前焦点是密码字段（1Password、登录窗等）时系统会临时开启

                关闭后即可正常自动粘贴。
                """
            a.addButton(withTitle: "我知道了")
            a.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    private static func showPermissionAlert() {
        let a = NSAlert()
        a.messageText = "需要辅助功能权限来「自动粘贴」"
        a.informativeText = """
            内容已写入剪贴板，可手动按 ⌘V 粘贴。
            授权后回车将直接粘贴到当前 App。

            授权步骤：
              系统设置 → 隐私与安全性 → 辅助功能 → 勾选「粘贴历史」
            授权后通常立即生效；若没生效，请退出再重新打开 粘贴历史。
            """
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "稍后")
        a.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Search palette (shared Spotlight-style picker)

/// A small rounded label. Used both for outlined keyboard-cap footer hints and for
/// tinted type badges. Colors are resolved per-appearance so dark/light both look right.
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

struct PaletteRow {
    var icon: NSImage?
    var iconIsTemplate: Bool = true   // template = tinted SF Symbol; false = full-color thumbnail
    var iconTint: NSColor? = nil      // tint for template icons (nil → secondary label)
    var title: String
    var subtitle: String
    var badge: String? = nil          // trailing pill text
    var badgeColor: NSColor? = nil    // nil → neutral outlined pill; else tinted
    var accessoryBadge: String? = nil      // optional second pill, rendered to the right of badge
    var accessoryBadgeColor: NSColor? = nil
}

/// A row: tinted icon + title + secondary subtitle + optional trailing badge pill.
private final class PaletteCellView: NSTableCellView {
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

/// Reusable translucent picker: a large search field over a vibrant list, full keyboard
/// control (type to filter, ↑/↓ to move, ↩ to activate, esc to close), auto-dismiss on
/// losing focus. Used for both the paste history and the snippet picker.
final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                               NSTextFieldDelegate, NSWindowDelegate {
    var placeholder = "搜索…"
    var footerHints: [(cap: String, text: String)] = [("↩", "粘贴"), ("esc", "关闭")]
    var emptyText = "暂无内容"
    /// query -> rows to show.
    var provider: ((String) -> [PaletteRow])?
    /// User activated the row at this index (↩ / double-click). Place content on the
    /// clipboard here; the controller then hides and triggers auto-paste.
    var onActivate: ((Int) -> Void)?
    /// Optional: user pressed ⌘⌫ on the row at this index.
    var onDelete: ((Int) -> Void)?

    private var window: NSWindow!
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scroll: NSScrollView!
    private var emptyLabel: NSTextField!
    private var rows: [PaletteRow] = []
    private var query = ""
    private var deleteMonitor: Any?
    /// The app that was frontmost when we were summoned; we hand focus back to it
    /// on hide so the synthetic ⌘V lands there (more reliable than NSApp.hide(nil)).
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { window?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        if window == nil { build() }
        // Remember who had focus so we can hand it back on hide.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
        searchField.placeholderString = placeholder
        searchField.stringValue = ""
        query = ""
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        installDeleteMonitor()
    }

    /// Hide and return focus to whoever had it before us, so the synthetic ⌘V lands there.
    /// Explicitly reactivating the recorded app is more reliable than `NSApp.hide(nil)`
    /// alone — `hide` is async on accessory apps and iTerm2 in particular sometimes
    /// doesn't get refocused in time for the paste to land.
    func hide() {
        removeDeleteMonitor()
        window?.orderOut(nil)
        let prev = previousApp
        previousApp = nil
        if let prev = prev {
            // ignoringOtherApps is a no-op on macOS 14+ — pass empty options.
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

    /// Footer of outlined key-cap hints, e.g. ⌈↩⌋ 粘贴   ⌈esc⌋ 关闭.
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

    // ⌘⌫ deletes the selected row, without colliding with editing in the search field.
    private func installDeleteMonitor() {
        guard onDelete != nil, deleteMonitor == nil else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            if e.modifierFlags.contains(.command), Int(e.keyCode) == kVK_Delete {
                let row = self.tableView.selectedRow
                if row >= 0, row < self.rows.count {
                    self.onDelete?(row)
                    self.reload(preserveSelection: true)
                }
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
        onActivate?(row)
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

    // Keyboard control while typing in the search field.
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

    // Auto-dismiss when the picker loses focus (clicking elsewhere), Spotlight-style.
    func windowDidResignKey(_ notification: Notification) {
        if isVisible { hide() }
    }

    // Data source / delegate
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

// MARK: - History palette controller

final class HistoryWindowController {
    let store: HistoryStore
    let monitor: ClipboardMonitor
    var onChange: (() -> Void)?

    private let palette = PaletteController()
    private var filtered: [ClipItem] = []

    init(store: HistoryStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        palette.placeholder = "搜索粘贴历史…"
        palette.emptyText = "暂无历史，复制点东西试试"
        palette.footerHints = [("↩", "粘贴"), ("⌘⌫", "删除"), ("esc", "关闭")]
        palette.provider = { [weak self] q in self?.rows(for: q) ?? [] }
        palette.onActivate = { [weak self] i in self?.activate(i) }
        palette.onDelete = { [weak self] i in self?.deleteAt(i) }
    }

    func show() { palette.show() }
    func hide() { palette.hide() }
    func toggle() { palette.toggle() }
    func refreshIfVisible() { palette.reloadIfVisible() }

    private func rows(for query: String) -> [PaletteRow] {
        if query.isEmpty {
            filtered = store.items
        } else {
            let q = query.lowercased()
            filtered = store.items.filter {
                $0.oneLine(400).lowercased().contains(q) || kindLabel($0.kind).contains(q)
            }
        }
        return filtered.map { item in
            PaletteRow(icon: icon(for: item),
                       iconIsTemplate: item.kind != .image,
                       iconTint: kindColor(item.kind),
                       title: item.oneLine(120),
                       subtitle: relativeTime(item.date),
                       badge: kindLabel(item.kind),
                       badgeColor: kindColor(item.kind))
        }
    }

    private func icon(for item: ClipItem) -> NSImage? {
        if item.kind == .image, let f = item.imageFile,
           let img = NSImage(contentsOf: store.imageURL(f)) {
            return img
        }
        let sym = item.kind == .file ? "doc" : "text.alignleft"
        return NSImage(systemSymbolName: sym, accessibilityDescription: nil)
    }

    private func activate(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        let item = filtered[i]
        restoreToClipboard(item, store: store)
        monitor.suppressNext()
        store.bump(id: item.id)
        onChange?()
    }

    private func deleteAt(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        store.delete(id: filtered[i].id)
        onChange?()
    }
}

// MARK: - Snippet picker controller

/// Loose categorization for a snippet, used to drive icon + colored type pill so the
/// list visually mirrors the history palette's kind badges.
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
    // Code heuristic: braces/semicolons, common keywords, or indented multi-line block.
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

final class SnippetPickerWindowController {
    let store: SnippetStore
    let monitor: ClipboardMonitor
    /// Fired after the picker mutates the store (currently: ⌘⌫ delete) so callers can
    /// re-sync derived state — per-snippet hotkey registrations in particular.
    var onChange: (() -> Void)?

    private let palette = PaletteController()
    private var filtered: [Snippet] = []

    init(store: SnippetStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        palette.placeholder = "搜索代码片段…"
        palette.emptyText = "暂无片段，可从状态栏 ▸ 片段选择器 ▸ 添加片段"
        palette.footerHints = [("↩", "粘贴"), ("⌘⌫", "删除"), ("esc", "关闭")]
        palette.provider = { [weak self] q in self?.rows(for: q) ?? [] }
        palette.onActivate = { [weak self] i in self?.activate(i) }
        palette.onDelete = { [weak self] i in self?.deleteAt(i) }
    }

    func show() { palette.show() }
    func hide() { palette.hide() }
    func toggle() { palette.toggle() }
    func refreshIfVisible() { palette.reloadIfVisible() }

    private func rows(for query: String) -> [PaletteRow] {
        if query.isEmpty {
            filtered = store.items
        } else {
            let q = query.lowercased()
            filtered = store.items.filter {
                $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
            }
        }
        return filtered.map { s in
            let kind = snippetKind(of: s.content)
            return PaletteRow(icon: NSImage(systemSymbolName: kind.symbolName,
                                            accessibilityDescription: nil),
                              iconIsTemplate: true,
                              iconTint: kind.color,
                              title: s.title.isEmpty ? "未命名" : s.title,
                              subtitle: subtitle(for: s.content),
                              badge: kind.label,
                              badgeColor: kind.color,
                              accessoryBadge: s.hotKey?.display,
                              accessoryBadgeColor: nil)
        }
    }

    /// `N 行 · N 字符 · <preview>` — mirrors history rows' dense metadata-then-content feel.
    private func subtitle(for content: String) -> String {
        let stripped = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "（空）" }
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let charCount = content.count
        var parts: [String] = []
        if lineCount > 1 { parts.append("\(lineCount) 行") }
        parts.append("\(charCount) 字符")
        parts.append(preview(of: stripped))
        return parts.joined(separator: " · ")
    }

    private func preview(of content: String) -> String {
        var s = content.replacingOccurrences(of: "\n", with: " ")
                       .replacingOccurrences(of: "\t", with: " ")
        if s.count > 80 { s = String(s.prefix(80)) + "…" }
        return s
    }

    private func activate(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(filtered[i].content, forType: .string)
        monitor.suppressNext()
    }

    private func deleteAt(_ i: Int) {
        guard i >= 0, i < filtered.count else { return }
        store.delete(id: filtered[i].id)
        onChange?()
    }
}

// MARK: - Snippet editor (create a new snippet)

/// Tiny modal-ish editor: title field + monospaced content view + 取消/保存.
/// Used by the status-bar menu's "添加片段…" entry; saved snippets flow through
/// SnippetStore.add and the picker / per-snippet hotkeys are refreshed via onSave.
final class SnippetEditorWindowController: NSObject, NSWindowDelegate {
    let store: SnippetStore
    /// Fired after a snippet is added so the picker can refresh and hotkeys reload.
    var onSave: (() -> Void)?

    private var window: NSWindow!
    private var titleField: NSTextField!
    private var contentView: NSTextView!

    init(store: SnippetStore) {
        self.store = store
    }

    func show() {
        if window == nil { build() }
        titleField.stringValue = ""
        contentView.string = ""
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(titleField)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "添加片段"
        window.subtitle = "保存后会出现在状态栏 ▸ 片段选择器"
        window.isReleasedWhenClosed = false
        window.delegate = self

        titleField = NSTextField()
        titleField.placeholderString = "为这段内容起个名字"
        titleField.font = .systemFont(ofSize: 15)
        titleField.bezelStyle = .roundedBezel

        contentView = NSTextView()
        contentView.isRichText = false
        contentView.isAutomaticQuoteSubstitutionEnabled = false
        contentView.isAutomaticDashSubstitutionEnabled = false
        contentView.isAutomaticTextReplacementEnabled = false
        contentView.isAutomaticSpellingCorrectionEnabled = false
        contentView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        contentView.allowsUndo = true
        contentView.autoresizingMask = [.width]
        contentView.textContainerInset = NSSize(width: 6, height: 6)

        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = contentView

        let cancelBtn = makeDialogButton("取消", action: #selector(cancel), keyEquivalent: "\u{1b}")
        let saveBtn = makeDialogButton("保存", action: #selector(save), keyEquivalent: "\r")

        let buttons = NSStackView(views: [cancelBtn, saveBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let v = NSView()
        let titleSection = labeledSection("标题", control: titleField)
        let contentSection = labeledSection("内容", control: scroll)

        let stack = NSStackView(views: [titleSection, contentSection, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -18),

            titleSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        window.contentView = v
    }

    /// `<section label> over <control>` vertical pair with consistent label styling.
    private func labeledSection(_ title: String, control: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 11, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        let s = NSStackView(views: [lbl, control])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        return s
    }

    private func makeDialogButton(_ title: String, action: Selector, keyEquivalent: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = keyEquivalent
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        return b
    }

    @objc private func cancel() {
        window.orderOut(nil)
    }

    @objc private func save() {
        let rawTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = contentView.string
        let bodyEmpty = content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if rawTitle.isEmpty && bodyEmpty {
            window.orderOut(nil)
            return
        }
        let title = rawTitle.isEmpty ? "未命名" : rawTitle
        store.add(title: title, content: content)
        onSave?()
        window.orderOut(nil)
    }
}

// MARK: - Settings window (hotkey recorders + general options)

final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Asked to apply a new history summon-hotkey config; returns true if it registered OK.
    var onApply: ((HotKeyConfig) -> Bool)?
    /// Asked to apply a new snippet-picker summon-hotkey config; returns true if it registered OK.
    var onApplySnippetSummon: ((HotKeyConfig) -> Bool)?
    /// Asked to open the history palette.
    var onOpenHistory: (() -> Void)?
    /// Asked to open the snippet picker.
    var onOpenSnippetPicker: (() -> Void)?

    private var window: NSWindow!
    private var recordButton: HotKeyRecorderButton!
    private var snippetSummonButton: HotKeyRecorderButton!
    private var statusLabel: NSTextField!
    private var autostartSwitch: NSSwitch!

    func show() {
        if window == nil { build() }
        recordButton.stop()
        recordButton.config = HotKeyConfig.history
        snippetSummonButton.stop()
        snippetSummonButton.config = HotKeyConfig.snippet
        statusLabel.stringValue = "点按钮后按下你想用的组合键"
        autostartSwitch.state = LaunchAgent.isEnabled ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildGeneralTab()
    }

    // MARK: Style helpers

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }
    private func footnote(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    // MARK: General tab

    private func buildGeneralTab() -> NSView {
        let v = NSView()

        recordButton = HotKeyRecorderButton()
        recordButton.config = HotKeyConfig.history
        recordButton.onChange = { [weak self] cfg in self?.onApply?(cfg) ?? false }
        recordButton.onStatus = { [weak self] msg in self?.statusLabel.stringValue = msg }
        recordButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        snippetSummonButton = HotKeyRecorderButton()
        snippetSummonButton.config = HotKeyConfig.snippet
        snippetSummonButton.onChange = { [weak self] cfg in self?.onApplySnippetSummon?(cfg) ?? false }
        snippetSummonButton.onStatus = { [weak self] msg in self?.statusLabel.stringValue = msg }
        snippetSummonButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let hkGroup = makeGroup([
            formRow("唤出历史选择器", trailing: [recordButton, smallButton("恢复默认", #selector(resetHistoryDefault))]),
            hSeparator(),
            formRow("唤出片段选择器", trailing: [snippetSummonButton, smallButton("恢复默认", #selector(resetSnippetSummonDefault))]),
        ])

        let hkHint = footnote("组合键需含 ⌘ / ⌥ / ⌃ 之一；录制时按 Esc 取消。被占用的组合会自动保留原设置。")
        statusLabel = footnote("")

        autostartSwitch = NSSwitch()
        autostartSwitch.target = self
        autostartSwitch.action = #selector(toggleAutostart)

        let openStack = NSStackView(views: [roundedButton("唤出历史", #selector(openHistory)),
                                            roundedButton("片段选择器", #selector(openSnippetPicker))])
        openStack.orientation = .horizontal
        openStack.spacing = 8

        let genGroup = makeGroup([
            formRow("开机自启动", trailing: [autostartSwitch]),
            hSeparator(),
            formRow("快速打开", trailing: [openStack]),
        ])

        let hkTitle = sectionLabel("快捷键")
        let genTitle = sectionLabel("通用")

        let stack = NSStackView(views: [hkTitle, hkGroup, hkHint, statusLabel, genTitle, genGroup])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(8, after: hkTitle)
        stack.setCustomSpacing(10, after: hkGroup)
        stack.setCustomSpacing(20, after: statusLabel)
        stack.setCustomSpacing(8, after: genTitle)

        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -24),
            hkGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
            genGroup.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return v
    }

    // A label-left / controls-right row with inner padding, for use inside a grouped box.
    private func formRow(_ title: String, trailing: [NSView]) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 13)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        return row
    }

    // A rounded, hairline-bordered card holding a vertical run of rows (separators included).
    private func makeGroup(_ rows: [NSView]) -> NSBox {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }

        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = container
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func hSeparator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func smallButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    private func roundedButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func resetHistoryDefault() {
        recordButton.stop()
        if onApply?(.historyDefault) == true {
            recordButton.config = .historyDefault
            statusLabel.stringValue = "已恢复默认 \(HotKeyConfig.historyDefault.display)"
        } else {
            statusLabel.stringValue = "默认组合 \(HotKeyConfig.historyDefault.display) 当前被占用"
        }
    }

    @objc private func resetSnippetSummonDefault() {
        snippetSummonButton.stop()
        if onApplySnippetSummon?(.snippetDefault) == true {
            snippetSummonButton.config = .snippetDefault
            statusLabel.stringValue = "已恢复默认 \(HotKeyConfig.snippetDefault.display)"
        } else {
            statusLabel.stringValue = "默认组合 \(HotKeyConfig.snippetDefault.display) 当前被占用"
        }
    }

    @objc private func toggleAutostart() {
        if autostartSwitch.state == .on {
            LaunchAgent.enable()
        } else {
            LaunchAgent.disable()
        }
        autostartSwitch.state = LaunchAgent.isEnabled ? .on : .off
    }

    @objc private func openHistory() { onOpenHistory?() }
    @objc private func openSnippetPicker() { onOpenSnippetPicker?() }

    func windowWillClose(_ notification: Notification) {
        recordButton.stop()
        snippetSummonButton.stop()
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = HistoryStore()
    private lazy var snippetStore = SnippetStore(baseDir: store.baseDir)
    private var monitor: ClipboardMonitor!
    private var windowController: HistoryWindowController!
    private var snippetPicker: SnippetPickerWindowController!
    private var snippetEditor: SnippetEditorWindowController!
    private var settingsController: SettingsWindowController!
    private var historyHotKeyID: UInt32?
    private var snippetSummonHotKeyID: UInt32?
    private var snippetHotKeyIDs: [UUID: UInt32] = [:]
    private var currentConfig = HotKeyConfig.history
    private var currentSnippetSummonConfig = HotKeyConfig.snippet

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "粘贴历史")
            btn.image?.isTemplate = true
        }

        monitor = ClipboardMonitor(store: store)
        monitor.onCapture = { [weak self] item in
            self?.store.add(item)
            self?.windowController.refreshIfVisible()
        }
        monitor.start()

        windowController = HistoryWindowController(store: store, monitor: monitor)
        snippetPicker = SnippetPickerWindowController(store: snippetStore, monitor: monitor)
        // When a snippet is deleted from the picker, drop its registered hotkey too.
        snippetPicker.onChange = { [weak self] in self?.reloadSnippetHotKeys() }

        snippetEditor = SnippetEditorWindowController(store: snippetStore)
        snippetEditor.onSave = { [weak self] in
            self?.snippetPicker.refreshIfVisible()
            self?.reloadSnippetHotKeys()
        }

        settingsController = SettingsWindowController()
        settingsController.onApply = { [weak self] cfg in self?.applyHotKey(cfg) ?? false }
        settingsController.onApplySnippetSummon = { [weak self] cfg in self?.applySnippetSummonHotKey(cfg) ?? false }
        settingsController.onOpenHistory = { [weak self] in self?.windowController.show() }
        settingsController.onOpenSnippetPicker = { [weak self] in self?.snippetPicker.show() }

        // Register the summon hotkeys + any per-snippet hotkeys.
        applyHotKey(currentConfig)
        applySnippetSummonHotKey(currentSnippetSummonConfig)
        reloadSnippetHotKeys()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// (Re)register the history summon hotkey. Unregisters the old one first so re-picking
    /// the same combo works; on failure, restores the previously working combo.
    @discardableResult
    private func applyHotKey(_ config: HotKeyConfig) -> Bool {
        if let id = historyHotKeyID { HotKeyCenter.shared.unregister(id); historyHotKeyID = nil }
        if let id = HotKeyCenter.shared.register(keyCode: config.keyCode, modifiers: config.carbonModifiers,
                                                 callback: { [weak self] in self?.windowController.toggle() }) {
            historyHotKeyID = id
            currentConfig = config
            HotKeyConfig.history = config
            return true
        }
        // failed (e.g. combo taken) — restore previous
        historyHotKeyID = HotKeyCenter.shared.register(keyCode: currentConfig.keyCode,
                                                       modifiers: currentConfig.carbonModifiers,
                                                       callback: { [weak self] in self?.windowController.toggle() })
        return false
    }

    /// (Re)register the snippet-picker summon hotkey, with the same restore-on-failure logic.
    @discardableResult
    private func applySnippetSummonHotKey(_ config: HotKeyConfig) -> Bool {
        if let id = snippetSummonHotKeyID { HotKeyCenter.shared.unregister(id); snippetSummonHotKeyID = nil }
        if let id = HotKeyCenter.shared.register(keyCode: config.keyCode, modifiers: config.carbonModifiers,
                                                 callback: { [weak self] in self?.snippetPicker.toggle() }) {
            snippetSummonHotKeyID = id
            currentSnippetSummonConfig = config
            HotKeyConfig.snippet = config
            return true
        }
        snippetSummonHotKeyID = HotKeyCenter.shared.register(keyCode: currentSnippetSummonConfig.keyCode,
                                                             modifiers: currentSnippetSummonConfig.carbonModifiers,
                                                             callback: { [weak self] in self?.snippetPicker.toggle() })
        return false
    }

    /// Re-register all per-snippet hotkeys from scratch (cheap; snippets are few).
    private func reloadSnippetHotKeys() {
        for (_, id) in snippetHotKeyIDs { HotKeyCenter.shared.unregister(id) }
        snippetHotKeyIDs.removeAll()
        for snip in snippetStore.items {
            guard let hk = snip.hotKey else { continue }
            let sid = snip.id
            if let token = HotKeyCenter.shared.register(keyCode: hk.keyCode, modifiers: hk.carbonModifiers,
                                                        callback: { [weak self] in self?.emitSnippet(id: sid) }) {
                snippetHotKeyIDs[sid] = token
            }
        }
    }

    private func emitSnippet(id: UUID) {
        guard let snip = snippetStore.items.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snip.content, forType: .string)
        monitor.suppressNext()
        AutoPaste.deliver(after: 0.03) // we never had focus; paste straight into the focused app
    }

    /// Three-segment menu header (主标题 + 灰色快捷键 + 更浅的尾注），与历史/片段两个入口共享。
    private func menuHeaderTitle(primary: String, hotkey: String, trailing: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: primary,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor]))
        s.append(NSAttributedString(string: "   \(hotkey)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(NSAttributedString(string: "       \(trailing)",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.tertiaryLabelColor]))
        return s
    }

    /// 通用「图标 + 标题 + 动作」菜单项，给片段子菜单的入口（搜索 / 添加）共用。
    private func makeMenuAction(title: String, symbol: String, action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return mi
    }

    /// 片段列表中的一行：标题 + 可选快捷键后缀，点击 → 粘贴。
    private func makeSnippetItem(_ snip: Snippet) -> NSMenuItem {
        let name = snip.title.isEmpty ? "未命名" : snip.title
        let label = snip.hotKey.map { "\(name)   \($0.display)" } ?? name
        let mi = NSMenuItem(title: label, action: #selector(pasteSnippet(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = snip.id.uuidString
        mi.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                           accessibilityDescription: nil)
        return mi
    }

    /// Build one history row for the status menu. Used both for the top-10 inline list
    /// and for the "更多历史 ▸" submenu (which omits the ⌘N quick shortcut).
    private func makeHistoryItem(_ item: ClipItem, keyEquivalent: String) -> NSMenuItem {
        let mi = NSMenuItem(title: item.oneLine(18),
                            action: #selector(restoreItem(_:)),
                            keyEquivalent: keyEquivalent)
        mi.target = self
        mi.representedObject = item.id.uuidString
        if item.kind == .image, let f = item.imageFile,
           let thumb = NSImage(contentsOf: store.imageURL(f)) {
            let w: CGFloat = 24
            let h = max(1, thumb.size.height) / max(1, thumb.size.width) * w
            thumb.size = NSSize(width: w, height: min(h, 24))
            mi.image = thumb
        } else {
            let sym = item.kind == .file ? "doc.fill" : "text.alignleft"
            let cfg = NSImage.SymbolConfiguration(hierarchicalColor: kindColor(item.kind))
            mi.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }
        return mi
    }

    // Rebuild menu each time it opens so it's always fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Top header doubles as the action: click (or just hit the shortcut) to open the palette.
        // Composed of three pieces — primary action label, shortcut hint, and count.
        let header = NSMenuItem(title: "", action: #selector(summonHistory), keyEquivalent: "")
        header.attributedTitle = menuHeaderTitle(primary: "历史选择器",
                                                 hotkey: HotKeyConfig.history.display,
                                                 trailing: "粘贴历史 · \(store.items.count) 条")
        header.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        header.target = self
        menu.addItem(header)
        menu.addItem(.separator())

        if store.items.isEmpty {
            let empty = NSMenuItem(title: "暂无记录，复制点东西试试", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            // Top 10 inline — ⌘1–⌘9 quick shortcuts on the first nine.
            for (i, item) in store.items.prefix(10).enumerated() {
                menu.addItem(makeHistoryItem(item, keyEquivalent: i < 9 ? "\(i + 1)" : ""))
            }
            // Older items folded into a submenu so the dropdown stays compact.
            let rest = store.items.dropFirst(10)
            if !rest.isEmpty {
                let more = NSMenuItem(title: "更多历史（\(rest.count) 条）",
                                      action: nil, keyEquivalent: "")
                more.image = NSImage(systemSymbolName: "ellipsis.circle",
                                     accessibilityDescription: nil)
                let sub = NSMenu()
                for item in rest {
                    sub.addItem(makeHistoryItem(item, keyEquivalent: ""))
                }
                more.submenu = sub
                menu.addItem(more)
            }
        }

        menu.addItem(.separator())

        // Snippets submenu — quick paste of saved code/text fragments.
        let snippetsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        snippetsItem.attributedTitle = menuHeaderTitle(primary: "片段选择器",
                                                       hotkey: HotKeyConfig.snippet.display,
                                                       trailing: "代码片段 · \(snippetStore.items.count) 条")
        snippetsItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                                     accessibilityDescription: nil)
        let sub = NSMenu()
        sub.addItem(makeMenuAction(title: "搜索",
                                   symbol: "magnifyingglass",
                                   action: #selector(openSnippetPickerWindow)))
        sub.addItem(makeMenuAction(title: "添加片段…",
                                   symbol: "plus.circle",
                                   action: #selector(openSnippetEditor)))
        sub.addItem(.separator())
        if snippetStore.items.isEmpty {
            let empty = NSMenuItem(title: "（无，点上方「添加片段…」）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for snip in snippetStore.items {
                sub.addItem(makeSnippetItem(snip))
            }
        }
        snippetsItem.submenu = sub
        menu.addItem(snippetsItem)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let clear = NSMenuItem(title: "清空历史…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(clear)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func restoreItem(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let item = store.items.first(where: { $0.id == id }) else { return }
        restoreToClipboard(item, store: store)
        monitor.suppressNext()
        store.bump(id: id)
        windowController.refreshIfVisible()
        AutoPaste.deliver(after: 0.06) // menu has closed; previous app is frontmost again
    }

    @objc private func openSettings() {
        settingsController.show()
    }

    @objc private func summonHistory() {
        windowController.show()
    }

    @objc private func openSnippetPickerWindow() {
        snippetPicker.show()
    }

    @objc private func openSnippetEditor() {
        snippetEditor.show()
    }

    @objc private func pasteSnippet(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let snip = snippetStore.items.first(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(snip.content, forType: .string)
        monitor.suppressNext() // don't record the snippet itself into history
        AutoPaste.deliver(after: 0.06)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空所有粘贴历史？"
        alert.informativeText = "此操作不可撤销。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.clear()
            windowController.refreshIfVisible()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
