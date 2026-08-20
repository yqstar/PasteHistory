import Cocoa
import Carbon.HIToolbox

// MARK: - Global hotkey (Carbon — no Accessibility permission needed)

private func fourCharCode(_ s: String) -> OSType {
    var result: OSType = 0
    for ch in s.utf8.prefix(4) { result = (result << 8) + OSType(ch) }
    return result
}

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var callbacks: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    private func installHandlerIfNeeded() -> Bool {
        guard !installed else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            guard let event = event else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            if err == noErr { HotKeyCenter.shared.fire(id: hkID.id) }
            return noErr
        }, 1, &eventType, nil, nil)
        installed = status == noErr
        return installed
    }

    fileprivate func fire(id: UInt32) {
        callbacks[id]?()
    }

    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
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

// MARK: - Hotkey recorder button

final class HotKeyRecorderButton: NSButton {
    var placeholder = "未设置"
    var config: HotKeyConfig? { didSet { if !recording { updateTitle() } } }
    var onChange: ((HotKeyConfig) -> Bool)?
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
            return nil
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
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let historyDefault = HotKeyConfig(keyCode: UInt32(kVK_ANSI_V),
                                             carbonModifiers: UInt32(cmdKey | shiftKey),
                                             display: "⌘⇧V")
    static let snippetDefault = HotKeyConfig(keyCode: UInt32(kVK_ANSI_S),
                                             carbonModifiers: UInt32(cmdKey | shiftKey),
                                             display: "⌘⇧S")

    private static let historyKey = "hotKeyConfig"
    private static let snippetKey = "snippetSummonHotKey"

    static var history: HotKeyConfig {
        get { load(historyKey) ?? historyDefault }
        set { store(newValue, historyKey) }
    }
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
