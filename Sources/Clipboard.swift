import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Clipboard monitor

final class ClipboardMonitor {
    private let pb = NSPasteboard.general
    private var lastChange: Int
    private var timer: Timer?
    private var returnToNormalWork: DispatchWorkItem?
    let store: HistoryStore
    var onCapture: ((ClipItem) -> Void)?

    private var lastActivity = Date()
    private var currentInterval: TimeInterval = 1.0
    private static let activeInterval: TimeInterval = 0.3
    private static let normalInterval: TimeInterval = 1.0
    private static let idleInterval: TimeInterval = 2.0
    private static let activeDuration: TimeInterval = 5.0
    private static let idleDelay: TimeInterval = 30.0

    init(store: HistoryStore) {
        self.store = store
        lastChange = pb.changeCount
    }

    func start() {
        guard timer == nil else { return }
        lastActivity = Date()
        reschedule(Self.normalInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        returnToNormalWork?.cancel()
        returnToNormalWork = nil
    }

    private func reschedule(_ interval: TimeInterval) {
        guard timer == nil || currentInterval != interval else { return }
        timer?.invalidate()
        currentInterval = interval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = min(0.1, interval * 0.2)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func suppressNext() {
        lastChange = pb.changeCount
    }

    private func poll() {
        let c = pb.changeCount
        guard c != lastChange else {
            if Date().timeIntervalSince(lastActivity) >= Self.idleDelay,
               currentInterval != Self.idleInterval {
                reschedule(Self.idleInterval)
            }
            return
        }
        lastChange = c
        lastActivity = Date()
        if currentInterval != Self.activeInterval {
            reschedule(Self.activeInterval)
        }
        scheduleReturnToNormal()
        capture()
    }

    private func scheduleReturnToNormal() {
        returnToNormalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentInterval == Self.activeInterval else { return }
            self.reschedule(Self.normalInterval)
        }
        returnToNormalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.activeDuration, execute: work)
    }

    private func capture() {
        if let types = pb.types, types.contains(where: { $0.rawValue.lowercased().contains("concealed") }) { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: "\n")
            onCapture?(ClipItem(id: UUID(), kind: .file, text: paths, imageFile: nil, date: Date()))
            return
        }
        if let fname = saveImageFromPasteboard() {
            onCapture?(ClipItem(id: UUID(), kind: .image, text: nil, imageFile: fname, date: Date()))
            return
        }
        if let str = pb.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onCapture?(ClipItem(id: UUID(), kind: .text, text: str, imageFile: nil, date: Date()))
            return
        }
    }

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
            try data.write(to: store.imageURL(name), options: .atomic)
            return name
        } catch {
            NSLog("[PasteHistory] image save failed: %@", error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func restore(_ item: ClipItem) -> Bool {
        guard restoreToClipboard(item, store: store) else { return false }
        suppressNext()
        return true
    }

    @discardableResult
    func writeText(_ text: String) -> Bool {
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        suppressNext()
        return true
    }
}

// MARK: - Clipboard restore

@discardableResult
func restoreToClipboard(_ item: ClipItem, store: HistoryStore) -> Bool {
    let pb = NSPasteboard.general
    switch item.kind {
    case .text:
        pb.clearContents()
        return pb.setString(item.text ?? "", forType: .string)
    case .file:
        let urls = (item.text ?? "").components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) as NSURL }
        guard !urls.isEmpty else { return false }
        pb.clearContents()
        return pb.writeObjects(urls)
    case .image:
        guard let file = item.imageFile,
              let image = NSImage(contentsOf: store.imageURL(file)) else { return false }
        pb.clearContents()
        return pb.writeObjects([image])
    }
}

// MARK: - Auto-paste (simulate ⌘V in the originating app)

enum AutoPaste {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    private static var didPrompt = false
    private static var didSecureAlert = false

    /// Sends paste directly to the app that owned focus before PasteHistory opened.
    /// App activation is asynchronous, so posting only to the global event stream can
    /// otherwise send Command-V back to PasteHistory while its palette is closing.
    static func deliver(to application: NSRunningApplication? = nil, after delay: Double = 0.15) {
        let target = pasteTarget(application)
        if isTrusted {
            if let target, !target.isActive {
                target.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard target?.isTerminated != true else { return }
                postPaste(to: target?.processIdentifier)
            }
        } else {
            showPermissionAlertIfNeeded()
        }
    }

    private static func pasteTarget(_ preferred: NSRunningApplication?) -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let preferred, !preferred.isTerminated, preferred.processIdentifier != ownPID {
            return preferred
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ownPID else { return nil }
        return frontmost
    }

    private static func postPaste(to processIdentifier: pid_t?) {
        if IsSecureEventInputEnabled() {
            showSecureInputAlertIfNeeded()
            return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let vDown = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            NSLog("[PasteHistory] unable to create paste keyboard events")
            return
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        if let processIdentifier {
            vDown.postToPid(processIdentifier)
            vUp.postToPid(processIdentifier)
        } else {
            vDown.post(tap: .cghidEventTap)
            vUp.post(tap: .cghidEventTap)
        }
    }

    private static func showPermissionAlertIfNeeded() {
        guard !didPrompt else { return }
        didPrompt = true
        DispatchQueue.main.async { showPermissionAlert() }
    }

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
