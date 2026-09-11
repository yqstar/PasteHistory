import Cocoa
import Carbon.HIToolbox

// MARK: - Hotkey recorder button

final class HotKeyRecorderButton: NSButton {
    var config: HotKeyConfig? { didSet { if !recording { updateTitle() } } }
    var onChange: ((HotKeyConfig) -> Bool)?
    var onStatus: ((String) -> Void)?

    private var recording = false
    private var monitor: Any?
    private static weak var activeRecorder: HotKeyRecorderButton?

    convenience init() {
        self.init(frame: .zero)
        bezelStyle = .rounded
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        translatesAutoresizingMaskIntoConstraints = false
        updateTitle()
    }

    private func updateTitle() {
        title = recording ? "按下组合键…" : (config?.display ?? "未设置")
        contentTintColor = recording ? .controlAccentColor : .labelColor
        toolTip = recording ? "按下新组合键，或按 Esc 取消" : "点击录制快捷键"
    }

    @objc private func toggle() { recording ? stop() : start() }

    private func start() {
        Self.activeRecorder?.stop()
        Self.activeRecorder = self
        recording = true
        updateTitle()
        onStatus?("正在录制：请按下组合键（Esc 取消）")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] e in
            guard let self, self.window?.isKeyWindow == true else { return e }
            self.handle(e)
            return nil
        }
    }

    func stop() {
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        updateTitle()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
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
