import Cocoa
import Carbon.HIToolbox
import Darwin

// Runs only against temporary stores; it never starts clipboard monitoring or auto-paste.
private var failures = 0
private let scriptedKeyTimestamp: TimeInterval = 0.12345
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() { print("PASS: \(message)") }
    else { failures += 1; print("FAIL: \(message)") }
}

private func pump(_ duration: TimeInterval = 0.2) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end {
        if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                      inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
    }
}

private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

private func buttons(_ window: NSWindow, title: String) -> [NSButton] {
    descendants(window.contentView!).compactMap { $0 as? NSButton }
        .filter { $0.title == title && !$0.isHiddenOrHasHiddenAncestor }
}

private func click(_ window: NSWindow, _ title: String) {
    guard let button = buttons(window, title: title).first else {
        check(false, "找不到按钮：\(title)")
        return
    }
    button.performClick(nil)
    pump()
}

private func respond(_ window: NSWindow, _ title: String) {
    pump()
    guard let sheet = window.attachedSheet else {
        check(false, "应显示确认或错误提示：\(title)")
        return
    }
    click(sheet, title)
}

private func snapshot(_ window: NSWindow, _ name: String) throws {
    guard CommandLine.arguments.count > 1, let view = window.contentView else { return }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png")
    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
}

private func testClipboardAndThumbnails(in directory: URL, defaults: UserDefaults) throws {
    let history = HistoryStore(baseDir: directory.appendingPathComponent("clipboard"), defaults: defaults)
    let pasteboard = NSPasteboard.withUniqueName()
    let monitor = ClipboardMonitor(store: history, pasteboard: pasteboard)
    defer { monitor.stop(); history.flush(); pasteboard.releaseGlobally() }
    let text = ClipItem(id: UUID(), kind: .text, text: "restored text", imageFile: nil, date: Date())
    check(monitor.restore(text) && pasteboard.string(forType: .string) == text.text, "文本恢复使用指定剪贴板")
    let paths = [directory.appendingPathComponent("one.txt").path, directory.appendingPathComponent("two.txt").path]
    let files = ClipItem(id: UUID(), kind: .file, text: paths.joined(separator: "\n"), imageFile: nil, date: Date())
    check(monitor.restore(files), "多个文件路径可以恢复")
    let restoredURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    check(restoredURLs?.map(\.path) == paths, "文件恢复保留路径及顺序")

    let sample = NSImage(size: NSSize(width: 400, height: 200), flipped: false) { rect in
        NSColor.systemBlue.setFill()
        rect.fill()
        return true
    }
    let imageURL = history.imageURL("sample.png")
    let png = NSBitmapImageRep(data: sample.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try png.write(to: imageURL)
    let thumb = loadImageThumbnail(at: imageURL, maxSize: 48)
    check(thumb?.size == NSSize(width: 48, height: 24), "图片缩略图限制尺寸并保留宽高比")
    let image = ClipItem(id: UUID(), kind: .image, text: nil, imageFile: "sample.png", date: Date())
    check(monitor.restore(image) && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil), "图片仍可恢复到剪贴板")
    monitor.writeText("self-written snippet")
    let missing = ClipItem(id: UUID(), kind: .image, text: nil, imageFile: "missing.png", date: Date())
    check(!monitor.restore(missing) && pasteboard.string(forType: .string) == "self-written snippet", "缺失图片不会清空已有剪贴板内容")
    monitor.start()
    pump(1.1)
    check(history.items.isEmpty, "应用自身写入不产生历史记录")
    pasteboard.clearContents()
    pasteboard.setString("externally copied text", forType: .string)
    pump(1.1)
    check(history.items.first?.text == "externally copied text", "简化轮询后仍会捕获外部复制")
    pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
    pasteboard.setString("synthetic concealed text", forType: .string)
    pump(0.4)
    check(history.items.count == 1, "隐藏类型的剪贴板内容仍会跳过")
    monitor.stop()

    history.add(image)
    history.add(ClipItem(id: UUID(), kind: .text, text: String(repeating: "a", count: 500) + "TAIL_MARKER", imageFile: nil, date: Date()))
    let controller = HistoryWindowController(store: history, monitor: monitor)
    controller.show()
    pump()
    let window = NSApp.windows.first { window in
        descendants(window.contentView!).contains { ($0 as? NSTextField)?.placeholderString == "搜索粘贴历史…" }
    }!
    try snapshot(window, "history-thumbnails")
    let search = descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    window.makeFirstResponder(search)
    (window.firstResponder as? NSTextView)?.insertText("TAIL_MARKER", replacementRange: NSRange(location: NSNotFound, length: 0))
    pump()
    let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
    check(table.numberOfRows == 1, "历史选择器能搜索正文第 400 字之后的内容")
    window.performClose(nil)
}

private func runTests() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteHistoryUI-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "PasteHistoryUITests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = HistoryStore(baseDir: directory, defaults: defaults)
    let store = SnippetStore(baseDir: directory)
    let monitor = ClipboardMonitor(store: history)
    let editor = SnippetEditorWindowController(store: store)
    let picker = SnippetPickerWindowController(store: store, monitor: monitor)
    picker.onCreate = { editor.showNew() }
    picker.onEdit = { editor.showEdit($0) }
    picker.show()
    pump()
    let pickerWindow = NSApp.windows.first { window in
        descendants(window.contentView!).contains {
            ($0 as? NSTextField)?.placeholderString == "搜索代码片段…"
        }
    }!
    let createButtons = buttons(pickerWindow, title: "新建片段")
    check(createButtons.count == 2, "空片段列表显示顶部和中央新建按钮")
    try snapshot(pickerWindow, "snippet-empty")
    pickerWindow.setContentSize(NSSize(width: 440, height: 320))
    pump()
    try snapshot(pickerWindow, "snippet-empty-small")
    createButtons.first?.performClick(nil)
    pump()
    let window = NSApp.windows.first { $0.title == "新建片段" }!
    let title = descendants(window.contentView!).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
    let body = descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }!
    check(window.isVisible && !editor.hasUnsavedChanges, "空态按钮打开空白编辑器")
    window.performClose(nil)
    pump()
    check(!window.isVisible && window.attachedSheet == nil, "未修改的空白草稿可直接关闭")

    picker.show()
    pump()
    let newEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                   timestamp: scriptedKeyTimestamp,
                                   windowNumber: pickerWindow.windowNumber, context: nil,
                                   characters: "n", charactersIgnoringModifiers: "n",
                                   isARepeat: false, keyCode: UInt16(kVK_ANSI_N))!
    NSApp.postEvent(newEvent, atStart: false)
    pump()
    check(window.isVisible && !pickerWindow.isVisible, "空列表未选中行时，⌘N 仍可新建")
    window.makeFirstResponder(title)
    (window.firstResponder as? NSTextView)?.insertText("测试标题", replacementRange: NSRange(location: NSNotFound, length: 0))
    check(editor.hasUnsavedChanges, "标题正在输入时即可识别未保存修改")
    body.string = "first saved body"
    window.performClose(nil)
    pump()
    check(window.attachedSheet.map { buttons($0, title: "保存").count == 1 && buttons($0, title: "放弃").count == 1 && buttons($0, title: "取消").count == 1 } ?? false,
          "关闭修改后的草稿提供保存、放弃和取消")
    if let sheet = window.attachedSheet { try snapshot(sheet, "snippet-unsaved") }
    respond(window, "取消")
    check(window.isVisible && body.string == "first saved body", "取消关闭保留草稿")
    window.performClose(nil)
    respond(window, "保存")
    check(!window.isVisible && store.items.first?.content == "first saved body", "确认保存后写入片段并关闭")
    check(SnippetStore(baseDir: directory).items == store.items, "新建片段已持久化到磁盘")

    let saved = store.items.first!
    editor.showEdit(saved)
    body.string = "modified draft"
    editor.showEdit(saved)
    check(body.string == "modified draft" && window.attachedSheet == nil, "重新打开同一片段保留当前修改")
    editor.showNew()
    respond(window, "取消")
    check(body.string == "modified draft", "取消切换保留原编辑内容")
    editor.showNew()
    respond(window, "放弃")
    check(body.string.isEmpty && title.stringValue.isEmpty && !editor.hasUnsavedChanges, "放弃修改后切换到空白新建窗口")

    editor.showNew(content: "captured history body")
    check(editor.hasUnsavedChanges, "从历史带入的正文尚未保存时也受保护")
    editor.showEdit(saved)
    respond(window, "保存")
    check(store.items.contains { $0.content == "captured history body" }, "切换前保存历史带入内容")
    check(body.string == saved.content && !editor.hasUnsavedChanges, "保存成功后打开目标片段")

    editor.showNew()
    title.stringValue = "只有标题"
    editor.showEdit(saved)
    respond(window, "保存")
    check(window.isVisible && title.stringValue == "只有标题" && body.string.isEmpty,
          "保存空正文失败时取消切换并保留草稿")
    respond(window, "好")
    click(window, "取消")
    respond(window, "放弃")

    editor.showNew(content: saved.content)
    title.stringValue = "重复正文的新标题"
    click(window, "保存")
    check(window.isVisible && body.string == saved.content && title.stringValue == "重复正文的新标题",
          "重复正文不覆盖当前编辑内容")
    respond(window, "好")
    click(window, "取消")
    respond(window, "放弃")

    editor.showEdit(saved)
    body.string = "recovered removed draft"
    try store.delete(id: saved.id)
    click(window, "保存")
    check(window.isVisible && body.string == "recovered removed draft", "原片段被移除后保存失败仍保留草稿")
    respond(window, "好")
    click(window, "保存")
    check(!window.isVisible && store.items.contains { $0.content == "recovered removed draft" },
          "再次保存可将失去原片段的草稿另存为新片段")

    editor.showNew(content: "disk failure draft")
    let db = directory.appendingPathComponent("snippets.json")
    let heldDB = directory.appendingPathComponent("held-snippets.json")
    try FileManager.default.moveItem(at: db, to: heldDB)
    try FileManager.default.createDirectory(at: db, withIntermediateDirectories: false)
    click(window, "保存")
    check(window.isVisible && body.string == "disk failure draft" && editor.hasUnsavedChanges,
          "磁盘写入失败时保留编辑窗口和正文")
    respond(window, "好")
    try FileManager.default.removeItem(at: db)
    try FileManager.default.moveItem(at: heldDB, to: db)
    click(window, "取消")
    respond(window, "放弃")

    editor.showNew(content: "hidden editor draft")
    window.orderOut(nil)
    check(editor.hasUnsavedChanges, "窗口暂时隐藏后未保存内容仍受保护")
    var allowedToQuit: Bool?
    editor.confirmDiscardingChanges { allowedToQuit = $0 }
    respond(window, "取消")
    check(allowedToQuit == false && body.string == "hidden editor draft", "取消退出会重新显示并保留隐藏草稿")
    editor.confirmDiscardingChanges { allowedToQuit = $0 }
    respond(window, "保存")
    check(allowedToQuit == true && !editor.hasUnsavedChanges && store.items.contains { $0.content == "hidden editor draft" },
          "退出前保存草稿并清除未保存状态")
    window.performClose(nil)

    pickerWindow.setContentSize(NSSize(width: 600, height: 480))
    picker.show()
    pump()
    check(buttons(pickerWindow, title: "新建片段").count == 1, "已有片段时仅显示顶部新建按钮")
    try snapshot(pickerWindow, "snippet-populated")
    click(pickerWindow, "新建片段")
    check(window.isVisible && body.string.isEmpty, "顶部按钮可直接新建片段")
    window.performClose(nil)
    picker.show()
    pump()
    let search = descendants(pickerWindow.contentView!).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == "搜索代码片段…" }!
    pickerWindow.makeFirstResponder(search)
    (pickerWindow.firstResponder as? NSTextView)?.insertText("UNMATCHED_QUERY", replacementRange: NSRange(location: NSNotFound, length: 0))
    pump()
    check(buttons(pickerWindow, title: "新建片段").count == 2, "搜索无结果时也提供中央创建入口")
    picker.hide()
    try testClipboardAndThumbnails(in: directory, defaults: defaults)

    let settings = SettingsWindowController()
    settings.historyStore = history
    settings.snippetStore = store
    settings.show()
    pump()
    let settingsWindow = NSApp.windows.first { $0.title == "设置" }!
    let recorders = descendants(settingsWindow.contentView!).compactMap { $0 as? HotKeyRecorderButton }
    recorders[0].performClick(nil)
    recorders[1].performClick(nil)
    check(recorders[0].title != "按下组合键…" && recorders[1].title == "按下组合键…", "快捷键录制按钮互斥，不遗留旧监听")
    settingsWindow.performClose(nil)
    pump()
    check(recorders.allSatisfy { $0.title != "按下组合键…" }, "关闭设置会停止快捷键录制")
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Real keyboard/mouse input must not edit synthetic drafts while the UI test owns focus.
let inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged,
                                                              .leftMouseDown, .leftMouseUp,
                                                              .rightMouseDown, .rightMouseUp]) { event in
    event.type == .keyDown && event.timestamp == scriptedKeyTimestamp ? event : nil
}
DispatchQueue.main.async {
    do { try runTests() }
    catch { failures += 1; print("FAIL: \(error)") }
    print(failures == 0 ? "PASS: 片段界面回归全部通过" : "FAIL: 共 \(failures) 项失败")
    if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
}
app.run()
