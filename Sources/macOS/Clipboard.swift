import Cocoa
import Carbon.HIToolbox
import ApplicationServices

// MARK: - Clipboard monitor

final class ClipboardMonitor {
    private let pb: NSPasteboard
    private var lastChange: Int
    private var timer: Timer?
    private let store: HistoryStore

    private var lastActivity = Date()
    private var currentInterval: TimeInterval = 1.0
    private static let activeInterval: TimeInterval = 0.3
    private static let normalInterval: TimeInterval = 1.0
    private static let idleInterval: TimeInterval = 2.0
    private static let activeDuration: TimeInterval = 5.0
    private static let idleDelay: TimeInterval = 30.0

    init(store: HistoryStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        pb = pasteboard
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
    }

    private func reschedule(_ interval: TimeInterval) {
        guard timer == nil || currentInterval != interval else { return }
        timer?.invalidate()
        currentInterval = interval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = min(0.1, interval * 0.2)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let c = pb.changeCount
        guard c != lastChange else {
            let elapsed = Date().timeIntervalSince(lastActivity)
            if elapsed >= Self.idleDelay {
                reschedule(Self.idleInterval)
            } else if elapsed >= Self.activeDuration {
                reschedule(Self.normalInterval)
            }
            return
        }
        lastChange = c
        lastActivity = Date()
        reschedule(Self.activeInterval)
        capture()
    }

    private func capture() {
        if let types = pb.types, types.contains(where: { $0.rawValue.lowercased().contains("concealed") }) { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }.joined(separator: "\n")
            store.add(ClipItem(id: UUID(), kind: .file, text: paths, imageFile: nil, date: Date()))
            return
        }
        if let fname = saveImageFromPasteboard() {
            store.add(ClipItem(id: UUID(), kind: .image, text: nil, imageFile: fname, date: Date()))
            return
        }
        if let str = pb.string(forType: .string),
           !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.add(ClipItem(id: UUID(), kind: .text, text: str, imageFile: nil, date: Date()))
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
        let objects: [NSPasteboardWriting]
        switch item.kind {
        case .text:
            return writeText(item.text ?? "")
        case .file:
            let urls = (item.text ?? "").split(separator: "\n")
                .map { NSURL(fileURLWithPath: String($0)) }
            guard !urls.isEmpty else { return false }
            objects = urls
        case .image:
            guard let name = item.imageFile,
                  let image = NSImage(contentsOf: store.imageURL(name)) else { return false }
            objects = [image]
        }
        pb.clearContents()
        guard pb.writeObjects(objects) else { return false }
        lastChange = pb.changeCount
        return true
    }

    @discardableResult
    func writeText(_ text: String) -> Bool {
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }
        lastChange = pb.changeCount
        return true
    }
}

// MARK: - Auto-paste (simulate ⌘V in the originating app)

enum AutoPaste {
    private static var isTrusted: Bool { AXIsProcessTrusted() }
    private static var didPrompt = false
    private static var didSecureAlert = false

    /// Sends paste directly to the app that owned focus before PasteHistory opened.
    /// App activation is asynchronous, so posting only to the global event stream can
    /// otherwise send Command-V back to PasteHistory while its palette is closing.
    static func deliver(to application: NSRunningApplication? = nil, after delay: Double = 0.15) {
        guard let target = pasteTarget(application) else { return }
        if isTrusted {
            if !target.isActive { target.activate() }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !target.isTerminated else { return }
                postPaste(to: target.processIdentifier)
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

    private static func postPaste(to processIdentifier: pid_t) {
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
        vDown.postToPid(processIdentifier)
        vUp.postToPid(processIdentifier)
    }

    private static func showPermissionAlertIfNeeded() {
        guard !didPrompt else { return }
        didPrompt = true
        DispatchQueue.main.async {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
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

}
