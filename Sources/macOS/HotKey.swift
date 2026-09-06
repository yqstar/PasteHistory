import Cocoa
import Carbon.HIToolbox

// MARK: - Global hotkey (Carbon — no Accessibility permission needed)

protocol HotKeyRegistering: AnyObject {
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32?
    func unregister(_ id: UInt32)
}

extension HotKeyRegistering {
    // Both palette shortcuts use the same rollback behavior on conflicts.
    func replace(_ id: UInt32?, current: HotKeyConfig, with config: HotKeyConfig,
                 callback: @escaping () -> Void) -> (id: UInt32?, applied: Bool) {
        if let id, current == config { return (id, true) }
        if let id { unregister(id) }
        if let replacement = register(keyCode: config.keyCode, modifiers: config.carbonModifiers,
                                      callback: callback) {
            return (replacement, true)
        }
        return (register(keyCode: current.keyCode, modifiers: current.carbonModifiers,
                         callback: callback), false)
    }
}

private let hotKeySignature: OSType = 0x50485459 // "PHTY"

final class HotKeyCenter: HotKeyRegistering {
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
            if err == noErr, hkID.signature == hotKeySignature { HotKeyCenter.shared.callbacks[hkID.id]?() }
            return noErr
        }, 1, &eventType, nil, nil)
        installed = status == noErr
        return installed
    }

    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) -> UInt32? {
        guard installHandlerIfNeeded() else { return nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: id)
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

// Keeps unchanged registrations alive when snippet titles, bodies, or order change.
final class SnippetHotKeyRegistry {
    private let center: HotKeyRegistering
    private var bindings: [UUID: (config: HotKeyConfig, token: UInt32)] = [:]
    private(set) var activeIDs = Set<UUID>()

    init(center: HotKeyRegistering = HotKeyCenter.shared) {
        self.center = center
    }

    deinit {
        for binding in bindings.values { center.unregister(binding.token) }
    }

    func update(_ snippets: [Snippet], onActivate: @escaping (UUID) -> Void) {
        let desired = Dictionary(snippets.compactMap { snippet in
            snippet.hotKey.map { (snippet.id, $0) }
        }, uniquingKeysWith: { first, _ in first })

        // Release all changed keys before registering replacements, so swaps work.
        for (id, binding) in bindings where desired[id] != binding.config {
            center.unregister(binding.token)
            bindings[id] = nil
        }
        for snippet in snippets {
            let id = snippet.id
            guard bindings[id] == nil, let config = desired[id] else { continue }
            if let token = center.register(keyCode: config.keyCode, modifiers: config.carbonModifiers,
                                            callback: { onActivate(id) }) {
                bindings[id] = (config, token)
            }
        }
        // Failed registrations are absent from bindings and retried on the next update.
        activeIDs = Set(bindings.keys)
    }
}

// MARK: - Hotkey configuration (persisted in UserDefaults)

struct HotKeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    static let historyDefault = HotKeyConfig(keyCode: UInt32(kVK_ANSI_P),
                                             carbonModifiers: UInt32(controlKey | cmdKey),
                                             display: "⌃⌘P")
    static let snippetDefault = HotKeyConfig(keyCode: UInt32(kVK_ANSI_S),
                                             carbonModifiers: UInt32(controlKey | cmdKey),
                                             display: "⌃⌘S")

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
