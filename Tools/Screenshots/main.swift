import Cocoa
import Darwin

// Render the real AppKit controllers with synthetic data. Never use the system clipboard,
// register global shortcuts, enable login items, or launch the application's delegate.
private func pump(_ duration: TimeInterval = 0.25) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                      inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
}

private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

private func findWindow(_ title: String) throws -> NSWindow {
    guard let window = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else {
        throw NSError(domain: "Screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到窗口：\(title)"])
    }
    return window
}

private func snapshot(_ window: NSWindow, to directory: URL, name: String) throws {
    pump()
    guard let view = window.contentView?.superview else { return }
    view.layoutSubtreeIfNeeded()
    pump(0.1)
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let url = directory.appendingPathComponent(name + ".png")
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url, options: .atomic)
    print("Rendered \(url.lastPathComponent) (\(bitmap.pixelsWide) × \(bitmap.pixelsHigh))")
}

private func renderScreenshots(output: URL, iconURL: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteHistory-Preview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "PasteHistoryPreview.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = HistoryStore(baseDir: directory, defaults: defaults)
    let snippets = SnippetStore(baseDir: directory)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { history.flush(); pasteboard.releaseGlobally() }
    let monitor = ClipboardMonitor(store: history, pasteboard: pasteboard)
    try FileManager.default.copyItem(at: iconURL, to: history.imageURL("preview-icon.png"))

    let sampleHistory: [(ClipKind, String?, String?, TimeInterval)] = [
        (.text, "让每一次复制，都能在需要时找回来。", nil, 40),
        (.text, "git status --short", nil, 180),
        (.text, "https://github.com/yqstar/PasteHistory", nil, 480),
        (.image, nil, "preview-icon.png", 720),
        (.file, "/Projects/PasteHistory/README.md", nil, 1080),
        (.text, "发布前检查：构建、测试、更新文档。", nil, 1800),
    ]
    for (kind, text, image, age) in sampleHistory.reversed() {
        history.add(ClipItem(id: UUID(), kind: kind, text: text, imageFile: image,
                             date: Date().addingTimeInterval(-age)))
    }
    let decoder = """
    struct Note: Decodable {
        let title: String
        let content: String
    }

    let decoder = JSONDecoder()
    let note = try decoder.decode(Note.self, from: data)
    print(note.title)
    """
    let sampleSnippets = [
        Snippet(id: UUID(), title: "Swift · JSON 解码", content: decoder, hotKey: nil),
        Snippet(id: UUID(), title: "项目主页", content: "https://github.com/yqstar/PasteHistory", hotKey: nil),
        Snippet(id: UUID(), title: "发布检查清单", content: "确认版本号与更新说明\n运行构建和回归测试\n更新 README 界面截图", hotKey: nil),
        Snippet(id: UUID(), title: "Python · 读取配置", content: "import json\n\nwith open(\"config.json\") as file:\n    config = json.load(file)", hotKey: nil),
        Snippet(id: UUID(), title: "会议纪要模板", content: "会议主题：\n关键结论：\n下一步行动：", hotKey: nil),
    ]
    _ = try snippets.importItems(sampleSnippets, mode: .replace)
    let historyController = HistoryWindowController(store: history, monitor: monitor)
    let picker = SnippetPickerWindowController(store: snippets, monitor: monitor)
    let editor = SnippetEditorWindowController(store: snippets)
    picker.onCreate = { editor.showNew() }
    picker.onEdit = { editor.showEdit($0) }
    historyController.onSaveAsSnippet = { editor.showNew(content: $0) }
    let settings = SettingsWindowController()
    settings.historyStore = history
    settings.snippetStore = snippets

    // Override display-only preferences for this process, without changing persisted settings.
    UserDefaults.standard.setVolatileDomain([
        "hotKeyConfig": try JSONEncoder().encode(HotKeyConfig.historyDefault),
        "snippetSummonHotKey": try JSONEncoder().encode(HotKeyConfig.snippetDefault),
    ], forName: UserDefaults.argumentDomain)

    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        historyController.show()
        let historyWindow = try findWindow("粘贴历史")
        try snapshot(historyWindow, to: output, name: "history-\(name)")
        historyWindow.orderOut(nil)

        picker.show()
        let pickerWindow = try findWindow("代码片段")
        try snapshot(pickerWindow, to: output, name: "snippets-\(name)")
        picker.hide()

        editor.showEdit(sampleSnippets[0])
        let editorWindow = try findWindow("编辑片段")
        editorWindow.makeFirstResponder(nil)
        try snapshot(editorWindow, to: output, name: "editor-\(name)")
        editorWindow.performClose(nil)

        settings.show()
        let settingsWindow = try findWindow("设置")
        settingsWindow.makeFirstResponder(nil)
        try snapshot(settingsWindow, to: output, name: "settings-\(name)")
        settingsWindow.performClose(nil)
    }

    // Additional layouts stay in build/ for visual QA, rather than adding every state to README.
    let qa = output.appendingPathComponent("qa")
    try FileManager.default.createDirectory(at: qa, withIntermediateDirectories: true)
    let emptyStore = SnippetStore(baseDir: directory.appendingPathComponent("empty"))
    let emptyPicker = SnippetPickerWindowController(store: emptyStore, monitor: monitor)
    emptyPicker.onCreate = { editor.showNew() }
    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        emptyPicker.show()
        let emptyWindow = try findWindow("代码片段")
        emptyWindow.setContentSize(NSSize(width: 440, height: 320))
        try snapshot(emptyWindow, to: qa, name: "empty-small-\(name)")
        emptyPicker.hide()

        picker.show()
        let pickerWindow = try findWindow("代码片段")
        pickerWindow.setContentSize(NSSize(width: 440, height: 320))
        try snapshot(pickerWindow, to: qa, name: "populated-small-\(name)")
        let search = descendants(pickerWindow.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.isEditable }!
        search.stringValue = "未匹配的关键词"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try snapshot(pickerWindow, to: qa, name: "no-results-small-\(name)")
        picker.hide()

        editor.showEdit(sampleSnippets[0])
        let editorWindow = try findWindow("编辑片段")
        editorWindow.setContentSize(NSSize(width: 480, height: 398))
        editorWindow.makeFirstResponder(nil)
        try snapshot(editorWindow, to: qa, name: "editor-small-\(name)")
        editorWindow.performClose(nil)

        settings.show()
        let settingsWindow = try findWindow("设置")
        settingsWindow.setContentSize(NSSize(width: 540, height: 458))
        try snapshot(settingsWindow, to: qa, name: "settings-small-\(name)")
        settingsWindow.performClose(nil)
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
                                                              .leftMouseDown, .leftMouseUp,
                                                              .rightMouseDown, .rightMouseUp]) { _ in nil }
DispatchQueue.main.async {
    do {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "Screenshots", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: PasteHistoryScreenshots OUTPUT_DIR APP_ICON_PNG"])
        }
        try renderScreenshots(output: URL(fileURLWithPath: CommandLine.arguments[1]),
                              iconURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        exit(EXIT_SUCCESS)
    } catch {
        print("Screenshot error: \(error)")
        exit(EXIT_FAILURE)
    }
}
app.run()
